import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
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

// The accounts loading state shows an indeterminate CircularProgressIndicator,
// which repeats forever and would make pumpAndSettle hang. Pump a bounded
// number of frames instead so streams/futures get a chance to resolve.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Widget _wrap({
  required AccountRepository accountRepository,
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: [
      accountRepositoryProvider.overrideWithValue(accountRepository),
      // accountsProvider normally also watches attachmentServiceProvider,
      // which needs real platform plugins unavailable in widget tests.
      // Settings only needs the account list, so bypass that dependency.
      accountsProvider.overrideWith((ref) => accountRepository.watchAccounts()),
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
    final first = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud-a.example.invalid',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final second = await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://cloud-b.example.invalid',
      loginName: 'bob',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 2),
    );

    await tester.pumpWidget(
      _wrap(accountRepository: accounts, overrides: []),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settle(tester);

    expect(find.text('alice'), findsOneWidget);
    expect(find.text('https://cloud-a.example.invalid'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('https://cloud-b.example.invalid'), findsOneWidget);

    // The second account was added last, so it is the selected one.
    expect(
      find.descendant(
        of: find.byKey(Key('account-tile-${second.id}')),
        matching: find.text('Active'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(Key('account-tile-${first.id}')),
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
    final only = await accounts.upsertAccount(
      accountId: 'account-only',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'solo',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );

    await tester.pumpWidget(
      _wrap(accountRepository: accounts, overrides: []),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settle(tester);

    expect(find.byType(ListTile).evaluate().length, greaterThanOrEqualTo(1));
    expect(find.text('solo'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(Key('account-tile-${only.id}')),
        matching: find.text('Active'),
      ),
      findsOneWidget,
    );

    // Tapping the already-active (only) account must not throw or change
    // anything: there is nothing else to switch to.
    await tester.tap(find.byKey(Key('account-tile-${only.id}')));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    final refreshed = await accounts.getAccount(only.id);
    expect(refreshed!.selected, isTrue);
  });

  testWidgets('tapping an inactive account switches the active account '
      'atomically without leaving two accounts selected', (tester) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final first = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud-a.example.invalid',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://cloud-b.example.invalid',
      loginName: 'bob',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 2),
    );
    // Second upsert selected account-b; switch back to account-a.

    await tester.pumpWidget(
      _wrap(accountRepository: accounts, overrides: []),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settle(tester);

    await tester.tap(find.byKey(Key('account-tile-${first.id}')));
    await _settle(tester);

    final all = await database.select(database.accounts).get();
    expect(all.where((account) => account.selected).length, 1);
    expect(
      all.singleWhere((account) => account.selected).id,
      first.id,
    );
    expect(
      find.descendant(
        of: find.byKey(Key('account-tile-${first.id}')),
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
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final store = _MemoryThemePreferenceStore();

    await tester.pumpWidget(
      _wrap(
        accountRepository: accounts,
        overrides: [themePreferenceStoreProvider.overrideWithValue(store)],
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settle(tester);

    RadioListTile<ThemeMode> radioTile(Key key) =>
        tester.widget<RadioListTile<ThemeMode>>(find.byKey(key));
    RadioGroup<ThemeMode> group() =>
        tester.widget<RadioGroup<ThemeMode>>(find.byType(RadioGroup<ThemeMode>));

    expect(group().groupValue, ThemeMode.system);
    expect(radioTile(const Key('theme-mode-dark')).value, ThemeMode.dark);

    await tester.tap(find.byKey(const Key('theme-mode-dark')));
    await _settle(tester);

    expect(group().groupValue, ThemeMode.dark);
    expect(store.stored, ThemeMode.dark);
    expect(store.writeCount, 1);

    await tester.tap(find.byKey(const Key('theme-mode-light')));
    await _settle(tester);

    expect(group().groupValue, ThemeMode.light);
    expect(store.stored, ThemeMode.light);
    expect(store.writeCount, 2);
  });

  testWidgets('loads the persisted theme mode on start', (tester) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final store = _MemoryThemePreferenceStore()..stored = ThemeMode.dark;

    await tester.pumpWidget(
      _wrap(
        accountRepository: accounts,
        overrides: [themePreferenceStoreProvider.overrideWithValue(store)],
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await _settle(tester);

    final group = tester.widget<RadioGroup<ThemeMode>>(
      find.byType(RadioGroup<ThemeMode>),
    );
    expect(group.groupValue, ThemeMode.dark);
  });
}
