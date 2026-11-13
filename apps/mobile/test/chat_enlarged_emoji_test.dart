import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/features/chat/emoji_only_message.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

const _uuid = '0b0c4e0a-3f5e-4c53-8a43-2f5d9b7e6a11';

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

ChatMessage _message(String text, String referenceId) =>
    ChatMessage.fromJson(<String, Object?>{
      'id': 42,
      'token': 'rooma123',
      'actorType': 'users',
      'actorId': 'fixture-author',
      'actorDisplayName': 'Fixture author',
      'timestamp': 1767225600,
      'systemMessage': '',
      'messageType': 'comment',
      'isReplyable': true,
      'referenceId': referenceId,
      'message': text,
      'messageParameters': <String, Object?>{},
      'markdown': true,
      'reactions': <String, Object?>{},
      'reactionsSelf': <Object?>[],
      'deleted': null,
    });

Widget _app(
  ChatMessage message, {
  double width = 300,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return localizedTestApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: MediaQuery(
          data: MediaQueryData(
            size: const Size(400, 800),
            textScaler: textScaler,
          ),
          child: SizedBox(
            width: width,
            child: ChatMessageContent(
              account: _account,
              message: message,
              fallbackText: '',
              foregroundColor: Colors.black,
            ),
          ),
        ),
      ),
    ),
  );
}

double _fontSize(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const Key('chat-enlarged-emoji-42')),
        matching: find.byType(Text),
      ),
    )
    .style!
    .fontSize!;

void main() {
  testWidgets('an emoji without a size marker keeps the jumbo size', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_message('\u{1F44D}', _uuid)));

    expect(_fontSize(tester), enlargedEmojiFontSize);
  });

  testWidgets('each size step grows the emoji further', (tester) async {
    final sizes = <double>[];
    for (var step = 1; step <= ChatEmojiSizeReference.maxStep; step++) {
      final reference = ChatEmojiSizeReference(uuid: _uuid, step: step);
      await tester.pumpWidget(
        _app(_message('\u{1F44D}', reference.referenceId), width: 400),
      );
      sizes.add(_fontSize(tester));
    }

    expect(sizes.first, greaterThan(enlargedEmojiFontSize));
    expect(sizes, orderedEquals([...sizes]..sort()));
    expect(sizes.toSet(), hasLength(ChatEmojiSizeReference.maxStep));
  });

  testWidgets('the marker does nothing to a message with text in it', (
    tester,
  ) async {
    final reference = ChatEmojiSizeReference(uuid: _uuid, step: 3);
    await tester.pumpWidget(
      _app(_message('ok \u{1F44D}', reference.referenceId)),
    );

    expect(find.byKey(const Key('chat-enlarged-emoji-42')), findsNothing);
  });

  testWidgets('the largest step scales down instead of overflowing', (
    tester,
  ) async {
    final reference = ChatEmojiSizeReference(
      uuid: _uuid,
      step: ChatEmojiSizeReference.maxStep,
    );
    await tester.pumpWidget(
      _app(
        _message('\u{1F44D}\u{1F44D}\u{1F44D}\u{1F44D}', reference.referenceId),
        width: 120,
        textScaler: const TextScaler.linear(2),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const Key('chat-enlarged-emoji-42'))).width,
      lessThanOrEqualTo(120),
    );
  });
}
