import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault credentials;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    credentials = MemoryCredentialVault()
      ..values['account-a'] = 'fixture-password';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 8, 30),
    );
  });

  tearDown(() => database.close());

  for (final testCase
      in <({StandaloneConversationType type, String wireType, String name})>[
        (
          type: StandaloneConversationType.group,
          wireType: '2',
          name: 'Project room',
        ),
        (
          type: StandaloneConversationType.public,
          wireType: '3',
          name: 'Town hall',
        ),
      ]) {
    test('creates ${testCase.type.name} without invite fields', () async {
      late http.Request captured;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode(_createdRoomResponse()), 201);
        }),
      );
      addTearDown(api.close);
      final service = HttpNewConversationService(
        accounts: accounts,
        credentials: credentials,
        api: api,
      );

      final token = await service.createStandaloneConversation(
        accountId: 'account-a',
        type: testCase.type,
        roomName: testCase.name,
      );

      expect(token.value, isNotEmpty);
      expect(captured.method, 'POST');
      expect(captured.bodyFields, <String, String>{
        'roomType': testCase.wireType,
        'roomName': testCase.name,
      });
    });
  }
}

Map<String, Object?> _createdRoomResponse() {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 201,
        'message': 'Created',
      },
      'data': rooms.first,
    },
  };
}
