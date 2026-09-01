import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/chat/composer/chat_media_composer.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy_attachment.dart';
import 'package:nextcloudtalk/features/chat/location_share_service.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:nextcloudtalk/platform/app_settings.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'chat_composer_location_test.part.dart';
part 'chat_composer_giphy_reopen_test.part.dart';

void main() {
  _registerLocationComposerTests();
  _registerGiphyReopenTests();
  testWidgets(
    'media reply reaches finalize and clears its banner on enqueue',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.runAsync(harness.seedReplyMessage);

      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () =>
            find
                .byKey(const Key('chat-message-target-109'))
                .evaluate()
                .isNotEmpty &&
            find.byType(ChatMediaComposer).evaluate().isNotEmpty,
      );
      await tester.longPress(find.byKey(const Key('chat-message-target-109')));
      await _pumpTransition(tester);
      await tester.tap(find.byKey(const Key('message-action-reply')));
      await _pumpTransition(tester);
      expect(find.byKey(const Key('chat-reply-banner')), findsOneWidget);

      final controller = tester
          .widget<ChatMediaComposer>(find.byType(ChatMediaComposer))
          .controller!;
      late Future<bool> acceptedFuture;
      await tester.runAsync(() async {
        acceptedFuture = controller.submitGiphyAttachment(
          (_) async => GiphyAttachmentPayload(
            body: _animatedGif,
            mimeType: 'image/gif',
            displayName: 'reply-fixture.gif',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1));
      });
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-reply-banner')).evaluate().isEmpty,
      );
      expect(await tester.runAsync(() => acceptedFuture), isTrue);
      await _pumpUntil(tester, () => harness.finalizedMetadata.isNotEmpty);

      expect(harness.finalizedMetadata.single['replyTo'], 109);
      expect(harness.finalizedMetadata.single.containsKey('threadId'), isFalse);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  testWidgets('Giphy selection sends a reference and keeps the composer', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);
    final giphy = _giphyRepository();
    addTearDown(giphy.close);

    await tester.pumpWidget(
      harness.app(
        overrides: <Override>[
          giphyRepositoryProvider.overrideWith((ref, accountId) async {
            expect(accountId, harness.account.id);
            return giphy;
          }),
        ],
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('open-emoji-picker')));
    await _pumpTransition(tester);
    // The picker expands above the compose row instead of covering it: the
    // line being typed into has to stay on screen while picking.
    expect(find.byKey(const Key('inline-emoji-panel')), findsOneWidget);
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('inline-emoji-panel'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('chat-composer'))).dy),
    );
    await tester.tap(find.byKey(const Key('emoji-category-people')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-choice-waving-hand')));
    await _pumpTransition(tester);
    expect(_composer(tester).text, '👋');
    // The picker stays open for a second pick; it is the close button that
    // dismisses it.
    expect(find.byKey(const Key('emoji-close')), findsOneWidget);
    await tester.tap(find.byKey(const Key('emoji-close')));
    await _pumpTransition(tester);
    expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);

    await tester.tap(find.byKey(const Key('open-giphy-picker')));
    final gif = find.byKey(
      const ValueKey<String>('giphy-thumbnail-https://giphy.com/gifs/wave'),
    );
    await _pumpUntil(tester, () => gif.evaluate().isNotEmpty);
    await _pumpTransition(tester);
    final thumbnailImage = tester.widget<Image>(
      find.descendant(of: gif, matching: find.byType(Image)),
    );
    final resizedThumbnail = thumbnailImage.image as ResizeImage;
    expect(resizedThumbnail.width, 480);
    expect(resizedThumbnail.height, 480);
    final pickerRect = tester.getRect(find.byType(GiphyPicker));
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(pickerRect.top, greaterThanOrEqualTo(0));
    expect(pickerRect.bottom, lessThanOrEqualTo(viewportHeight));
    await tester.ensureVisible(gif);
    await tester.pump();
    await tester.tap(gif);
    await _pumpTransition(tester);
    await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);

    // The GIF travels as a reference the bubble renders, so nothing is
    // uploaded into the user's own storage.
    expect(harness.sentMessages, <String>['https://giphy.com/gifs/wave']);
    expect(harness.uploadedAttachments, isEmpty);
    expect(harness.finalizedFileNames, isEmpty);
    // Text already typed must survive sending a GIF.
    expect(_composer(tester).text, '👋');

    await _pumpUntil(tester, () => _sendButtonEnabled(tester));
    await tester.tap(find.byKey(const Key('send-message-gesture')));
    await _pumpUntil(
      tester,
      () => harness.sentMessages.length == 2 && _composer(tester).text.isEmpty,
    );

    expect(harness.sentMessages.last, '👋');
    expect(_composer(tester).text, isEmpty);
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
  });

  testWidgets(
    'unavailable Giphy integration becomes an honest disabled state',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);

      await tester.pumpWidget(
        harness.app(
          overrides: <Override>[
            giphyRepositoryProvider.overrideWith(
              (ref, accountId) async => null,
            ),
          ],
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .byIcon(Icons.chat_bubble_outline_rounded)
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('open-giphy-picker')));
      await _pumpUntil(tester, () {
        final button = tester.widget<IconButton>(
          find.byKey(const Key('open-giphy-picker')),
        );
        return button.onPressed == null &&
            button.tooltip == 'GIFs are not available on this server.';
      });

      final button = tester.widget<IconButton>(
        find.byKey(const Key('open-giphy-picker')),
      );
      expect(button.onPressed, isNull);
      expect(button.tooltip, 'GIFs are not available on this server.');
      expect(find.byType(GiphyPicker), findsNothing);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
  );

  testWidgets(
    'first Giphy tap keeps the probe alive before the watched frame',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final probeClient = _ControlledGiphyClient();
      addTearDown(probeClient.close);
      var factoryInvocations = 0;

      await tester.pumpWidget(
        harness.app(
          overrides: <Override>[
            giphyRepositoryFactoryProvider.overrideWithValue(({
              required ServerBase server,
              required GiphyAuthorization authorization,
            }) {
              factoryInvocations++;
              return HttpGiphyRepository(
                server: server,
                authorization: authorization,
                client: probeClient,
              );
            }),
          ],
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => _giphyButtonEnabled(tester));

      await tester.tap(find.byKey(const Key('open-giphy-picker')));
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 600; attempt++) {
          if (probeClient.requestStarted.isCompleted) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      final startedBeforeFrame = probeClient.requestStarted.isCompleted;

      await tester.pump();
      await _pumpUntil(tester, () => probeClient.requestStarted.isCompleted);
      expect(find.byKey(const Key('pick-image-attachment')), findsOneWidget);
      probeClient.complete(_giphyResponse());
      await _pumpUntil(
        tester,
        () => find.byType(GiphyPicker).evaluate().isNotEmpty,
      );

      expect(startedBeforeFrame, isTrue);
      expect(factoryInvocations, 1);
      expect(probeClient.closed, isFalse);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
  );

  testWidgets(
    'a completed Giphy probe cannot cross a changed account or room scope',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final probeClient = _ControlledGiphyClient();
      addTearDown(probeClient.close);
      final factoryOverride = giphyRepositoryFactoryProvider.overrideWithValue(
        ({
          required ServerBase server,
          required GiphyAuthorization authorization,
        }) {
          return HttpGiphyRepository(
            server: server,
            authorization: authorization,
            client: probeClient,
          );
        },
      );

      await tester.pumpWidget(
        harness.app(overrides: <Override>[factoryOverride]),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => _giphyButtonEnabled(tester));
      await tester.tap(find.byKey(const Key('open-giphy-picker')));
      await _pumpUntil(tester, () => probeClient.requestStarted.isCompleted);

      final accountB = harness.account.copyWith(
        id: 'account-b',
        serverUrl: 'https://cloud-b.example.invalid',
        loginName: 'fixture-user-b',
      );
      final conversationB = harness.conversation.copyWith(
        accountId: accountB.id,
        token: 'roomb123',
        displayName: 'Room B',
      );
      await tester.pumpWidget(
        harness.app(
          account: accountB,
          conversation: conversationB,
          overrides: <Override>[factoryOverride],
        ),
      );
      await tester.pump();

      probeClient.complete(_giphyResponse());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();

      expect(find.byType(GiphyPicker), findsNothing);
      expect(harness.sentMessages, isEmpty);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
  );
  testWidgets('a bare Enter sends and Shift+Enter does not, in the real pane', (
    tester,
  ) async {
    // The rule itself is asserted in `composer_enter_key_test.dart`. What
    // only the real pane can show is that the `Focus` around the field sees
    // Enter at all, rather than the multiline field swallowing it first.
    // Reset inside the body, not in a tearDown: the invariant that catches
    // a leaked debug variable runs before tearDowns do.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('chat-composer')));
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('chat-composer')),
      'ctrl-free send',
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      harness.sentMessages,
      isEmpty,
      reason: 'Shift+Enter belongs to the field, not to sending',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);

    // Only the send matters here; clearing the composer afterwards is
    // already covered by the emoji test above.
    expect(harness.sentMessages, <String>['ctrl-free send']);
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('Escape backs out of a reply', (tester) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);
    await tester.runAsync(harness.seedReplyMessage);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const Key('chat-message-target-109'))
              .evaluate()
              .isNotEmpty &&
          find.byType(ChatMediaComposer).evaluate().isNotEmpty,
    );
    await tester.longPress(find.byKey(const Key('chat-message-target-109')));
    await _pumpTransition(tester);
    await tester.tap(find.byKey(const Key('message-action-reply')));
    await _pumpTransition(tester);
    expect(find.byKey(const Key('chat-reply-banner')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-composer')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-reply-banner')).evaluate().isEmpty,
    );

    expect(find.byKey(const Key('chat-reply-banner')), findsNothing);
    expect(harness.sentMessages, isEmpty);
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
  }, timeout: const Timeout(Duration(seconds: 20)));
}

