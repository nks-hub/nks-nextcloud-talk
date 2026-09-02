import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Covers the desktop "note to self" unread badge that never cleared.
///
/// The room's own conversation-list row can be resynced (a periodic full
/// account refresh, running independently of the open chat's own live loop)
/// after the visible message was already marked read. When that resync
/// lands with a server `unreadMessages` that had not yet caught up on the
/// read, the cached row goes back to unread with no newer message to notify
/// the room about — the one-shot "already handled this message id" flag must
/// not be the only thing standing between that and a stuck badge.
void main() {
  testWidgets(
    'auto-read retries after a resync restores unread on the same message',
    (tester) async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      final chat = ChatRepository(database);
      final vault = MemoryCredentialVault();
      final account = await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user-a',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
      );
      vault.values[account.id] = 'fixture-app-password-never-use';

      final roomWire = _noteToSelfRoomJson();
      final room = ConversationRoom.fromJson(roomWire);
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
              roomType: Value(room.type),
              rawJson: jsonEncode(roomWire),
            ),
          );
      final conversation = (await chat.getConversation(
        accountId: account.id,
        roomToken: room.token.value,
      ))!;

      var futureRequests = 0;
      final readTargets = <int>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                capabilitiesJson(
                  talkFeatures: const <String>[
                    'conversation-v4',
                    'chat-v2',
                    'chat-read-marker',
                    'chat-read-last',
                    'chat-keep-notifications',
                  ],
                ),
              ),
              200,
            );
          }
          if (request.url.path.contains('/avatar/')) {
            return http.Response('', 404);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/chat/rooma123/read')) {
            final target = int.parse(
              Uri.splitQueryString(request.body)['lastReadMessage']!,
            );
            readTargets.add(target);
            return http.Response(jsonEncode(_readMarkerResponse(target)), 200);
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }

          futureRequests++;
          if (futureRequests == 1) {
            return _messageResponse(120, 'Note to self');
          }
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            credentialVaultProvider.overrideWithValue(vault),
            nextcloudApiProvider.overrideWithValue(api),
            connectivityWakeEventsProvider.overrideWithValue(
              const Stream<void>.empty(),
            ),
          ],
          child: localizedTestApp(
            home: ChatRoomPane(account: account, conversation: conversation),
          ),
        ),
      );

      await _pumpUntil(tester, () => readTargets.length == 1);
      expect(readTargets, [120]);
      final afterFirstRead = await chat.getConversation(
        accountId: account.id,
        roomToken: room.token.value,
      );
      expect(afterFirstRead?.unreadMessages, 0);

      // A conversation-list resync (independent of this room's own live
      // loop) lands after the read, still reporting the server's
      // not-yet-caught-up unread count for the same last message.
      await (database.update(database.cachedConversations)..where(
            (row) =>
                row.accountId.equals(account.id) &
                row.token.equals(room.token.value),
          ))
          .write(const CachedConversationsCompanion(unreadMessages: Value(3)));
      final afterStaleResync = await chat.getConversation(
        accountId: account.id,
        roomToken: room.token.value,
      );
      expect(afterStaleResync?.unreadMessages, 3);

      await _pumpUntil(tester, () => readTargets.length == 2);
      expect(readTargets, [120, 120]);
      final afterRetry = await chat.getConversation(
        accountId: account.id,
        roomToken: room.token.value,
      );
      expect(afterRetry?.unreadMessages, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
}

Map<String, Object?> _noteToSelfRoomJson() {
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
  )..['id'] = 109;
  room['lastMessage'] = lastMessage;
  room['type'] = 6;
  room['unreadMessages'] = 2;
  room['lastReadMessage'] = 40;
  return room;
}

http.Response _messageResponse(int messageId, String message) {
  final root =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-future.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final messages = ocs['data']! as List<Object?>;
  final wire =
      Map<String, Object?>.from(messages.first! as Map<String, Object?>)
        ..['id'] = messageId
        ..['timestamp'] = 1770000000 + messageId
        ..['message'] = message
        ..['messageParameters'] = <String, Object?>{};
  ocs['data'] = <Object?>[wire];
  return http.Response(
    jsonEncode(root),
    200,
    headers: <String, String>{
      'X-Chat-Last-Given': '$messageId',
      'X-Chat-Last-Common-Read': '109',
    },
  );
}

Map<String, Object?> _readMarkerResponse(int messageId) => {
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': {
      'token': 'rooma123',
      'lastReadMessage': messageId,
      'lastCommonReadMessage': messageId,
      'unreadMessages': 0,
    },
  },
};

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}
