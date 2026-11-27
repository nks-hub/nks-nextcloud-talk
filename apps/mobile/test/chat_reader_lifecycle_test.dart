import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'closing a chat cancels a pending jump and late connectivity wake',
    (tester) async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      final account = await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final vault = MemoryCredentialVault()
        ..values[account.id] = 'fixture-password';
      final rooms =
          readFixtureJson(
                'conversation-list/fixtures/conversations-full.response.json',
              )
              as Map<String, Object?>;
      final room =
          ((rooms['ocs']! as Map)['data'] as List).first
              as Map<String, Object?>;
      await accounts.applyAuthoritativeConversation(
        account.id,
        ConversationRoom.fromJson(room),
      );
      final conversation = await database
          .select(database.cachedConversations)
          .getSingle();
      const targetId = 18;
      final message = {
        ...room['lastMessage']! as Map<String, Object?>,
        'id': targetId,
        'message': 'Jump target after reopening',
        'threadId': targetId,
      };
      final capabilities = capabilitiesJson(
        talkFeatures: const [
          'conversation-v4',
          'chat-v2',
          'chat-reference-id',
          'chat-get-context',
        ],
      );
      final heldContext = Completer<http.Response>();
      var contextReads = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(capabilities), 200);
          }
          if (request.url.path.endsWith('/context')) {
            if (++contextReads == 1) return heldContext.future;
            return http.Response(
              jsonEncode({
                'ocs': {
                  'meta': {'status': 'ok', 'statuscode': 200},
                  'data': [message],
                },
              }),
              200,
              headers: const {'X-Chat-Last-Given': '19'},
            );
          }
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final showRoom = ValueNotifier(true);
      addTearDown(showRoom.dispose);
      final wakes = StreamController<void>.broadcast();
      addTearDown(wakes.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            accountRepositoryProvider.overrideWithValue(accounts),
            credentialVaultProvider.overrideWithValue(vault),
            nextcloudApiProvider.overrideWithValue(api),
            connectivityWakeEventsProvider.overrideWithValue(wakes.stream),
            chatAttachmentDependenciesProvider.overrideWith(
              (_, _) async =>
                  throw StateError('Attachments are outside this test'),
            ),
          ],
          child: localizedTestApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: showRoom,
              builder: (context, open, _) => open
                  ? ChatRoomPane(
                      account: account,
                      conversation: conversation,
                      jumpToMessageId: targetId,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await pumpUntilCondition(tester, () => contextReads == 1);
      wakes.add(null);
      await tester.pump();

      showRoom.value = false;
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ChatRoomPane), findsNothing);
      heldContext.complete(http.Response('', 503));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(contextReads, 1);

      showRoom.value = true;
      final target = find.byKey(const Key('chat-message-target-18'));
      await pumpUntilCondition(tester, () => target.evaluate().isNotEmpty);
      expect(contextReads, 2);
      expect(target, findsOneWidget);
      expect(find.byKey(const Key('chat-jump-not-found')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    },
  );
}
