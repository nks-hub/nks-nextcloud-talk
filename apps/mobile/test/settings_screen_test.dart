import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_cache.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:nextcloudtalk/features/settings/account_removal_service.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';
import 'package:nextcloudtalk/features/settings/theme_preference.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';

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

/// Lets a multi-step real async chain (Drift plus file I/O plus a mocked HTTP
/// round trip) finish while the tree keeps rebuilding between steps.
///
/// One [_flushRealAsync] only covers a single hop. `pumpAndSettle` is
/// deliberately not used anywhere here: it budgets in fake time, so against
/// this tree it spins for ten minutes before giving up.
Future<void> _settleRealAsync(WidgetTester tester, {int rounds = 24}) async {
  for (var round = 0; round < rounds; round++) {
    await _flushRealAsync(tester);
    await tester.pump();
  }
}

/// Flushes real async work until [condition] holds.
///
/// A fixed number of rounds is a race against the machine: under load the work
/// simply has not landed yet and the test then reports a stale read as a bug.
/// Both removal tests here have flaked that way in a loaded full-suite run
/// while passing on their own.
Future<void> _settleUntil(
  WidgetTester tester,
  Future<bool> Function() condition, {
  int rounds = 200,
}) async {
  for (var round = 0; round < rounds; round++) {
    await _flushRealAsync(tester);
    await tester.pump();
    if (await tester.runAsync(condition) ?? false) {
      return;
    }
  }
  fail('the condition was not reached after $rounds rounds');
}

/// Opens a route whose transition is bounded, without `pumpAndSettle`.
Future<void> _pumpRouteTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
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

/// A real [AccountRemovalService] wired to test doubles: an in-memory vault,
/// a mocked server, and temporary directories. Nothing here may touch the
/// real home directory, so every path lives under one temp root that the
/// caller's tearDown removes again.
({
  AccountRemovalService service,
  MemoryCredentialVault vault,
  List<String> calls,
})
_removalService(
  WidgetTester tester,
  AccountRepository accounts, {
  bool serverReachable = true,
}) {
  final vault = MemoryCredentialVault();
  final calls = <String>[];
  final root = Directory.systemTemp.createTempSync('nctalk-settings-removal-');
  addTearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });
  final api = HttpNextcloudApi(
    client: MockClient((request) async {
      calls.add(request.url.path);
      if (!serverReachable) {
        throw const SocketException('offline');
      }
      return http.Response(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'ok',
              'statuscode': 200,
              'message': 'OK',
            },
            'data': <String, Object?>{},
          },
        }),
        200,
      );
    }),
  );
  return (
    service: AccountRemovalService(
      accounts: accounts,
      credentials: vault,
      api: api,
      mediaCache: ChatMediaCache(),
      mediaDiskCache: ChatMediaDiskCache(
        rootDirectory: () async =>
            Directory('${root.path}${Platform.pathSeparator}previews'),
      ),
      emojiUsage: FileEmojiUsageStore(
        directory: Directory('${root.path}${Platform.pathSeparator}emoji'),
      ),
      clearChatBackgrounds: (_) async {},
      voiceDirectory: () async =>
          Directory('${root.path}${Platform.pathSeparator}voice'),
      chatAttachmentDirectory: () async => root,
      attachmentSources: () async => DurableAttachmentSourceStore(
        root: Directory('${root.path}${Platform.pathSeparator}sources'),
      ),
    ),
    vault: vault,
    calls: calls,
  );
}

