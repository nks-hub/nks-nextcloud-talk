import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'inline link has one semantic node, 48dp target, and 200% wrapping',
    (tester) async {
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(_app(TextScaler.noScaling));

      final link = find.descendant(
        of: find.byKey(const Key('message-content')),
        matching: find.byType(InkWell),
      );
      expect(link, findsOneWidget);
      final linkSize = tester.getSize(link);
      expect(linkSize.width, greaterThanOrEqualTo(48));
      expect(linkSize.height, greaterThanOrEqualTo(48));

      final linkSemantics = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.link == true &&
            widget.properties.label == 'Open docs',
      );
      expect(linkSemantics, findsOneWidget);
      final semanticNode = tester.getSemantics(linkSemantics);
      expect(semanticNode.childrenCount, 0);
      expect(
        semanticNode,
        matchesSemantics(label: 'Open docs', isLink: true, hasTapAction: true),
      );

      await tester.pumpWidget(_app(const TextScaler.linear(2)));
      final contentSize = tester.getSize(
        find.byKey(const Key('message-content')),
      );
      expect(contentSize.width, lessThanOrEqualTo(160));
      expect(contentSize.height, greaterThan(linkSize.height));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('reply preview can be hidden without hiding the reply body', (
    tester,
  ) async {
    await tester.pumpWidget(_app(TextScaler.noScaling, message: _replyMessage));

    expect(find.byKey(const Key('chat-reply-preview-43')), findsOneWidget);
    expect(find.text('Reply body'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        TextScaler.noScaling,
        message: _replyMessage,
        showReplyPreview: false,
      ),
    );

    expect(find.byKey(const Key('chat-reply-preview-43')), findsNothing);
    expect(find.text('Reply body'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  TextScaler textScaler, {
  ChatMessage? message,
  bool showReplyPreview = true,
}) {
  return localizedTestApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: MediaQuery(
          data: MediaQueryData(
            size: const Size(200, 400),
            textScaler: textScaler,
          ),
          child: SizedBox(
            width: 160,
            child: ChatMessageContent(
              key: const Key('message-content'),
              account: _account,
              message: message ?? _message,
              fallbackText: '',
              foregroundColor: Colors.black,
              showReplyPreview: showReplyPreview,
            ),
          ),
        ),
      ),
    ),
  );
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

final _message = ChatMessage.fromJson(<String, Object?>{
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
  'message': 'Before [Open docs](https://docs.example.invalid/guide) after',
  'messageParameters': <String, Object?>{},
  'markdown': true,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
});

final _replyMessage = ChatMessage.fromJson(<String, Object?>{
  'id': 43,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-replier',
  'actorDisplayName': 'Fixture replier',
  'timestamp': 1767225660,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-43',
  'message': 'Reply body',
  'messageParameters': <String, Object?>{},
  'markdown': false,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
  'threadId': 42,
  'parent': _message.wire,
});
