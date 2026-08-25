import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';
import 'package:nextcloudtalk/features/settings/theme_preference.dart';

import 'test_support.dart';

final class _MemoryThemePreferenceStore implements ThemePreferenceStore {
  ThemeMode stored = ThemeMode.system;
  int writeCount = 0;

  @override
  Future<ThemeMode> read() async => stored;

  @override
  Future<void> write(ThemeMode mode) async {
    writeCount++;
    stored = mode;
  }
}

// testWidgets runs a fake clock. Real Drift I/O (even against an in-memory
// database) needs a genuine event-loop turn to finish, so a plain
// tester.pump() never lets it complete — it would hang forever. Route the
// real work through runAsync, which briefly leaves the fake zone.
Future<void> _flushRealAsync(WidgetTester tester) {
  return tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
}

Future<List<StoredAccount>> _allAccounts(AppDatabase database) {
  return database.select(database.accounts).get();
}

Widget _wrap({
  required AccountRepository accountRepository,
  required Stream<List<StoredAccount>> accountsStream,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      accountRepositoryProvider.overrideWithValue(accountRepository),
      // accountsProvider normally watches a live Drift stream (and also
      // attachmentServiceProvider, which needs platform plugins unavailable
      // in widget tests). Settings only needs a snapshot of the account
      // list, fed here as a plain stream so the fake clock in testWidgets
      // never has to wait on Drift's live-query machinery.
      accountsProvider.overrideWith((ref) => accountsStream),
      ...overrides,
    ],
    child: localizedTestApp(home: const SettingsScreen()),
  );
}

void main() {
  testWidgets('lists every stored account with the active one marked', (
    tester,
  ) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    late String firstId;
    late String secondId;
    late List<StoredAccount> initial;
    await tester.runAsync(() async {
      firstId = (await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud-a.example.invalid',
        loginName: 'alice',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      )).id;
      secondId = (await accounts.upsertAccount(
        accountId: 'account-b',
        serverUrl: 'https://cloud-b.example.invalid',
        loginName: 'bob',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 2),
      )).id;
      initial = await _allAccounts(database);
    });

    await tester.pumpWidget(
      _wrap(accountRepository: accounts, accountsStream: Stream.value(initial)),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('alice'), findsOneWidget);
    expect(find.text('https://cloud-a.example.invalid'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('https://cloud-b.example.invalid'), findsOneWidget);

    // The second account was added last, so it is the selected one.
    expect(
      find.descendant(
        of: find.byKey(Key('account-tile-$secondId')),
        matching: find.text('Active'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(Key('account-tile-$firstId')),
        matching: find.text('Active'),
      ),
      findsNothing,
    );
  });

  testWidgets('single-account state shows exactly one entry, already active', (
    tester,
  ) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    late String onlyId;
    late List<StoredAccount> initial;
    await tester.runAsync(() async {
      onlyId = (await accounts.upsertAccount(
        accountId: 'account-only',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'solo',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      )).id;
      initial = await _allAccounts(database);
    });

    await tester.pumpWidget(
      _wrap(accountRepository: accounts, accountsStream: Stream.value(initial)),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    expect(find.byType(ListTile).evaluate().length, greaterThanOrEqualTo(1));
    expect(find.text('solo'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(Key('account-tile-$onlyId')),
        matching: find.text('Active'),
      ),
      findsOneWidget,
    );

    // The only account is already active, so its tile has no onTap handler
    // (see SettingsScreen._AccountTile): tapping it must be a pure no-op.
    await tester.tap(find.byKey(Key('account-tile-$onlyId')));
    await tester.pump();
    expect(tester.takeException(), isNull);

    late StoredAccount? refreshed;
    await tester.runAsync(() async {
      refreshed = await accounts.getAccount(onlyId);
    });
    expect(refreshed!.selected, isTrue);
  });

  testWidgets('tapping an inactive account switches the active account '
      'atomically without leaving two accounts selected', (tester) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    late String firstId;
    late List<StoredAccount> initial;
    await tester.runAsync(() async {
      firstId = (await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud-a.example.invalid',
        loginName: 'alice',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      )).id;
      // Second upsert selects account-b; the test switches back to
      // account-a.
      await accounts.upsertAccount(
        accountId: 'account-b',
        serverUrl: 'https://cloud-b.example.invalid',
        loginName: 'bob',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 2),
      );
      initial = await _allAccounts(database);
    });

    final feed = StreamController<List<StoredAccount>>();
    addTearDown(feed.close);
    feed.add(initial);

    await tester.pumpWidget(
      _wrap(accountRepository: accounts, accountsStream: feed.stream),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(Key('account-tile-$firstId')));
    await tester.pump();
    // The tap triggers a real Drift transaction (AccountRepository.
    // selectAccount) via the widget's onTap handler; let it actually finish
    // before reading the database back or expecting a rebuild.
    await _flushRealAsync(tester);

    late List<StoredAccount> updated;
    await tester.runAsync(() async {
      updated = await _allAccounts(database);
    });
    expect(updated.where((account) => account.selected).length, 1);
    expect(updated.singleWhere((account) => account.selected).id, firstId);

    feed.add(updated);
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(Key('account-tile-$firstId')),
        matching: find.text('Active'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('choosing a theme mode persists it and updates the group '
      'selection', (tester) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    late List<StoredAccount> initial;
    await tester.runAsync(() async {
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'alice',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      initial = await _allAccounts(database);
    });
    final store = _MemoryThemePreferenceStore();

    await tester.pumpWidget(
      _wrap(
        accountRepository: accounts,
        accountsStream: Stream.value(initial),
        overrides: [themePreferenceStoreProvider.overrideWithValue(store)],
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    RadioListTile<ThemeMode> radioTile(Key key) =>
        tester.widget<RadioListTile<ThemeMode>>(find.byKey(key));
    RadioGroup<ThemeMode> group() =>
        tester.widget<RadioGroup<ThemeMode>>(find.byType(RadioGroup<ThemeMode>));

    expect(group().groupValue, ThemeMode.system);
    expect(radioTile(const Key('theme-mode-dark')).value, ThemeMode.dark);

    await tester.tap(find.byKey(const Key('theme-mode-dark')));
    await tester.pump();
    await tester.pump();

    expect(group().groupValue, ThemeMode.dark);
    expect(store.stored, ThemeMode.dark);
    expect(store.writeCount, 1);

    await tester.tap(find.byKey(const Key('theme-mode-light')));
    await tester.pump();
    await tester.pump();

    expect(group().groupValue, ThemeMode.light);
    expect(store.stored, ThemeMode.light);
    expect(store.writeCount, 2);
  });

  testWidgets('loads the persisted theme mode on start', (tester) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    late List<StoredAccount> initial;
    await tester.runAsync(() async {
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'alice',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      initial = await _allAccounts(database);
    });
    final store = _MemoryThemePreferenceStore()..stored = ThemeMode.dark;

    await tester.pumpWidget(
      _wrap(
        accountRepository: accounts,
        accountsStream: Stream.value(initial),
        overrides: [themePreferenceStoreProvider.overrideWithValue(store)],
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    final group = tester.widget<RadioGroup<ThemeMode>>(
      find.byType(RadioGroup<ThemeMode>),
    );
    expect(group.groupValue, ThemeMode.dark);
  });
}
