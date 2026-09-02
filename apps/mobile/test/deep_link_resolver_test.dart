import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/conversations/deep_link_bridge.dart';
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

  test(
    'resolves an /index.php/call/<token> link to the matching account',
    () async {
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
    },
  );

  test(
    'picks the account whose server shares the origin, out of several',
    () async {
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
    },
  );

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

  test('a missing native bridge leaves the coordinator idle', () async {
    final coordinator = DeepLinkCoordinator(
      platform: _ThrowingDeepLinkPlatform(MissingPluginException()),
      resolver: () => DeepLinkResolver(accounts),
    );
    addTearDown(coordinator.close);

    await expectLater(coordinator.start(), completes);

    expect(coordinator.takeNext(), isNull);
  });

  test('an unexpected native bridge error remains visible', () async {
    final coordinator = DeepLinkCoordinator(
      platform: _ThrowingDeepLinkPlatform(StateError('bridge failed')),
      resolver: () => DeepLinkResolver(accounts),
    );
    addTearDown(coordinator.close);

    await expectLater(coordinator.start(), throwsStateError);
  });

  test('does not initialize the resolver database without a link', () async {
    var resolverCreations = 0;
    final container = ProviderContainer(
      overrides: [
        deepLinkPlatformProvider.overrideWithValue(
          const _NoLinkDeepLinkPlatform(),
        ),
        deepLinkResolverProvider.overrideWith((ref) {
          resolverCreations += 1;
          throw StateError('resolver must stay lazy');
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(deepLinkCoordinatorProvider), isNotNull);
    await pumpEventQueue();

    expect(resolverCreations, 0);
  });
}

final class _ThrowingDeepLinkPlatform implements DeepLinkPlatform {
  const _ThrowingDeepLinkPlatform(this.error);

  final Object error;

  @override
  Stream<Uri> get linkOpened => const Stream.empty();

  @override
  Future<Uri?> getLaunchLink() => Future<Uri?>.error(error);

  @override
  Future<void> dispose() async {}
}

final class _NoLinkDeepLinkPlatform implements DeepLinkPlatform {
  const _NoLinkDeepLinkPlatform();

  @override
  Stream<Uri> get linkOpened => const Stream.empty();

  @override
  Future<Uri?> getLaunchLink() async => null;

  @override
  Future<void> dispose() async {}
}
