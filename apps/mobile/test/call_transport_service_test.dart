import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  CallTransportService service(MockClient client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return CallTransportService(
      accounts: accounts,
      credentials: vault,
      api: api,
    );
  }

  http.Response ocs(Object? data, int statusCode) {
    return http.Response.bytes(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': statusCode == 200 ? 'ok' : 'failure',
              'statuscode': statusCode,
              'message': 'OK',
            },
            'data': data,
          },
        }),
      ),
      statusCode,
    );
  }

  test('the settings endpoint decides which transport a room uses', () async {
    final cases =
        readFixtureJson('signaling/fixtures/settings.cases.json')
            as List<Object?>;
    final internal =
        (cases.first! as Map<String, Object?>)['data']! as Map<String, Object?>;
    late Uri requested;

    final transport = await service(
      MockClient((request) async {
        requested = request.url;
        return ocs(internal, 200);
      }),
    ).resolve(accountId: 'account-a', roomToken: 'rooma123');

    expect(transport, CallTransport.internal);
    expect(requested.path, endsWith('/signaling/settings'));
    expect(requested.queryParameters['token'], 'rooma123');
  });

  test(
    'an external High Performance Backend is chosen when the server names one',
    () async {
      final cases =
          readFixtureJson('signaling/fixtures/settings.cases.json')
              as List<Object?>;
      final external =
          cases
                  .cast<Map<String, Object?>>()
                  .firstWhere((c) => c['id'] == 'external-v1')['data']!
              as Map<String, Object?>;

      final transport = await service(
        MockClient((_) async => ocs(external, 200)),
      ).resolve(accountId: 'account-a', roomToken: 'rooma123');

      expect(transport, CallTransport.externalHpb);
    },
  );

  test('the relay switch follows what the server hands out', () async {
    final cases =
        readFixtureJson('signaling/fixtures/settings.cases.json')
            as List<Object?>;
    Map<String, Object?> data(int index) =>
        (cases[index]! as Map<String, Object?>)['data']! as Map<String, Object?>;

    // Case 1 carries a TURN server, case 0 lists none — a Nextcloud whose
    // administrator configured no relay, which is the ordinary small install.
    expect(
      await service(
        MockClient((_) async => ocs(data(1), 200)),
      ).offersRelay(accountId: 'account-a', roomToken: 'rooma123'),
      isTrue,
    );
    expect(
      await service(
        MockClient((_) async => ocs(data(0), 200)),
      ).offersRelay(accountId: 'account-a', roomToken: 'rooma123'),
      isFalse,
    );
    // A server that cannot be asked keeps the switch: hiding a working one is
    // worse than showing one that may do nothing.
    expect(
      await service(
        MockClient((_) async => ocs(const <String, Object?>{}, 500)),
      ).offersRelay(accountId: 'account-a', roomToken: 'rooma123'),
      isTrue,
    );
  });

  test('an unauthorized fetch asks for a new sign-in', () async {
    final transport = await service(
      MockClient((_) async => ocs(const <String, Object?>{}, 401)),
    ).resolve(accountId: 'account-a', roomToken: 'rooma123');

    expect(transport, CallTransport.reauthenticationRequired);
  });

  test(
    'a missing room is reported as unavailable, never as a transport',
    () async {
      final transport = await service(
        MockClient((_) async => ocs(const <String, Object?>{}, 404)),
      ).resolve(accountId: 'account-a', roomToken: 'rooma123');

      expect(transport, CallTransport.roomUnavailable);
    },
  );

  test('a server failure never guesses a transport', () async {
    final transport = await service(
      MockClient((_) async => ocs(const <String, Object?>{}, 500)),
    ).resolve(accountId: 'account-a', roomToken: 'rooma123');

    expect(transport, CallTransport.unavailable);
  });

  test('a signed-out account is not sent to the server', () async {
    vault.values.remove('account-a');
    var calls = 0;
    final transport = await service(
      MockClient((_) async {
        calls++;
        return ocs(const <String, Object?>{}, 200);
      }),
    ).resolve(accountId: 'account-a', roomToken: 'rooma123');

    expect(transport, CallTransport.reauthenticationRequired);
    expect(calls, 0);
  });

  test('an unknown account resolves nothing', () async {
    final transport = await service(
      MockClient((_) async => ocs(const <String, Object?>{}, 200)),
    ).resolve(accountId: 'account-missing', roomToken: 'rooma123');

    expect(transport, CallTransport.unavailable);
  });
}
