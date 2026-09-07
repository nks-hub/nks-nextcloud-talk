import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/features/chat/poll_dialog.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'poll_test_support.dart';
import 'test_support.dart';

void main() {
  testWidgets(
    'an open poll survives recycling its chat cell and still permits export',
    (tester) async {
      final sender = FakePollSender(
        access: const PollManagementAccess(canClose: true, canExport: true),
      );
      final visible = ValueNotifier(true);
      final locale = ValueNotifier(const Locale('en'));
      addTearDown(visible.dispose);
      addTearDown(locale.dispose);
      var roomCurrent = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [pollServiceProvider.overrideWithValue(sender)],
          child: ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (_, value, _) => localizedTestApp(
              locale: value,
              home: Scaffold(
                body: PollInteractionScope(
                  roomKey: const (
                    accountId: 'account-a',
                    roomToken: 'rooma123',
                    threadId: null,
                  ),
                  isCurrent: () => roomCurrent,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: visible,
                    builder: (_, show, _) => show
                        ? ChatMessageContent(
                            account: _account,
                            message: _message,
                            fallbackText: '',
                            foregroundColor: Colors.black,
                          )
                        : const Text('Message cell recycled'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-poll-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('poll-end')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('poll-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Poll ended'), findsOneWidget);

      visible.value = false;
      locale.value = const Locale('cs');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('poll-viewer-dialog')), findsOneWidget);
      expect(
        tester
            .widget<PopupMenuButton<PollExportFormat>>(
              find.byKey(const Key('poll-export')),
            )
            .enabled,
        isTrue,
      );

      await tester.tap(find.byKey(const Key('poll-export')));
      await tester.pumpAndSettle();
      roomCurrent = false;
      await tester.tap(find.text('Exportovat CSV'));
      await tester.pumpAndSettle();
      expect(
        sender.exports,
        isEmpty,
        reason: 'recycling is allowed, leaving the owning room is not',
      );
    },
  );
}

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 0,
);

final _message = ChatMessage.fromJson(<String, Object?>{
  'id': 42,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-author',
  'actorDisplayName': 'Fixture author',
  'timestamp': 1767225600,
  'systemMessage': 'object_shared',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-42',
  'message': '{object}',
  'markdown': false,
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'talk-poll',
      'id': '7',
      'name': 'Lunch?',
    },
  },
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
});
