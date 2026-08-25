import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/conversations/deep_link_coordinator.dart';

import 'test_support.dart';

void main() {
  late AccountRepository accounts;

  setUp(() async {
    final database = openTestDatabase();
    addTearDown(database.close);
    accounts = AccountRepository(database);
  });

  test('resolves a bare /call/<token> link to the matching account', () async {
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final resolver = DeepLinkResolver(accounts);

    final resolved = await resolver.resolve(
      Uri.parse('https://cloud.example.invalid/call/abc12345'),
    );

    expect(resolved, isNotNull);
    expect(resolved!.accountId, account.id);
    expect(resolved.token.value, 'abc12345');
  });

  test('resolves an /index.php/call/<token> link to the matching account', () async {
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final resolver = DeepLinkResolver(accounts);

    final resolved = await resolver.resolve(
      Uri.parse('https://cloud.example.invalid/index.php/call/abc12345'),
    );

    expect(resolved, isNotNull);
    expect(resolved!.accountId, account.id);
    expect(resolved.token.value, 'abc12345');
  });

  test('picks the account whose server shares the origin, out of several', () async {
    await accounts.upsertAccount(
      accountId: 'account-other',
      serverUrl: 'https://other.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final target = await accounts.upsertAccount(
      accountId: 'account-target',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 2),
    );
    final resolver = DeepLinkResolver(accounts);

    final resolved = await resolver.resolve(
      Uri.parse('https://cloud.example.invalid/call/abc12345'),
    );

    expect(resolved?.accountId, target.id);
  });

  test('never guesses when no account shares the link origin', () async {
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final resolver = DeepLinkResolver(accounts);

    final resolved = await resolver.resolve(
      Uri.parse('https://attacker.example.invalid/call/abc12345'),
    );

    expect(resolved, isNull);
  });

  test('rejects a subdomain that merely contains the account host', () async {
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final resolver = DeepLinkResolver(accounts);

    final resolved = await resolver.resolve(
      Uri.parse('https://cloud.example.invalid.attacker.invalid/call/abc12345'),
    );

    expect(resolved, isNull);
  });

  test('rejects a link with a malformed room token', () async {
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final resolver = DeepLinkResolver(accounts);

    final resolved = await resolver.resolve(
      Uri.parse('https://cloud.example.invalid/call/abc_1234'),
    );

    expect(resolved, isNull);
  });

  test('rejects a path that is not a call link', () async {
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final resolver = DeepLinkResolver(accounts);

    final resolved = await resolver.resolve(
      Uri.parse('https://cloud.example.invalid/index.php/apps/spreed/'),
    );

    expect(resolved, isNull);
  });

  test('honours the account server base path', () async {
    final subpathAccount = await accounts.upsertAccount(
      accountId: 'account-subpath',
      serverUrl: 'https://cloud.example.invalid/nextcloud',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final resolver = DeepLinkResolver(accounts);

    final matching = await resolver.resolve(
      Uri.parse('https://cloud.example.invalid/nextcloud/call/abc12345'),
    );
    final mismatched = await resolver.resolve(
      Uri.parse('https://cloud.example.invalid/call/abc12345'),
    );

    expect(matching?.accountId, subpathAccount.id);
    expect(mismatched, isNull);
  });
}
