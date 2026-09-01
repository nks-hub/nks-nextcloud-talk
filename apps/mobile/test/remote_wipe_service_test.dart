import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/settings/remote_wipe_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

const String _server = 'https://cloud.example.invalid';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: _server,
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    vault.values['account-a'] = 'fixture-app-password-never-use';
  });

  tearDown(() => database.close());

  ({RemoteWipeService service, List<String> removed, List<Uri> calls}) build(
    MockClientHandler handler,
  ) {
    final calls = <Uri>[];
    final removed = <String>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        calls.add(request.url);
        return handler(request);
      }),
    );
    addTearDown(api.close);
    return (
      service: RemoteWipeService(
        accounts: accounts,
        credentials: vault,
        api: api,
        removeAccount: (accountId) async {
          removed.add(accountId);
          if (await accounts.getAccount(accountId) == null) {
            return false;
          }
          await database.customStatement('DELETE FROM accounts WHERE id = ?', [
            accountId,
          ]);
          return true;
        },
      ),
      removed: removed,
      calls: calls,
    );
  }

  test('an explicit wipe order removes the account and is reported', () async {
    final built = build(
      (request) async => request.url.path.endsWith('/wipe/check')
          ? http.Response(jsonEncode({'wipe': true}), 200)
          : http.Response('', 200),
    );

    final result = await built.service.wipeIfRequested('account-a');

    expect(result, RemoteWipeResult.wiped);
    expect(built.removed, <String>['account-a']);
    expect(built.calls.map((uri) => uri.path), <String>[
      '/index.php/core/wipe/check',
      '/index.php/core/wipe/success',
    ]);
    // The report goes out only once the device really has nothing left.
    expect(await accounts.getAccount('account-a'), isNull);
  });

  test('the token travels in the body, never in the URL', () async {
    final bodies = <String>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(jsonEncode({'wipe': false}), 200);
      }),
    );
    addTearDown(api.close);
    final service = RemoteWipeService(
      accounts: accounts,
      credentials: vault,
      api: api,
      removeAccount: (_) async => true,
    );

    await service.wipeIfRequested('account-a');

    expect(bodies.single, 'token=fixture-app-password-never-use');
  });

  test('nothing is wiped when the server says no', () async {
    final built = build(
      (_) async => http.Response(jsonEncode({'wipe': false}), 200),
    );

    expect(
      await built.service.wipeIfRequested('account-a'),
      RemoteWipeResult.kept,
    );
    expect(built.removed, isEmpty);
    expect(await accounts.getAccount('account-a'), isNotNull);
  });

  test('an unreachable or failing server never destroys local data', () async {
    for (final answer in <http.Response Function()>[
      () => http.Response('', 503),
      () => http.Response('', 404),
      () => http.Response('not json', 200),
    ]) {
      final built = build((_) async => answer());

      expect(
        await built.service.wipeIfRequested('account-a'),
        RemoteWipeResult.kept,
      );
      expect(built.removed, isEmpty);
      expect(await accounts.getAccount('account-a'), isNotNull);
    }
  });

  test('a thrown transport error is not a wipe either', () async {
    final built = build((_) async => throw const SocketFailure());

    expect(
      await built.service.wipeIfRequested('account-a'),
      RemoteWipeResult.kept,
    );
    expect(await accounts.getAccount('account-a'), isNotNull);
  });

  test('without a stored credential the server is never asked', () async {
    vault.values.remove('account-a');
    final built = build((_) async => http.Response('', 200));

    expect(
      await built.service.wipeIfRequested('account-a'),
      RemoteWipeResult.kept,
    );
    expect(built.calls, isEmpty);
  });

  test('an account that is already gone is not wiped again', () async {
    final built = build(
      (_) async => http.Response(jsonEncode({'wipe': true}), 200),
    );

    expect(
      await built.service.wipeIfRequested('missing-account'),
      RemoteWipeResult.kept,
    );
    expect(built.calls, isEmpty);
  });
}

final class SocketFailure implements Exception {
  const SocketFailure();
}
