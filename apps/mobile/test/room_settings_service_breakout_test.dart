import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

Map<String, Object?> _room(String token) {
  final root =
      jsonDecode(
            File(
              '../../contracts/conversation-list/fixtures/'
              'conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(
    rooms.first! as Map<String, Object?>,
  )..['token'] = token;
  // The decoder refuses a preview whose token does not name its own room.
  final preview = room['lastMessage'];
  if (preview is Map<String, Object?>) {
    room['lastMessage'] = Map<String, Object?>.from(preview)
      ..['token'] = token;
  }
  return room;
}

http.Response _administrationResponse() => http.Response.bytes(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': _room('parent01'),
      },
    }),
  ),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

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
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'breakout-rooms-v1'},
      createdAt: DateTime.utc(2026),
    );
    for (final token in const <String>['parent01', 'child001', 'child002']) {
      await accounts.applyAuthoritativeConversation(
        'account-a',
        ConversationRoom.fromJson(_room(token)),
      );
    }
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

  Future<Set<String>> cachedTokens() async {
    final rows = await (database.select(
      database.cachedConversations,
    )..where((row) => row.accountId.equals('account-a'))).get();
    return rows.map((row) => row.token).toSet();
  }

  test('removing breakout rooms drops their conversations too', () async {
    var deletes = 0;
    final service = serviceWith(
      MockClient((request) async {
        if (request.method == 'DELETE' &&
            request.url.path.contains('/breakout-rooms/parent01')) {
          deletes++;
          return _administrationResponse();
        }
        return http.Response('', 404);
      }),
    );

    await service.removeBreakoutRooms(
      accountId: 'account-a',
      roomToken: 'parent01',
      childTokens: const <String>['child001', 'child002'],
    );

    expect(deletes, 1);
    expect(await cachedTokens(), <String>{'parent01'});
  });

  test('a failed removal keeps the breakout conversations', () async {
    final service = serviceWith(
      MockClient((request) async => http.Response('', 403)),
    );

    await expectLater(
      service.removeBreakoutRooms(
        accountId: 'account-a',
        roomToken: 'parent01',
        childTokens: const <String>['child001', 'child002'],
      ),
      throwsA(isA<RoomSettingsException>()),
    );

    expect(await cachedTokens(), <String>{
      'parent01',
      'child001',
      'child002',
    });
  });
}
