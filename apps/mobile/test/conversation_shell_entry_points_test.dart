import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_screen.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';
import 'package:nextcloudtalk/features/settings/theme_preference.dart';

import 'test_support.dart';

/// Both screens below already had their own passing tests while being
/// unreachable from the running app. These tests assert the calling chain
/// itself, so a screen can never again count as done without an entry point.
void main() {
  Future<StoredAccount> seedAccount(AppDatabase database) async {
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'test-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    return account;
  }

  Widget wrapShell(
    AppDatabase database,
    StoredAccount account, {
    List<Override> overrides = const [],
  }) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(MemoryCredentialVault()),
        accountsProvider.overrideWith((ref) => Stream.value([account])),
        selectedAccountProvider.overrideWith((ref) => Stream.value(account)),
        // Plain streams instead of the drift-backed ones: the fake clock in
        // testWidgets never drains drift's live-query timers.
        conversationsProvider.overrideWith(
          (ref, accountId) => Stream.value(const <CachedConversation>[]),
        ),
        chatMessagesProvider.overrideWith(
          (ref, key) => Stream.value(const <CachedChatMessage>[]),
        ),
        outgoingMessageStatusesProvider.overrideWith(
          (ref, key) => Stream.value(const <OutgoingMessageStatus>[]),
        ),
        textSendOperationsProvider.overrideWith(
          (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
        ),
        chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
        ...overrides,
      ],
      child: localizedTestApp(home: const ConversationShell()),
    );
  }

  /// The two layouts reach the same screens through different chrome, so a
  /// wiring gap in one of them is invisible from the other.
  const layouts = <String, Size>{
    'compact': Size(420, 900),
    'expanded': Size(1280, 900),
  };

  for (final layout in layouts.entries) {
    final isCompact = layout.key == 'compact';

    Future<void> pumpShell(WidgetTester tester) async {
      tester.view.physicalSize = layout.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = openTestDatabase();
      addTearDown(database.close);
      late StoredAccount account;
      await tester.runAsync(() async => account = await seedAccount(database));

      await tester.pumpWidget(
        wrapShell(
          database,
          account,
          overrides: [
            themePreferenceStoreProvider.overrideWithValue(
              _MemoryThemePreferenceStore(),
            ),
          ],
        ),
      );
      await tester.pump();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }

    testWidgets('${layout.key}: the shell reaches the new conversation screen', (
      tester,
    ) async {
      await pumpShell(tester);

      expect(
        find.byKey(const Key('open-new-conversation')),
        findsOneWidget,
        reason: 'NewConversationScreen has no other way in',
      );
      await tester.tap(find.byKey(const Key('open-new-conversation')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(NewConversationScreen), findsOneWidget);
    });

    testWidgets('${layout.key}: the shell reaches the settings screen', (
      tester,
    ) async {
      await pumpShell(tester);

      if (isCompact) {
        // Compact hides the accounts behind a menu; expanded shows a rail.
        await tester.tap(find.byTooltip('Switch account'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.byKey(const Key('open-settings')), findsOneWidget);

      await tester.tap(find.byKey(const Key('open-settings')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  }

  testWidgets(
    'the app applies the stored theme mode instead of the system one',
    (tester) async {
      final store = _MemoryThemePreferenceStore()..stored = ThemeMode.dark;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            themePreferenceStoreProvider.overrideWithValue(store),
            accountsProvider.overrideWith(
              (ref) => Stream.value(const <StoredAccount>[]),
            ),
            selectedAccountProvider.overrideWith((ref) => Stream.value(null)),
          ],
          child: const NextcloudTalkApp(),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(
        app.themeMode,
        ThemeMode.dark,
        reason: 'a hardcoded ThemeMode.system silently ignores the setting',
      );
      expect(app.darkTheme?.brightness, AppTheme.dark().brightness);
    },
  );
}

final class _MemoryThemePreferenceStore implements ThemePreferenceStore {
  ThemeMode stored = ThemeMode.system;

  @override
  Future<ThemeMode> read() async => stored;

  @override
  Future<void> write(ThemeMode mode) async => stored = mode;
}