void main() {
  testWidgets('removing an account asks first, and cancelling keeps it', (
    tester,
  ) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    late List<StoredAccount> initial;
    await tester.runAsync(() async {
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud-a.example.invalid',
        loginName: 'alice',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      initial = await _allAccounts(database);
    });
    final removal = _removalService(tester, accounts);
    removal.vault.values['account-a'] = 'fixture-app-password-never-use';

    await tester.pumpWidget(
      _wrap(
        accountRepository: accounts,
        accountsStream: Stream.value(initial),
        overrides: [
          accountRemovalServiceProvider.overrideWithValue(removal.service),
        ],
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('account-remove-account-a')));
    await _pumpRouteTransition(tester);

    expect(find.byKey(const Key('account-remove-dialog')), findsOneWidget);
    expect(find.text('Remove this account?'), findsOneWidget);
    // The dialog has to name what is about to be destroyed.
    expect(find.textContaining('alice'), findsWidgets);
    expect(
      find.textContaining('https://cloud-a.example.invalid'),
      findsWidgets,
    );

    await tester.tap(find.byKey(const Key('account-remove-cancel')));
    await _pumpRouteTransition(tester);
    await _settleRealAsync(tester);

    expect(find.byKey(const Key('account-remove-dialog')), findsNothing);
    late StoredAccount? survivor;
    await tester.runAsync(() async {
      survivor = await accounts.getAccount('account-a');
    });
    expect(survivor, isNotNull);
    expect(removal.vault.values['account-a'], isNotNull);
    expect(removal.calls, isEmpty);
  });

  testWidgets('confirming the dialog removes the account and its credential', (
    tester,
  ) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    late List<StoredAccount> initial;
    await tester.runAsync(() async {
      await accounts.upsertAccount(
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
      initial = await _allAccounts(database);
    });
    final removal = _removalService(tester, accounts);
    removal.vault.values['account-a'] = 'fixture-app-password-never-use';
    removal.vault.values['account-b'] = 'fixture-app-password-never-use';

    await tester.pumpWidget(
      _wrap(
        accountRepository: accounts,
        accountsStream: Stream.value(initial),
        overrides: [
          accountRemovalServiceProvider.overrideWithValue(removal.service),
        ],
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('account-remove-account-a')));
    await _pumpRouteTransition(tester);
    await tester.tap(find.byKey(const Key('account-remove-confirm')));
    await _pumpRouteTransition(tester);
    await _settleUntil(
      tester,
      // Both halves matter: the row leaves the database and the user is told
      // so. Waiting only for the first returns before the snackbar exists.
      () async =>
          await accounts.getAccount('account-a') == null &&
          find.text('The account was removed.').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400));

    late StoredAccount? removed;
    late StoredAccount? kept;
    await tester.runAsync(() async {
      removed = await accounts.getAccount('account-a');
      kept = await accounts.getAccount('account-b');
    });
    expect(removed, isNull);
    expect(removal.vault.values.containsKey('account-a'), isFalse);
    // Removing an account that was not the active one leaves the active one
    // alone.
    expect(kept, isNotNull);
    expect(kept!.selected, isTrue);
    expect(removal.vault.values['account-b'], isNotNull);
    expect(find.text('The account was removed.'), findsOneWidget);
  });

  testWidgets('an unreachable server still removes the account locally and '
      'says the app password was not revoked', (tester) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    late List<StoredAccount> initial;
    await tester.runAsync(() async {
      await accounts.upsertAccount(
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
      initial = await _allAccounts(database);
    });
    final removal = _removalService(tester, accounts, serverReachable: false);
    removal.vault.values['account-a'] = 'fixture-app-password-never-use';

    await tester.pumpWidget(
      _wrap(
        accountRepository: accounts,
        accountsStream: Stream.value(initial),
        overrides: [
          accountRemovalServiceProvider.overrideWithValue(removal.service),
        ],
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('account-remove-account-a')));
    await _pumpRouteTransition(tester);
    await tester.tap(find.byKey(const Key('account-remove-confirm')));
    await _pumpRouteTransition(tester);
    await _settleUntil(
      tester,
      () async =>
          await accounts.getAccount('account-a') == null &&
          find
              .textContaining('did not confirm the app password was revoked')
              .evaluate()
              .isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400));

    late StoredAccount? removed;
    await tester.runAsync(() async {
      removed = await accounts.getAccount('account-a');
    });
    expect(removed, isNull);
    expect(removal.vault.values.containsKey('account-a'), isFalse);
    expect(
      find.textContaining('did not confirm the app password was revoked'),
      findsOneWidget,
    );
  });

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
    // The theme tiles sit below every other settings section, so the default
    // 800x600 test surface leaves them off-screen and a tap would miss.
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    RadioGroup<ThemeMode> group() => tester.widget<RadioGroup<ThemeMode>>(
      find.byType(RadioGroup<ThemeMode>),
    );

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
