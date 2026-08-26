import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/rooms/conversation_tags_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()
      ..values['account-a'] = 'password-a'
      ..values['account-b'] = 'password-b';
    for (final entry in const <(String, String)>[
      ('account-a', 'user-a'),
      ('account-b', 'user-b'),
    ]) {
      await accounts.upsertAccount(
        accountId: entry.$1,
        serverUrl: 'https://cloud.example.invalid',
        loginName: entry.$2,
        serverProductName: 'Nextcloud',
        talkFeatures: const {'conversation-tags'},
        createdAt: DateTime.utc(2026),
      );
      await accounts.applyAuthoritativeConversation(
        entry.$1,
        ConversationRoom.fromJson(_taggedRoom(const <String>[])),
      );
    }
  });

  tearDown(() => database.close());

  ConversationTagsService createService(MockClient client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return ConversationTagsService(
      accounts: accounts,
      credentials: vault,
      api: api,
    );
  }

  Future<Set<String>> cachedTagIds(String accountId) async {
    final row =
        await (database.select(database.cachedConversations)..where(
              (conversation) => conversation.accountId.equals(accountId),
            ))
            .getSingle();
    return ConversationRoom.fromJson(jsonDecode(row.rawJson)).tagIds;
  }

  test(
    'keeps definitions and assignments isolated for two participants',
    () async {
      final requestBodies = <String, List<String>>{};
      var capabilityRequests = 0;
      final service = createService(
        MockClient((request) async {
          final accountId = _accountForAuthorization(request);
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests++;
            return _jsonResponse(
              capabilitiesJson(talkFeatures: const ['conversation-tags']),
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/api/v4/tags')) {
            return _ocsResponse(200, [
              _tagDefinition(
                accountId == 'account-a' ? '11' : '22',
                accountId == 'account-a' ? 'Work' : 'Personal',
              ),
            ]);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/api/v4/room/rooma123/tags')) {
            final body = jsonDecode(request.body) as Map<String, Object?>;
            final tagIds = (body['tagIds']! as List<Object?>).cast<String>();
            requestBodies[accountId] = tagIds;
            return _ocsResponse(200, _taggedRoom(tagIds));
          }
          return http.Response('', 404);
        }),
      );

      final definitions = await Future.wait([
        service.fetchDefinitions(accountId: 'account-a'),
        service.fetchDefinitions(accountId: 'account-b'),
      ]);
      expect(definitions[0].single.name, 'Work');
      expect(definitions[1].single.name, 'Personal');

      await Future.wait([
        service.assign(
          accountId: 'account-a',
          roomToken: 'rooma123',
          tagIds: const ['11'],
        ),
        service.assign(
          accountId: 'account-b',
          roomToken: 'rooma123',
          tagIds: const ['22'],
        ),
      ]);

      expect(capabilityRequests, 4);
      expect(requestBodies, {
        'account-a': ['11'],
        'account-b': ['22'],
      });
      final cached = await database.select(database.cachedConversations).get();
      final byAccount = {for (final room in cached) room.accountId: room};
      expect(
        ConversationRoom.fromJson(
          jsonDecode(byAccount['account-a']!.rawJson),
        ).tagIds,
        {'11'},
      );
      expect(
        ConversationRoom.fromJson(
          jsonDecode(byAccount['account-b']!.rawJson),
        ).tagIds,
        {'22'},
      );
    },
  );

  test('fresh missing capability prevents tag endpoint calls', () async {
    var tagRequests = 0;
    final service = createService(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(capabilitiesJson(talkFeatures: const []));
        }
        tagRequests++;
        return http.Response('', 500);
      }),
    );

    await expectLater(
      service.fetchDefinitions(accountId: 'account-a'),
      throwsA(
        isA<ConversationTagsException>().having(
          (error) => error.code,
          'code',
          ConversationTagsError.unsupported,
        ),
      ),
    );
    expect(tagRequests, 0);
  });

  test(
    'malformed definitions fail closed without changing room cache',
    () async {
      final before = await cachedTagIds('account-a');
      final service = createService(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _jsonResponse(
              capabilitiesJson(talkFeatures: const ['conversation-tags']),
            );
          }
          return _ocsResponse(200, [_tagDefinition('not-numeric', 'Broken')]);
        }),
      );

      await expectLater(
        service.fetchDefinitions(accountId: 'account-a'),
        throwsA(
          isA<ConversationTagsException>().having(
            (error) => error.code,
            'code',
            ConversationTagsError.invalidResponse,
          ),
        ),
      );
      expect(await cachedTagIds('account-a'), before);
    },
  );
}

String _accountForAuthorization(http.Request request) {
  final authorization = request.headers['Authorization'];
  for (final entry in const <(String, String, String)>[
    ('account-a', 'user-a', 'password-a'),
    ('account-b', 'user-b', 'password-b'),
  ]) {
    final expected =
        'Basic ${base64Encode(utf8.encode('${entry.$2}:${entry.$3}'))}';
    if (authorization == expected) {
      return entry.$1;
    }
  }
  fail('Unexpected authorization scope');
}

Map<String, Object?> _tagDefinition(String id, String name) => {
  'id': id,
  'name': name,
  'sortOrder': 1,
  'collapsed': false,
  'type': 'custom',
};

Map<String, Object?> _taggedRoom(List<String> tagIds) {
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
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>)
    ..['tagIds'] = tagIds;
}

http.Response _ocsResponse(int statusCode, Object? data) => _jsonResponse({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': statusCode, 'message': 'OK'},
    'data': data,
  },
}, statusCode: statusCode);

http.Response _jsonResponse(Object? body, {int statusCode = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