TextEditingController _composer(WidgetTester tester) {
  return tester
      .widget<TextField>(find.byKey(const Key('chat-composer')))
      .controller!;
}

bool _sendButtonEnabled(WidgetTester tester) {
  return tester
          .widget<IconButton>(find.byKey(const Key('send-message')))
          .onPressed !=
      null;
}

bool _giphyButtonEnabled(WidgetTester tester) {
  final button = find.byKey(const Key('open-giphy-picker'));
  return button.evaluate().isNotEmpty &&
      tester.widget<IconButton>(button).onPressed != null;
}

/// Pumps until [condition] holds.
///
/// The bound is a net against a hang, not a budget for the work: the chains
/// waited on here span drift, real file I/O and a mocked HTTP round trip, and
/// at the old bound of 100 they outran it on a loaded machine — the media
/// reply test then failed reproducibly while the code was fine. Six hundred
/// rounds is roughly seven seconds, still inside the twenty-second timeout,
/// and the work itself finishes in three.
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 600; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}

Future<void> _pumpTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _addHarnessTearDown(
  WidgetTester tester,
  _ComposerHarness harness,
) {
  addTearDown(() async {
    await tester.runAsync(harness.close);
  });
}

Future<void> _unmountComposer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

final class _ComposerHarness {
  _ComposerHarness({
    required this.database,
    required this.account,
    required this.conversation,
    required this.vault,
    required this.api,
    required this.sentMessages,
    required this.sourceStore,
    required this.attachmentService,
    required this.attachmentClient,
    required this.attachmentRoot,
    required this.uploadedAttachments,
    required this.finalizedFileNames,
    required this.finalizedMetadata,
  });

