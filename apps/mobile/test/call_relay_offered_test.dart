import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

/// Whether the settings screen offers "always use a relay server" at all.
///
/// The rule is one sentence and it has been got wrong once: the switch is
/// hidden only where the server is KNOWN not to hand out a relay. Anything
/// unknown — a server that cannot be reached, an account with no room to name
/// in the request — counts as offering one, because hiding a working switch is
/// worse than showing one that may do nothing.
void main() {
  late AppDatabase database;
  late AccountRepository accounts;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  http.Response ocs(Object? data, int statusCode) => http.Response.bytes(
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

  Future<bool> offered(MockClient client) async {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(
          MemoryCredentialVault()..values['account-a'] = 'fixture-password',
        ),
        nextcloudApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);
    return container.read(callRelayOfferedProvider.future);
  }

  test('an account with no conversation yet keeps the switch', () async {
    var requests = 0;
    expect(
      await offered(
        MockClient((_) async {
          requests++;
          return ocs(const <String, Object?>{}, 200);
        }),
      ),
      isTrue,
    );
    expect(
      requests,
      0,
      reason: 'there was no room to ask about, so nothing was asked',
    );
  });

  test('a server that hands out no TURN server hides the switch', () async {
    await _cacheRoom(database);
    final cases =
        readFixtureJson('signaling/fixtures/settings.cases.json')
            as List<Object?>;
    final withoutTurn =
        (cases.first! as Map<String, Object?>)['data']! as Map<String, Object?>;

    expect(await offered(MockClient((_) async => ocs(withoutTurn, 200))), isFalse);
  });

  test('a server that cannot be asked keeps the switch', () async {
    await _cacheRoom(database);
    expect(
      await offered(
        MockClient((_) async => ocs(const <String, Object?>{}, 503)),
      ),
      isTrue,
    );
  });
}

Future<void> _cacheRoom(AppDatabase database) async {
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: 'account-a',
          token: 'relayroom1',
          displayName: 'Relay room',
          description: '',
          lastActivity: 1770000000,
          unreadMessages: 0,
          favorite: false,
          rawJson: '{}',
        ),
      );
}
