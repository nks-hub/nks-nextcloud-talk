import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';

import 'test_support.dart';

/// A credential that is not readable yet must not switch the live channel off
/// for the rest of the run.
///
/// The coordinator treats a null from `resolve` as "this server has no live
/// channel" and stops for good — correct for a server without `notify_push`,
/// and wrong for a secure store that simply is not ready. Desktop secure
/// storage is not readable the instant the window opens and a locked keychain
/// answers the same way, so conflating the two left the app with no live
/// channel until it was restarted: no notification, and no refresh while it
/// sat in the background.
final class _CountingVault implements CredentialVault {
  _CountingVault(this._password);

  final String? _password;
  int reads = 0;

  @override
  Future<String?> readAppPassword(String accountId) async {
    reads++;
    return _password;
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {}

  @override
  Future<void> deleteAppPassword(String accountId) async {}
}

void main() {
  late AppDatabase database;
  late AccountRepository accounts;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
  });

  tearDown(() => database.close());

  test(
    'an unreadable credential is retried, not taken as no channel',
    () async {
      final vault = _CountingVault(null);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          accountRepositoryProvider.overrideWithValue(accounts),
          credentialVaultProvider.overrideWithValue(vault),
        ],
      );
      addTearDown(container.dispose);

      final coordinator = container.read(clientPushCoordinatorProvider);
      expect(coordinator, isNotNull);
      coordinator!.follow('account-a');

      // Long enough for the first attempt and at least one retry after the
      // two-second backoff. A give-up shows up as exactly one read that never
      // grows.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final afterFirst = vault.reads;
      expect(afterFirst, greaterThan(0), reason: 'it has to try at least once');

      await Future<void>.delayed(const Duration(seconds: 3));
      expect(
        vault.reads,
        greaterThan(afterFirst),
        reason: 'a missing credential must keep the retry loop alive',
      );

      await coordinator.dispose();
    },
  );
}
