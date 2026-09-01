import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/features/chat/references/reference_resolver.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'unknown providers render an OpenGraph card that opens the original HTTPS URL',
    (tester) async {
      final resolver = _FakeReferenceResolver((target) async {
        return ReferenceCardData(
          reference: target.reference,
          title: 'Reference title',
          description: 'Reference description',
          richObjectType: 'integration_unknown',
        );
      });
      final opened = <Uri>[];

      await tester.pumpWidget(
        _app(
          _message('[Visible label](https://docs.example.invalid/original)'),
          overrides: [
            referenceResolverProvider.overrideWithValue(resolver),
            referenceUriLauncherProvider.overrideWithValue((uri) async {
              opened.add(uri);
              return true;
            }),
          ],
        ),
      );
      await tester.pump();

      final card = find.byKey(const Key('chat-reference-card-0'));
      expect(card, findsOneWidget);
      expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
      expect(find.text('Reference title'), findsOneWidget);
      expect(find.text('Reference description'), findsOneWidget);
      expect(find.text('docs.example.invalid'), findsOneWidget);
      expect(find.textContaining('spoofed'), findsNothing);

      await tester.tap(card);
      await tester.pump();
      expect(opened, [Uri.parse('https://docs.example.invalid/original')]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the card keeps its hierarchy with long values at 200% text', (
    tester,
  ) async {
    final resolver = _FakeReferenceResolver((target) async {
      return ReferenceCardData(
        reference: target.reference,
        title:
            'مرحبا بالعالم — a title long enough to need both of its lines '
            'and then some more so it has to be cut off',
        description:
            'وصف طويل جدا — a description that keeps going well past '
            'the two lines the card is willing to give it, on purpose',
        richObjectType: 'integration_unknown',
      );
    });

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        _message('https://docs.example.invalid/original'),
        overrides: [
          referenceResolverProvider.overrideWithValue(resolver),
          referenceUriLauncherProvider.overrideWithValue((uri) async => true),
        ],
        textScale: 2,
      ),
    );
    await tester.pump();

    final title = find.byKey(const Key('chat-reference-title-0'));
    final host = find.byKey(const Key('chat-reference-host-0'));
    final description = find.byKey(const Key('chat-reference-description-0'));
    expect(title, findsOneWidget);
    expect(host, findsOneWidget);
    expect(description, findsOneWidget);

    // Title, then source, then description: the source must never end up
    // below the description again.
    expect(
      tester.getTopLeft(host).dy,
      greaterThan(tester.getTopLeft(title).dy),
    );
    expect(
      tester.getTopLeft(description).dy,
      greaterThan(tester.getTopLeft(host).dy),
    );

    // The title outranks the description visually.
    final titleStyle = tester.widget<Text>(title).style!;
    final descriptionStyle = tester.widget<Text>(description).style!;
    expect(titleStyle.fontWeight, FontWeight.w600);
    expect(titleStyle.fontSize! > descriptionStyle.fontSize!, isTrue);

    // A link without a preview image still reserves the same leading slot.
    expect(find.byIcon(Icons.link), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolver failure keeps the ordinary inline link as fallback', (
    tester,
  ) async {
    final resolver = _FakeReferenceResolver((target) async {
      throw const ReferenceResolverException(ReferenceResolverError.network);
    });

    await tester.pumpWidget(
      _app(
        _message('[Visible label](https://docs.example.invalid/original)'),
        overrides: [referenceResolverProvider.overrideWithValue(resolver)],
      ),
    );
    await tester.pump();

    expect(find.text('Visible label'), findsOneWidget);
    expect(find.byKey(const Key('chat-reference-card-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolves at most three distinct non-Giphy HTTPS links', (
    tester,
  ) async {
    final gate = Future<ReferenceCardData?>.value(null);
    final resolver = _FakeReferenceResolver((target) => gate);
    final message = _message(
      '[A](https://a.example.invalid) '
      '[B](https://b.example.invalid) '
      '[A2](https://a.example.invalid) '
      '[GIF](https://giphy.com/gifs/example-fixture) '
      '[C](https://c.example.invalid) '
      '[D](https://d.example.invalid) '
      '[HTTP](http://http.example.invalid)',
    );

    await tester.pumpWidget(
      _app(
        message,
        overrides: [
          referenceResolverProvider.overrideWithValue(resolver),
          giphyReferenceMediaProvider.overrideWith((ref, request) async {
            throw StateError('Giphy is not part of this reference test');
          }),
        ],
      ),
    );
    await tester.pump();

    expect(resolver.targets.map((target) => target.reference).toList(), [
      Uri.parse('https://a.example.invalid'),
      Uri.parse('https://b.example.invalid'),
      Uri.parse('https://c.example.invalid'),
    ]);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  ChatMessage message, {
  required List<Override> overrides,
  double textScale = 1,
}) => ProviderScope(
  overrides: overrides,
  child: localizedTestApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
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
  ),
);

ChatMessage _message(String text) => ChatMessage.fromJson({
  'id': 42,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-author',
  'actorDisplayName': 'Fixture author',
  'timestamp': 1767225600,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-42',
  'message': text,
  'messageParameters': <String, Object?>{},
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
  'markdown': true,
});

final class _FakeReferenceResolver implements ReferenceResolver {
  _FakeReferenceResolver(this._resolve);

  final Future<ReferenceCardData?> Function(ReferenceResolutionTarget target)
  _resolve;
  final List<ReferenceResolutionTarget> targets = [];

  @override
  Future<ReferenceCardData?> resolve(
    ReferenceResolutionTarget target, {
    Future<void>? abortTrigger,
  }) {
    targets.add(target);
    return _resolve(target);
  }
}

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid/nextcloud',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);
