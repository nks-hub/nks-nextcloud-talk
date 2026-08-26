import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'password-a';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
      talkFeatures: const <String>{'clear-history'},
    );
    await _seedCachedChat(database);
  });

  tearDown(() => database.close());

  RoomSettingsService serviceWith(MockClient client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return RoomSettingsService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: vault,
      api: api,
    );
  }

  test(
    'uses fresh capability and applies 202 only after DELETE success',
    () async {
      final calls = <String>[];
      final service = serviceWith(
        MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                capabilitiesJson(talkFeatures: const ['clear-history']),
              ),
              200,
            );
          }
          expect(request.method, 'DELETE');
          expect(request.bodyBytes, isEmpty);
          return _ocsResponse(
            statusCode: 202,
            data: _historyClearedMessage(),
            headers: const {'X-Chat-Last-Common-Read': '41'},
          );
        }),
      );

      final result = await service.clearHistory(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(result.externalCopiesMayRemain, isTrue);
      expect(calls, hasLength(2));
      expect(calls.first, endsWith('/cloud/capabilities'));
      expect(calls.last, endsWith('/api/v1/chat/rooma123'));
      final messages = await database.select(database.cachedChatMessages).get();
      expect(messages, hasLength(1));
      expect(messages.single.messageId, 42);
      expect(messages.single.systemMessage, 'history_cleared');
    },
  );

  test(
    'does not DELETE or mutate cache without the exact capability',
    () async {
      var deletes = 0;
      final service = serviceWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(capabilitiesJson(talkFeatures: const [])),
              200,
            );
          }
          deletes++;
          return http.Response('', 500);
        }),
      );

      await expectLater(
        service.clearHistory(accountId: 'account-a', roomToken: 'rooma123'),
        _throwsRoomSettingsError(RoomSettingsError.invalidResponse),
      );

      expect(deletes, 0);
      expect(
        await database.select(database.cachedChatMessages).get(),
        hasLength(1),
      );
    },
  );

  test('keeps the local cache intact when the server refuses', () async {
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(capabilitiesJson(talkFeatures: const ['clear-history'])),
            200,
          );
        }
        return _ocsResponse(
          statusCode: 403,
          status: 'failure',
          data: const <Object?>[],
        );
      }),
    );

    await expectLater(
      service.clearHistory(accountId: 'account-a', roomToken: 'rooma123'),
      _throwsRoomSettingsError(RoomSettingsError.forbidden),
    );

    final messages = await database.select(database.cachedChatMessages).get();
    expect(messages, hasLength(1));
    expect(messages.single.messageId, 4);
    expect(await database.select(database.chatScopes).get(), hasLength(1));
  });
}

Matcher _throwsRoomSettingsError(RoomSettingsError code) => throwsA(
  isA<RoomSettingsException>().having((error) => error.code, 'code', code),
);

Future<void> _seedCachedChat(AppDatabase database) async {
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 4,
          actorType: 'users',
          actorId: 'user-a',
          actorDisplayName: 'User A',
          timestamp: 4,
          systemMessage: '',
          messageType: 'comment',
          referenceId: '',
          displayText: 'old',
          deleted: false,
          rawJson: jsonEncode(_ordinaryMessage()),
        ),
      );
  await database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          scopeKey: 'root',
          historyCursor: '4',
          futureCursor: '4',
          lastCommonRead: '4',
          lastReadMessage: 4,
          unreadMessages: 0,
          hasHistory: false,
          futureConverged: true,
          blocksJson: '[{"start":"4","end":"4"}]',
        ),
      );
}

http.Response _ocsResponse({
  required int statusCode,
  String status = 'ok',
  required Object? data,
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'status': status, 'statuscode': statusCode, 'message': status},
      'data': data,
    },
  }),
  statusCode,
  headers: headers,
);

Map<String, Object?> _ordinaryMessage() => <String, Object?>{
  ..._historyClearedMessage(),
  'id': 4,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'message': 'old',
};

Map<String, Object?> _historyClearedMessage() => <String, Object?>{
  'id': 42,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'user-a',
  'actorDisplayName': 'User A',
  'timestamp': 1787695200,
  'systemMessage': 'history_cleared',
  'messageType': 'system',
  'isReplyable': false,
  'referenceId': '',
  'message': 'You cleared the history of the conversation',
  'messageParameters': <String, Object?>{},
};