  final AppDatabase database;
  final StoredAccount account;
  final CachedConversation conversation;
  final MemoryCredentialVault vault;
  final HttpNextcloudApi api;
  final List<String> sentMessages;
  final DurableAttachmentSourceStore sourceStore;
  final AttachmentService attachmentService;
  final http.Client attachmentClient;
  final Directory attachmentRoot;
  final List<List<int>> uploadedAttachments;
  final List<String> finalizedFileNames;
  final List<Map<String, Object?>> finalizedMetadata;

  static Future<_ComposerHarness> create() async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final roomJson = _conversationRoomJson();
    final room = ConversationRoom.fromJson(roomJson);
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: room.token.value,
            displayName: room.displayName,
            description: room.description,
            lastActivity: room.lastActivity,
            unreadMessages: room.unreadMessages,
            favorite: room.isFavorite,
            readOnly: Value(room.readOnly),
            roomType: Value(room.type),
            roomName: Value(room.name),
            objectType: Value(room.objectType),
            avatarVersion: Value(room.avatarVersion),
            isCustomAvatar: Value(room.isCustomAvatar),
            rawJson: jsonEncode(roomJson),
          ),
        );
    final conversation = await database
        .select(database.cachedConversations)
        .getSingle();
    final vault = MemoryCredentialVault()
      ..values[account.id] = 'fixture-app-password';
    final sentMessages = <String>[];
    final uploadedAttachments = <List<int>>[];
    final finalizedFileNames = <String>[];
    final finalizedMetadata = <Map<String, Object?>>[];
    final attachmentRoot = await Directory.systemTemp.createTemp(
      'nctalk-composer-attachments-',
    );
    final sourceStore = DurableAttachmentSourceStore(root: attachmentRoot);
    await sourceStore.initialize();
    final attachmentClient = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
        return http.Response.bytes(_attachmentProbeSuccess(), 200);
      }
      if (request.method == 'PUT') {
        uploadedAttachments.add(List<int>.from(request.bodyBytes));
        return http.Response('', 201);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/attachment')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        final fileName = body['fileName']! as String;
        finalizedFileNames.add(fileName);
        finalizedMetadata.add(
          Map<String, Object?>.from(
            jsonDecode(body['talkMetaData']! as String) as Map<String, Object?>,
          ),
        );
        return http.Response.bytes(_attachmentFinalizeSuccess(fileName), 200);
      }
      fail('Unexpected attachment request: ${request.method} ${request.url}');
    });
    final attachmentService = AttachmentService(
      repository: AttachmentRepository(database),
      credentials: vault,
      releaseSource: (source) => sourceStore.discard(source.handle),
      transport: HttpAttachmentTransport(
        client: attachmentClient,
        sourceProvider: sourceStore,
      ),
      watchConfirmationCandidates: () =>
          const Stream<AttachmentConfirmationSnapshot>.empty(),
      confirmationRetryDelays: const <Duration>[Duration(hours: 1)],
    );
    await attachmentService.ready;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_attachmentCapabilities()), 200);
        }
        if (request.method == 'POST') {
          sentMessages.add(request.bodyFields['message']!);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(
                _sendResponse(
                  referenceId: request.bodyFields['referenceId']!,
                  message: request.bodyFields['message']!,
                ),
              ),
            ),
            201,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }
        if (request.url.path.contains('/avatar/')) {
          return http.Response('', 404);
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/apps/spreed/api/v1/chat/rooma123')) {
          return http.Response('', 304);
        }
        return http.Response('', 404);
      }),
    );
    return _ComposerHarness(
      database: database,
      account: account,
      conversation: conversation,
      vault: vault,
      api: api,
      sentMessages: sentMessages,
      sourceStore: sourceStore,
      attachmentService: attachmentService,
      attachmentClient: attachmentClient,
      attachmentRoot: attachmentRoot,
      uploadedAttachments: uploadedAttachments,
      finalizedFileNames: finalizedFileNames,
      finalizedMetadata: finalizedMetadata,
    );
  }

  Future<void> seedReplyMessage() async {
    final room = _conversationRoomJson();
    final message = Map<String, Object?>.from(
      room['lastMessage']! as Map<String, Object?>,
    );
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: conversation.token,
            messageId: message['id']! as int,
            actorType: message['actorType']! as String,
            actorId: message['actorId']! as String,
            actorDisplayName: message['actorDisplayName']! as String,
            timestamp: message['timestamp']! as int,
            systemMessage: message['systemMessage']! as String,
            messageType: message['messageType']! as String,
            referenceId: message['referenceId']! as String,
            displayText: message['message']! as String,
            deleted: false,
            rawJson: jsonEncode(message),
          ),
        );
  }

  Widget app({
    StoredAccount? account,
    CachedConversation? conversation,
    bool wrapInScaffold = false,
    List<Override> overrides = const <Override>[],
  }) {
    return ProviderScope(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        attachmentSourceProvider.overrideWith((ref) async => sourceStore),
        attachmentServiceProvider.overrideWith(
          (ref) async => attachmentService,
        ),
        ...overrides,
      ],
      child: localizedTestApp(
        home: wrapInScaffold
            ? Scaffold(
                body: ChatRoomPane(
                  account: account ?? this.account,
                  conversation: conversation ?? this.conversation,
                ),
              )
            : ChatRoomPane(
                account: account ?? this.account,
                conversation: conversation ?? this.conversation,
              ),
      ),
    );
  }

  Future<void> close() async {
    await api.close();
    await attachmentService.close();
    attachmentClient.close();
    await database.close();
    if (await attachmentRoot.exists()) {
      await attachmentRoot.delete(recursive: true);
    }
  }
}

