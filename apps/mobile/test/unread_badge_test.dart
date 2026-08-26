import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/unread_badge.dart';

import 'test_support.dart';

void main() {
  group('UnreadCountBadge', () {
    testWidgets('renders nothing at a zero count', (tester) async {
      await tester.pumpWidget(
        localizedTestApp(
          home: const Scaffold(body: UnreadCountBadge(count: 0)),
        ),
      );

      expect(find.byType(UnreadCountBadge), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('shows the count once it is positive', (tester) async {
      await tester.pumpWidget(
        localizedTestApp(
          home: const Scaffold(body: UnreadCountBadge(count: 3)),
        ),
      );

      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('caps large counts at 99+', (tester) async {
      await tester.pumpWidget(
        localizedTestApp(
          home: const Scaffold(body: UnreadCountBadge(count: 250)),
        ),
      );

      expect(find.text('99+'), findsOneWidget);
    });
  });

  group('unreadCountOf', () {
    test('sums unread messages across the given conversations', () async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
        loginName: 'alex',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      await _insertConversation(
        database,
        accountId: 'account-a',
        token: 'room-1',
        unreadMessages: 3,
      );
      await _insertConversation(
        database,
        accountId: 'account-a',
        token: 'room-2',
        unreadMessages: 5,
      );

      final conversations = await accounts
          .watchConversations('account-a')
          .first;
      expect(unreadCountOf(conversations), 8);
    });

    test('is zero for an empty conversation list', () {
      expect(unreadCountOf(const []), 0);
    });
  });

  group('unreadSummaryProvider', () {
    late AppDatabase database;
    late AccountRepository accounts;

    setUp(() async {
      database = openTestDatabase();
      accounts = AccountRepository(database);
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
        loginName: 'alex',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      await accounts.upsertAccount(
        accountId: 'account-b',
        serverUrl: 'https://b.example.invalid',
        loginName: 'blair',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 2),
      );
    });

    tearDown(() => database.close());

    test('is zero per account and in total with no unread messages', () async {
      await _insertConversation(
        database,
        accountId: 'account-a',
        token: 'room-a',
        unreadMessages: 0,
      );
      await _insertConversation(
        database,
        accountId: 'account-b',
        token: 'room-b',
        unreadMessages: 0,
      );

      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      final summary = await _readSummary(container);
      expect(summary.countFor('account-a'), 0);
      expect(summary.countFor('account-b'), 0);
      expect(summary.total, 0);
    });

    test(
      'keeps unread counts isolated per account even with the same room token',
      () async {
        // Same token reused under two different accounts: the primary key is
        // (accountId, token), so this must never let account B's count leak
        // into account A's, or vice versa.
        await _insertConversation(
          database,
          accountId: 'account-a',
          token: 'shared-token',
          unreadMessages: 4,
        );
        await _insertConversation(
          database,
          accountId: 'account-a',
          token: 'other-room',
          unreadMessages: 1,
        );
        await _insertConversation(
          database,
          accountId: 'account-b',
          token: 'shared-token',
          unreadMessages: 20,
        );

        final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(database)],
        );
        addTearDown(container.dispose);

        final summary = await _readSummary(container);
        expect(summary.countFor('account-a'), 5);
        expect(summary.countFor('account-b'), 20);
        expect(summary.total, 25);
      },
    );

    test('reacts to conversation updates after the initial read', () async {
      await _insertConversation(
        database,
        accountId: 'account-a',
        token: 'room-a',
        unreadMessages: 2,
      );

      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      final first = await _readSummary(container);
      expect(first.countFor('account-a'), 2);

      final updatedToNine = Completer<void>();
      final subscription = container.listen(unreadSummaryProvider, (_, next) {
        if (next.countFor('account-a') == 9 && !updatedToNine.isCompleted) {
          updatedToNine.complete();
        }
      });
      addTearDown(subscription.close);

      await (database.update(database.cachedConversations)..where(
            (row) =>
                row.accountId.equals('account-a') & row.token.equals('room-a'),
          ))
          .write(
            const CachedConversationsCompanion(unreadMessages: Value(9)),
          );

      await updatedToNine.future.timeout(const Duration(seconds: 2));
    });
  });

  group('AppIconBadgeUpdater', () {
    test('updates the badge once support is confirmed', () async {
      final updatedWith = <int>[];
      final updater = AppIconBadgeUpdater(
        isSupported: () async => true,
        updateBadge: (count) async {
          updatedWith.add(count);
        },
      );

      await updater.update(7);

      expect(updatedWith, [7]);
    });

    test('never calls updateBadge when the launcher is unsupported', () async {
      var updateCalled = false;
      final updater = AppIconBadgeUpdater(
        isSupported: () async => false,
        updateBadge: (_) async {
          updateCalled = true;
        },
      );

      await updater.update(3);

      expect(updateCalled, isFalse);
    });

    test(
      'swallows an isSupported failure instead of throwing or crashing',
      () async {
        final updater = AppIconBadgeUpdater(
          isSupported: () async => throw StateError('no platform channel'),
          updateBadge: (_) async {},
        );

        await expectLater(updater.update(1), completes);
      },
    );

    test(
      'swallows an updateBadge failure instead of throwing or crashing',
      () async {
        final updater = AppIconBadgeUpdater(
          isSupported: () async => true,
          updateBadge: (_) async => throw StateError('rejected by launcher'),
        );

        await expectLater(updater.update(1), completes);
      },
    );

    test('clamps negative counts to zero', () async {
      final received = <int>[];
      final updater = AppIconBadgeUpdater(
        isSupported: () async => true,
        updateBadge: (count) async => received.add(count),
      );

      await updater.update(-5);

      expect(received, [0]);
    });
  });

  group('setWindowsTaskbarBadge', () {
    const channel = MethodChannel('com.nkshub.nextcloudtalk/taskbar_badge');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('hands the count to the runner as an int', (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });

      await setWindowsTaskbarBadge(7);
      // Zero is what clears the overlay, so it must reach the runner too
      // instead of being filtered out on the Dart side.
      await setWindowsTaskbarBadge(0);

      expect(calls.map((call) => call.method), ['setBadge', 'setBadge']);
      expect(calls.map((call) => call.arguments), [7, 0]);
    });
  });

  group('appIconBadgeSyncProvider', () {
    test('pushes the total to the updater on every summary change', () async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
        loginName: 'alex',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      await _insertConversation(
        database,
        accountId: 'account-a',
        token: 'room-a',
        unreadMessages: 1,
      );

      final seen = <int>[];
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          appIconBadgeUpdaterProvider.overrideWithValue(
            AppIconBadgeUpdater(
              isSupported: () async => true,
              updateBadge: (count) async => seen.add(count),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(appIconBadgeSyncProvider);
      await _waitUntil(() => seen.contains(1));

      await (database.update(database.cachedConversations)..where(
            (row) =>
                row.accountId.equals('account-a') & row.token.equals('room-a'),
          ))
          .write(
            const CachedConversationsCompanion(unreadMessages: Value(4)),
          );

      await _waitUntil(() => seen.contains(4));
      expect(seen.last, 4);
    });
  });
}

Future<UnreadSummary> _readSummary(ProviderContainer container) async {
  // unreadSummaryProvider reads accountsProvider and conversationsProvider
  // via valueOrNull, so it silently sees "no data yet" until each underlying
  // stream has actually emitted once. Await that directly instead of racing
  // it with a timer.
  final accountList = await container.read(accountsProvider.future);
  for (final account in accountList) {
    await container.read(conversationsProvider(account.id).future);
  }
  return container.read(unreadSummaryProvider);
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _insertConversation(
  AppDatabase database, {
  required String accountId,
  required String token,
  required int unreadMessages,
}) {
  return database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
          token: token,
          displayName: 'Room $token',
          description: '',
          lastActivity: 1,
          unreadMessages: unreadMessages,
          favorite: false,
          rawJson: '{}',
        ),
      );
}
