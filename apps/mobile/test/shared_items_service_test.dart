import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/shareditems/shared_items_service.dart';
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
    vault = MemoryCredentialVault()..values['account-a'] = 'app-password';
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'user-a',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await _insertConversation(database, account);
  });

  tearDown(() => database.close());

  test('loads overview and a page with exact account-bound requests', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _jsonResponse(
          capabilitiesJson(talkFeatures: const ['rich-object-list-media']),
        );
      }
      if (request.url.path.endsWith('/share/overview')) {
        return _jsonResponse(
          _ocsData({
            'file': [_message(110)],
            'media': <Object?>[],
          }),
        );
      }
      if (request.url.path.endsWith('/share')) {
        return _jsonResponse(
          _ocsData({'110': _message(110)}),
          headers: {'X-Chat-Last-Given': '110'},
        );
      }
      return http.Response('', 404);
    });
    final service = _service(accounts, vault, client);

    final overview = await service.overview(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final page = await service.page(
      accountId: 'account-a',
      roomToken: 'rooma123',
      type: SharedItemType.file,
      lastKnownMessageId: 0,
    );

    expect(overview.messagesByType.keys, [SharedItemType.file]);
    expect(page.messages.single.messageId, 110);
    expect(page.moreItemsPossible, isFalse);
    expect(requests, hasLength(3));
    expect(requests[1].url.queryParameters, {'format': 'json', 'limit': '7'});
    expect(requests[2].url.queryParameters, {
      'format': 'json',
      'objectType': 'file',
      'lastKnownMessageId': '0',
      'limit': '28',
    });
    expect(
      requests.every((request) => request.headers['authorization'] != null),
      isTrue,
    );
  });

  test('fails closed before shared-items access without capability', () async {
    var sharedRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _jsonResponse(capabilitiesJson(talkFeatures: const []));
      }
      sharedRequests++;
      return http.Response('', 500);
    });

    await expectLater(
      _service(
        accounts,
        vault,
        client,
      ).overview(accountId: 'account-a', roomToken: 'rooma123'),
      throwsA(
        isA<SharedItemsException>().having(
          (error) => error.code,
          'code',
          SharedItemsError.unsupported,
        ),
      ),
    );
    expect(sharedRequests, 0);
  });

  test('federated room needs the federated shared-items capability', () async {
    await (database.delete(database.cachedConversations)).go();
    final account = (await accounts.getAccount('account-a'))!;
    await _insertConversation(
      database,
      account,
      overrides: {'remoteServer': 'remote.example.invalid'},
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _jsonResponse(
          capabilitiesJson(talkFeatures: const ['rich-object-list-media']),
        );
      }
      return http.Response('', 500);
    });

    await expectLater(
      _service(
        accounts,
        vault,
        client,
      ).overview(accountId: 'account-a', roomToken: 'rooma123'),
      throwsA(
        isA<SharedItemsException>().having(
          (error) => error.code,
          'code',
          SharedItemsError.unsupported,
        ),
      ),
    );
  });

  test('maps lobby restriction without losing its cause', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _jsonResponse(
          capabilitiesJson(talkFeatures: const ['rich-object-list-media']),
        );
      }
      return _jsonResponse(
        _ocsData(<String, Object?>{}, success: false),
        statusCode: 412,
      );
    });

    await expectLater(
      _service(
        accounts,
        vault,
        client,
      ).overview(accountId: 'account-a', roomToken: 'rooma123'),
      throwsA(
        isA<SharedItemsException>().having(
          (error) => error.code,
          'code',
          SharedItemsError.lobbyRestricted,
        ),
      ),
    );
  });

  for (final entry in const {
    429: SharedItemsError.rateLimited,
    503: SharedItemsError.serviceUnavailable,
  }.entries) {
    test('maps HTTP ${entry.key} without losing its cause', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(
            capabilitiesJson(talkFeatures: const ['rich-object-list-media']),
          );
        }
        return http.Response('', entry.key);
      });

      await expectLater(
        _service(
          accounts,
          vault,
          client,
        ).overview(accountId: 'account-a', roomToken: 'rooma123'),
        throwsA(
          isA<SharedItemsException>().having(
            (error) => error.code,
            'code',
            entry.value,
          ),
        ),
      );
    });
  }
}

HttpSharedItemsService _service(
  AccountRepository accounts,
  MemoryCredentialVault vault,
  http.Client client,
) => HttpSharedItemsService(
  accounts: accounts,
  credentials: vault,
  api: HttpNextcloudApi(client: client),
);

Future<void> _insertConversation(
  AppDatabase database,
  StoredAccount account, {
  Map<String, Object?> overrides = const {},
}) async {
  final roomJson = <String, Object?>{..._roomJson(), ...overrides};
  final room = ConversationRoom.fromJson(roomJson);
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
          readOnly: Value(room.readOnly),
          roomType: Value(room.type),
          roomName: Value(room.name),
          objectType: Value(room.objectType),
          avatarVersion: Value(room.avatarVersion),
          isCustomAvatar: Value(room.isCustomAvatar),
          rawJson: jsonEncode(roomJson),
        ),
      );
}

Map<String, Object?> _roomJson() {
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
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

Map<String, Object?> _message(int id) {
  final root =
      jsonDecode(
            File(
              '../../contracts/chat-messages/fixtures/chat-future.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final messages = ocs['data']! as List<Object?>;
  return <String, Object?>{
    ...(messages.first! as Map<String, Object?>),
    'id': id,
  };
}

Map<String, Object?> _ocsData(Object? data, {bool success = true}) => {
  'ocs': {
    'meta': {
      'status': success ? 'ok' : 'failure',
      'statuscode': success ? 200 : 998,
      'message': success ? 'OK' : 'Failure',
    },
    'data': data,
  },
};

http.Response _jsonResponse(
  Object? body, {
  int statusCode = 200,
  Map<String, String> headers = const {},
}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  statusCode,
  headers: {'content-type': 'application/json', ...headers},
);
