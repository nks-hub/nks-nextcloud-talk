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

Map<String, Object?> _capabilitiesWithFeatures(Object? features) {
  final payload = capabilitiesJson(talkFeatures: const <String>[]);
  final ocs = payload['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  spreed['features'] = features;
  return payload;
}

http.Response _ocsResponse({required int statusCode, required String status}) {
  return http.Response(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': status,
          'statuscode': statusCode,
          'message': status,
        },
        'data': const <Object?>[],
      },
    }),
    statusCode,
  );
}

Matcher _throwsRoomSettingsError(RoomSettingsError code) {
  return throwsA(
    isA<RoomSettingsException>().having((error) => error.code, 'code', code),
  );
}

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
    for (final account in <({String id, String host, String login})>[
      (id: 'account-a', host: 'a.example.invalid', login: 'user-a'),
      (id: 'account-b', host: 'b.example.invalid', login: 'user-b'),
    ]) {
      await accounts.upsertAccount(
        accountId: account.id,
        serverUrl: 'https://${account.host}',
        loginName: account.login,
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
        talkFeatures: const <String>{'archived-conversations-v2'},
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

  test('does not call archive without a fresh archive capability', () async {
    var capabilityCalls = 0;
    var archiveCalls = 0;
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          capabilityCalls++;
          return http.Response(
            jsonEncode(_capabilitiesWithFeatures(const <Object?>[])),
            200,
          );
        }
        if (request.url.path.endsWith('/archive')) {
          archiveCalls++;
          return _ocsResponse(statusCode: 200, status: 'ok');
        }
        return http.Response('', 404);
      }),
    );

    await expectLater(
      service.setArchived(
        accountId: 'account-a',
        roomToken: 'rooma123',
        archived: true,
      ),
      _throwsRoomSettingsError(RoomSettingsError.invalidResponse),
    );

    expect(capabilityCalls, 1);
    expect(archiveCalls, 0);
  });

  for (final invalid in <({String name, Object? features})>[
    (
      name: 'malformed',
      features: const <Object?>['archived-conversations-v2', 7],
    ),
    (
      name: 'duplicate',
      features: const <Object?>[
        'archived-conversations-v2',
        'archived-conversations-v2',
      ],
    ),
  ]) {
    test('does not call archive for ${invalid.name} capabilities', () async {
      var archiveCalls = 0;
      final service = serviceWith(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(_capabilitiesWithFeatures(invalid.features)),
              200,
            );
          }
          if (request.url.path.endsWith('/archive')) {
            archiveCalls++;
            return _ocsResponse(statusCode: 200, status: 'ok');
          }
          return http.Response('', 404);
        }),
      );

      await expectLater(
        service.setArchived(
          accountId: 'account-a',
          roomToken: 'rooma123',
          archived: true,
        ),
        _throwsRoomSettingsError(RoomSettingsError.invalidResponse),
      );
      expect(archiveCalls, 0);
    });
  }

  test('scopes capability and archive requests to each account', () async {
    final calls =
        <({String method, String host, String path, String? authorization})>[];
    final service = serviceWith(
      MockClient((request) async {
        calls.add((
          method: request.method,
          host: request.url.host,
          path: request.url.path,
          authorization: request.headers['Authorization'],
        ));
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _capabilitiesWithFeatures(const <Object?>[
                'archived-conversations-v2',
              ]),
            ),
            200,
          );
        }
        if (request.url.path.endsWith('/archive')) {
          return _ocsResponse(statusCode: 200, status: 'ok');
        }
        return http.Response('', 404);
      }),
    );

    await service.setArchived(
      accountId: 'account-a',
      roomToken: 'rooma123',
      archived: true,
    );
    await service.setArchived(
      accountId: 'account-b',
      roomToken: 'rooma123',
      archived: false,
    );

    expect(calls, hasLength(4));
    expect(
      calls
          .map(
            (call) => (
              method: call.method,
              host: call.host,
              isArchive: call.path.endsWith('/archive'),
            ),
          )
          .toList(),
      <({String method, String host, bool isArchive})>[
        (method: 'GET', host: 'a.example.invalid', isArchive: false),
        (method: 'POST', host: 'a.example.invalid', isArchive: true),
        (method: 'GET', host: 'b.example.invalid', isArchive: false),
        (method: 'DELETE', host: 'b.example.invalid', isArchive: true),
      ],
    );
    expect(calls.take(2).map((call) => call.authorization).toSet(), <String>{
      'Basic ${base64Encode(utf8.encode('user-a:password-a'))}',
    });
    expect(calls.skip(2).map((call) => call.authorization).toSet(), <String>{
      'Basic ${base64Encode(utf8.encode('user-b:password-b'))}',
    });
  });

  test('maps a capability 401 to reauthentication without archive', () async {
    var archiveCalls = 0;
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response('', 401);
        }
        if (request.url.path.endsWith('/archive')) {
          archiveCalls++;
        }
        return http.Response('', 404);
      }),
    );

    await expectLater(
      service.setArchived(
        accountId: 'account-a',
        roomToken: 'rooma123',
        archived: true,
      ),
      _throwsRoomSettingsError(RoomSettingsError.reauthenticationRequired),
    );
    expect(archiveCalls, 0);
  });

  test('preserves archive endpoint 401 classification', () async {
    final service = serviceWith(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _capabilitiesWithFeatures(const <Object?>[
                'archived-conversations-v2',
              ]),
            ),
            200,
          );
        }
        if (request.url.path.endsWith('/archive')) {
          return _ocsResponse(statusCode: 401, status: 'failure');
        }
        return http.Response('', 404);
      }),
    );

    await expectLater(
      service.setArchived(
        accountId: 'account-a',
        roomToken: 'rooma123',
        archived: true,
      ),
      _throwsRoomSettingsError(RoomSettingsError.reauthenticationRequired),
    );
  });
}
