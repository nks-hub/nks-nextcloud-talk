import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

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

  group('open conversations', () {
    test('lists what the server publishes and joins one of them', () async {
      final requests = <http.Request>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/listed-room')) {
            return http.Response(
              jsonEncode({
                'ocs': {
                  'meta': {'statuscode': 200},
                  'data': [
                    {
                      'token': 'open1234',
                      'displayName': 'Open room',
                      'hasPassword': true,
                    },
                  ],
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'ocs': {
                'meta': {'statuscode': 200},
                'data': <String, Object?>{},
              },
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final service = HttpNewConversationService(
        accounts: accounts,
        credentials: credentials,
        api: api,
      );

      final rooms = await service.listOpenConversations(accountId: 'account-a');
      expect(rooms.single.displayName, 'Open room');
      expect(rooms.single.hasPassword, isTrue);

      final token = await service.joinOpenConversation(
        accountId: 'account-a',
        roomToken: rooms.single.token,
        password: 'open sesame',
      );

      expect(token.value, 'open1234');
      expect(
        requests.last.url.path,
        endsWith('/room/open1234/participants/active'),
      );
      expect(requests.last.body, 'password=open+sesame');
      expect(
        requests.every(
          (request) => request.headers.containsKey('Authorization'),
        ),
        isTrue,
      );
    });

    test('a wrong password is reported as such, not as a failure', () async {
      final api = HttpNextcloudApi(
        client: MockClient((_) async => http.Response('', 403)),
      );
      addTearDown(api.close);
      final service = HttpNewConversationService(
        accounts: accounts,
        credentials: credentials,
        api: api,
      );

      await expectLater(
        service.joinOpenConversation(
          accountId: 'account-a',
          roomToken: ConversationToken.parse('open1234', path: r'$.token'),
        ),
        throwsA(
          isA<NewConversationException>().having(
            (error) => error.code,
            'code',
            NewConversationError.passwordRequired,
          ),
        ),
      );
    });

    test('a server without open conversations is not an empty list', () async {
      final api = HttpNextcloudApi(
        client: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(api.close);
      final service = HttpNewConversationService(
        accounts: accounts,
        credentials: credentials,
        api: api,
      );

      await expectLater(
        service.listOpenConversations(accountId: 'account-a'),
        throwsA(
          isA<NewConversationException>().having(
            (error) => error.code,
            'code',
            NewConversationError.unavailable,
          ),
        ),
      );
    });
  });
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