HttpGiphyRepository _giphyRepository() {
  return HttpGiphyRepository(
    server: ServerBase.parse('https://cloud.example.invalid'),
    authorization: const GiphyAuthorization(
      loginName: 'fixture-user',
      appPassword: 'fixture-app-password',
    ),
    client: MockClient((request) async {
      if (request.url.path.endsWith('/gifs/trending')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': <String, Object?>{
                'entries': <Object?>[
                  <String, Object?>{
                    'thumbnailUrl':
                        'https://cloud.example.invalid/'
                        'apps/integration_giphy/gif/wave',
                    'title': 'Wave',
                    'subline': 'Fixture author',
                    'resourceUrl': 'https://giphy.com/gifs/wave',
                  },
                ],
                'cursor': 1,
              },
            },
          }),
          200,
        );
      }
      if (request.url.path == '/apps/integration_giphy/gif/wave') {
        return http.Response.bytes(
          _animatedGif,
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }
      if (request.url.path.endsWith('/ocs/v2.php/references/resolve')) {
        return http.Response(
          _giphyReferenceResponse(Uri.parse('https://giphy.com/gifs/wave')),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      if (request.url.path.endsWith(
        '/index.php/apps/integration_giphy/gif/proxy',
      )) {
        return http.Response.bytes(
          _animatedGif,
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }
      if (request.url.path ==
          '/apps/integration_giphy/img/powered-by-giphy.gif') {
        return http.Response.bytes(
          base64Decode('R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=='),
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }
      return http.Response('', 404);
    }),
  );
}

Map<String, Object?> _attachmentCapabilities() {
  final result = capabilitiesJson(
    talkFeatures: const <String>[
      'conversation-v4',
      'chat-v2',
      'chat-reference-id',
      'chat-replies',
      'geo-location-sharing',
    ],
  );
  final ocs = result['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  final config = spreed['config']! as Map<String, Object?>;
  config['attachments'] = <String, Object?>{
    'allowed': true,
    'conversation-subfolders': true,
  };
  return result;
}

List<int> _attachmentProbeSuccess() => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'folder': 'Talk/Fixture/Draft',
        'renames': <Object?>[],
      },
    },
  }),
);

