import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test('animated Giphy fixture contains two frames', () async {
    final codec = await ui.instantiateImageCodec(_gifBody);
    addTearDown(codec.dispose);

    expect(codec.frameCount, 2);
    final first = await codec.getNextFrame();
    final second = await codec.getNextFrame();
    addTearDown(first.image.dispose);
    addTearDown(second.image.dispose);
    expect(first.duration, isNot(Duration.zero));
    expect(second.duration, isNot(Duration.zero));
    final firstPixels = await first.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    final secondPixels = await second.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(
      secondPixels!.buffer.asUint8List(),
      isNot(equals(firstPixels!.buffer.asUint8List())),
    );
  });

  testWidgets('renders a confirmed Giphy reference as inline memory media', (
    tester,
  ) async {
    final completion = Completer<GiphyReferenceMedia>();
    GiphyReferenceRequest? observed;
    await tester.pumpWidget(
      _messageApp(
        _message('Before [$_resourceUrl]($_resourceUrl) after', messageId: 101),
        overrides: [
          giphyReferenceMediaProvider.overrideWith((ref, request) {
            observed = request;
            return completion.future;
          }),
        ],
      ),
    );

    expect(observed?.accountId, _account.id);
    expect(observed?.resourceUrl, Uri.parse(_resourceUrl));
    expect(
      find.byKey(const Key('chat-giphy-reference-loading-0')),
      findsOneWidget,
    );
    expect(find.byType(InkWell), findsNothing);
    expect(find.textContaining('Before', findRichText: true), findsOneWidget);
    expect(find.textContaining('after', findRichText: true), findsOneWidget);

    completion.complete(
      GiphyReferenceMedia(
        resourceUrl: Uri.parse(_resourceUrl),
        body: _gifBody,
        contentType: 'image/gif',
        aspectRatio: 2,
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('chat-giphy-reference-loading-0')),
      findsOneWidget,
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('chat-giphy-reference-loading-0'))
          .evaluate()
          .isEmpty,
    );

    expect(
      find.byKey(const Key('chat-giphy-reference-loading-0')),
      findsNothing,
    );
    final memoryImage = find.byWidgetPredicate(
      (widget) => widget is Image && widget.image is ResizeImage,
    );
    expect(memoryImage, findsOneWidget);
    final ratio = tester.widget<AspectRatio>(
      find.byKey(const Key('chat-giphy-reference-media-0')),
    );
    expect(ratio.aspectRatio, 2);
    expect(find.byType(InkWell), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'renders an exact confirmed Giphy URL inline when markdown is false',
    (tester) async {
      await _expectConfirmedExactGiphyInline(
        tester,
        _message(_resourceUrl, messageId: 123, markdown: false),
      );
    },
  );

  testWidgets(
    'renders an exact confirmed Giphy URL inline when markdown is missing',
    (tester) async {
      await _expectConfirmedExactGiphyInline(
        tester,
        _message(_resourceUrl, messageId: 124, includeMarkdown: false),
      );
    },
  );

  testWidgets('hides the Giphy URL and exposes retry when resolution fails', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _messageApp(
        _message('[$_resourceUrl]($_resourceUrl)', messageId: 102),
        overrides: [
          giphyReferenceMediaProvider.overrideWith((ref, request) async {
            attempts++;
            throw const GiphyException(GiphyError.network);
          }),
        ],
      ),
    );
    await tester.pump();

    expect(find.text(_resourceUrl), findsNothing);
    expect(
      find.byKey(const Key('chat-giphy-reference-error-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('chat-giphy-reference-retry-0')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is MemoryImage,
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('chat-giphy-reference-retry-0')));
    await tester.pump();
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inactive recipient integration is final and hides the URL', (
    tester,
  ) async {
    await tester.pumpWidget(
      _messageApp(
        _message('[$_resourceUrl]($_resourceUrl)', messageId: 125),
        overrides: [
          giphyReferenceMediaProvider.overrideWith((ref, request) async {
            throw const GiphyException(GiphyError.integrationUnavailable);
          }),
        ],
      ),
    );
    await tester.pump();

    expect(find.text(_resourceUrl), findsNothing);
    expect(find.text('GIFs are not available on this server.'), findsOneWidget);
    expect(
      find.byKey(const Key('chat-giphy-reference-error-0')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('chat-giphy-reference-retry-0')), findsNothing);
    expect(find.byIcon(Icons.gif_box_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolves at most four Giphy references per message', (
    tester,
  ) async {
    final pending = Completer<GiphyReferenceMedia>();
    final observed = <GiphyReferenceRequest>[];
    final links = List<String>.generate(
      5,
      (index) => 'https://giphy.com/gifs/fixture-$index',
    );
    await tester.pumpWidget(
      _messageApp(
        _message(
          links.map((link) => '[$link]($link)').join(' '),
          messageId: 103,
        ),
        overrides: [
          giphyReferenceMediaProvider.overrideWith((ref, request) {
            observed.add(request);
            return pending.future;
          }),
        ],
      ),
    );

    expect(observed, hasLength(4));
    expect(find.byType(CircularProgressIndicator), findsNWidgets(4));
    expect(find.byType(InkWell), findsNothing);
    expect(find.text(links.last), findsNothing);
    expect(
      find.byKey(const Key('chat-giphy-reference-error-4')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('bounds reference loading across visible messages', (
    tester,
  ) async {
    final gates = List.generate(3, (_) => Completer<void>());
    var activeResolves = 0;
    var maximumActiveResolves = 0;
    var startedResolves = 0;
    final repository = HttpGiphyRepository(
      server: ServerBase.parse(_account.serverUrl),
      authorization: const GiphyAuthorization(
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/ocs/v2.php/references/resolve')) {
          final gateIndex = startedResolves++;
          activeResolves++;
          maximumActiveResolves = activeResolves > maximumActiveResolves
              ? activeResolves
              : maximumActiveResolves;
          try {
            await gates[gateIndex].future;
          } finally {
            activeResolves--;
          }
          final resource = request.url.queryParameters['reference']!;
          return http.Response(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'ok',
                  'statuscode': 200,
                  'message': 'OK',
                },
                'data': <String, Object?>{
                  'references': <String, Object?>{
                    resource: <String, Object?>{
                      'richObjectType': 'integration_giphy_gif',
                      'richObject': <String, Object?>{
                        'proxied_url':
                            '${_account.serverUrl}/apps/'
                            'integration_giphy/gif/proxy',
                      },
                    },
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response.bytes(
          _gifBody,
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }),
    );
    addTearDown(repository.close);
    final resources = List.generate(
      3,
      (index) => 'https://giphy.com/gifs/visible-fixture-$index',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          giphyRepositoryProvider.overrideWith(
            (ref, accountId) async => repository,
          ),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (var index = 0; index < resources.length; index++)
                    ChatMessageContent(
                      account: _account,
                      message: _message(
                        '[${resources[index]}](${resources[index]})',
                        messageId: 120 + index,
                      ),
                      fallbackText: resources[index],
                      foregroundColor: Colors.black,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => startedResolves == 2);

    expect(maximumActiveResolves, 2);
    expect(startedResolves, 2);
    gates[0].complete();
    await _pumpUntil(tester, () => startedResolves == 3);

    expect(maximumActiveResolves, 2);
    gates[1].complete();
    gates[2].complete();
    await _pumpUntil(
      tester,
      () =>
          find
              .byWidgetPredicate(
                (widget) => widget is Image && widget.image is ResizeImage,
              )
              .evaluate()
              .length ==
          3,
    );
    for (final resource in resources) {
      expect(find.textContaining(resource), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'renders a pending exact Giphy message through the same resolver',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            giphyReferenceMediaProvider.overrideWith((ref, request) async {
              return GiphyReferenceMedia(
                resourceUrl: request.resourceUrl,
                body: _gifBody,
                contentType: 'image/gif',
                aspectRatio: 1,
              );
            }),
          ],
          child: localizedTestApp(
            home: Scaffold(
              body: ChatPendingGiphyReference(
                account: _account,
                resourceUrl: Uri.parse(_resourceUrl),
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is ResizeImage,
        ),
        findsOneWidget,
      );
      expect(find.byType(InkWell), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retry also rebuilds a failed account Giphy repository', (
    tester,
  ) async {
    final repository = _referenceRepository();
    addTearDown(repository.close);
    var repositoryAttempts = 0;
    await tester.pumpWidget(
      _messageApp(
        _message('[$_resourceUrl]($_resourceUrl)', messageId: 104),
        overrides: [
          giphyRepositoryProvider.overrideWith((ref, accountId) async {
            repositoryAttempts++;
            if (repositoryAttempts == 1) {
              throw const GiphyException(GiphyError.network);
            }
            return repository;
          }),
        ],
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('chat-giphy-reference-error-0')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('chat-giphy-reference-retry-0')));
    await _pumpUntil(
      tester,
      () => find
          .byWidgetPredicate(
            (widget) => widget is Image && widget.image is ResizeImage,
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(repositoryAttempts, 2);
    expect(find.text(_resourceUrl), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply preview labels a Giphy parent without exposing its URL', (
    tester,
  ) async {
    final replyWire =
        Map<String, Object?>.from(_message('Reply body', messageId: 106).wire)
          ..['threadId'] = 105
          ..['parent'] = _message(_resourceUrl, messageId: 105).wire;
    final reply = ChatMessage.fromJson(replyWire);

    await tester.pumpWidget(_messageApp(reply, overrides: const []));

    expect(find.text('GIF'), findsOneWidget);
    expect(find.text(_resourceUrl), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply preview hides a Giphy URL inside surrounding text', (
    tester,
  ) async {
    final replyWire =
        Map<String, Object?>.from(_message('Reply body', messageId: 108).wire)
          ..['threadId'] = 107
          ..['parent'] = _message(
            'Before $_resourceUrl after',
            messageId: 107,
          ).wire;

    await tester.pumpWidget(
      _messageApp(ChatMessage.fromJson(replyWire), overrides: const []),
    );

    expect(find.text('Before GIF after'), findsOneWidget);
    expect(find.textContaining(_resourceUrl), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}

HttpGiphyRepository _referenceRepository() {
  return HttpGiphyRepository(
    server: ServerBase.parse(_account.serverUrl),
    authorization: const GiphyAuthorization(
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    ),
    client: MockClient((request) async {
      if (request.url.path.endsWith('/ocs/v2.php/references/resolve')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': <String, Object?>{
                'references': <String, Object?>{
                  _resourceUrl: <String, Object?>{
                    'richObjectType': 'integration_giphy_gif',
                    'richObject': <String, Object?>{
                      'proxied_url':
                          '${_account.serverUrl}/apps/'
                          'integration_giphy/gif/proxy',
                    },
                  },
                },
              },
            },
          }),
          200,
        );
      }
      return http.Response.bytes(
        _gifBody,
        200,
        headers: const <String, String>{'content-type': 'image/gif'},
      );
    }),
  );
}

Widget _messageApp(ChatMessage message, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: localizedTestApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: ChatMessageContent(
            account: _account,
            message: message,
            fallbackText: message.message,
            foregroundColor: Colors.black,
          ),
        ),
      ),
    ),
  );
}

Future<void> _expectConfirmedExactGiphyInline(
  WidgetTester tester,
  ChatMessage message,
) async {
  GiphyReferenceRequest? observed;
  await tester.pumpWidget(
    _messageApp(
      message,
      overrides: [
        giphyReferenceMediaProvider.overrideWith((ref, request) async {
          observed = request;
          return GiphyReferenceMedia(
            resourceUrl: request.resourceUrl,
            body: _gifBody,
            contentType: 'image/gif',
            aspectRatio: 1,
          );
        }),
      ],
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(observed?.accountId, _account.id);
  expect(observed?.resourceUrl, Uri.parse(_resourceUrl));
  final memoryImage = find.byWidgetPredicate(
    (widget) =>
        widget is Image &&
        widget.image is ResizeImage &&
        (widget.image as ResizeImage).imageProvider is MemoryImage,
  );
  expect(memoryImage, findsOneWidget);
  expect(find.textContaining(_resourceUrl), findsNothing);
  expect(find.textContaining(_resourceUrl, findRichText: true), findsNothing);
  expect(find.byType(InkWell), findsNothing);
  expect(tester.takeException(), isNull);
}

ChatMessage _message(
  String text, {
  required int messageId,
  bool? markdown = true,
  bool includeMarkdown = true,
}) {
  final wire = <String, Object?>{
    'id': messageId,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'fixture-author',
    'actorDisplayName': 'Fixture author',
    'timestamp': 1767225600,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$messageId',
    'message': text,
    'messageParameters': <String, Object?>{},
    'reactions': <String, Object?>{},
    'reactionsSelf': <Object?>[],
    'deleted': null,
  };
  if (includeMarkdown) {
    wire['markdown'] = markdown;
  }
  return ChatMessage.fromJson(wire);
}

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

const _resourceUrl = 'https://giphy.com/gifs/waving-cat-fixture123';

final _gifBody = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwA'
  'AAAAAQABAAACAkQBACH5BAAKAAAALAAAAAABAAEAAAICTAEAOw==',
);