List<int> _attachmentFinalizeSuccess(String fileName) => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'renames': <Object?>[
          <String, Object?>{fileName: fileName},
        ],
      },
    },
  }),
);

String _giphyReferenceResponse(Uri resourceUrl) => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'references': <String, Object?>{
        resourceUrl.toString(): <String, Object?>{
          'richObjectType': 'integration_giphy_gif',
          'richObject': <String, Object?>{
            'id': 'fixture-wave',
            'proxied_url':
                'https://cloud.example.invalid/index.php/apps/'
                'integration_giphy/gif/proxy',
            'images': <String, Object?>{
              'fixed_width': <String, Object?>{'width': '1', 'height': '1'},
            },
          },
        },
      },
    },
  },
});

final _animatedGif = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwA'
  'AAAAAQABAAACAkQBACH5BAAKAAAALAAAAAABAAEAAAICTAEAOw==',
);

String _giphyResponse() => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'entries': <Object?>[
        <String, Object?>{
          'thumbnailUrl':
              'https://cloud.example.invalid/apps/integration_giphy/gif/wave',
          'title': 'Wave',
          'subline': 'Fixture author',
          'resourceUrl': 'https://giphy.com/gifs/wave',
        },
      ],
      'cursor': 1,
    },
  },
});

final class _ControlledGiphyClient extends http.BaseClient {
  final requestStarted = Completer<void>();
  final _response = Completer<http.StreamedResponse>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!requestStarted.isCompleted) {
      requestStarted.complete();
    }
    return _response.future;
  }

  void complete(String body) {
    if (_response.isCompleted) {
      return;
    }
    _response.complete(
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(body)),
        200,
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      ),
    );
  }

  @override
  void close() {
    if (closed) {
      return;
    }
    closed = true;
    if (!_response.isCompleted) {
      _response.completeError(
        http.ClientException('fixture connection cancelled'),
      );
    }
    super.close();
  }
}

Map<String, Object?> _conversationRoomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  final lastMessage = Map<String, Object?>.from(
    room['lastMessage']! as Map<String, Object?>,
  );
  lastMessage['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}

Map<String, Object?> _sendResponse({
  required String referenceId,
  required String message,
}) {
  final response =
      readFixtureJson('chat-messages/fixtures/send-success.response.json')!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  data['referenceId'] = referenceId;
  data['message'] = message;
  return response;
}
