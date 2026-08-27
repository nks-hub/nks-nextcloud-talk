import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_screen.dart';
import 'package:nextcloudtalk/features/rooms/room_details_screen.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';
import 'package:nextcloudtalk/features/settings/theme_preference.dart';

import 'test_support.dart';

/// Both screens below already had their own passing tests while being
/// unreachable from the running app. These tests assert the calling chain
/// itself, so a screen can never again count as done without an entry point.
void main() {
  Future<StoredAccount> seedAccount(
    AppDatabase database, {
    String accountId = 'account-a',
    Set<String> talkFeatures = const {},
  }) async {
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://$accountId.example.invalid',
      loginName: 'user-$accountId',
      serverProductName: 'Nextcloud',
      talkFeatures: talkFeatures,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    return account;
  }

  Widget wrapShell(
    AppDatabase database,
    StoredAccount account, {
    List<Override> overrides = const [],
    List<StoredAccount>? availableAccounts,
    Stream<StoredAccount?>? selectedAccounts,
    Map<String, List<CachedConversation>> conversationsByAccount = const {},
    Set<ChatRoomProviderKey>? observedChatKeys,
  }) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        clientPushEnabledProvider.overrideWithValue(false),
        credentialVaultProvider.overrideWithValue(MemoryCredentialVault()),
        accountsProvider.overrideWith(
          (ref) => Stream.value(availableAccounts ?? [account]),
        ),
        selectedAccountProvider.overrideWith(
          (ref) => selectedAccounts ?? Stream.value(account),
        ),
        // Plain streams instead of the drift-backed ones: the fake clock in
        // testWidgets never drains drift's live-query timers.
        conversationsProvider.overrideWith(
          (ref, accountId) => Stream.value(
            conversationsByAccount[accountId] ?? const <CachedConversation>[],
          ),
        ),
        chatMessagesProvider.overrideWith((ref, key) {
          observedChatKeys?.add(key);
          return Stream.value(const <CachedChatMessage>[]);
        }),
        outgoingMessageStatusesProvider.overrideWith(
          (ref, key) => Stream.value(const <OutgoingMessageStatus>[]),
        ),
        textSendOperationsProvider.overrideWith(
          (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
        ),
        chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
        connectivityWakeEventsProvider.overrideWithValue(
          const Stream<void>.empty(),
        ),
        chatAttachmentDependenciesProvider.overrideWith(
          (ref, key) => Future<ChatAttachmentDependencies>.error(
            StateError('attachment transport is outside this route test'),
            StackTrace.empty,
          ),
        ),
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

    Future<StoredAccount> pumpShell(
      WidgetTester tester, {
      Map<String, List<CachedConversation>> conversationsByAccount = const {},
      Set<ChatRoomProviderKey>? observedChatKeys,
      List<Override> overrides = const [],
      List<String> talkFeatures = const ['unified-search'],
    }) async {
      tester.view.physicalSize = layout.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = openTestDatabase();
      addTearDown(database.close);
      late StoredAccount account;
      await tester.runAsync(
        () async => account = await seedAccount(
          database,
          talkFeatures: talkFeatures.toSet(),
        ),
      );

      await tester.pumpWidget(
        wrapShell(
          database,
          account,
          conversationsByAccount: conversationsByAccount,
          observedChatKeys: observedChatKeys,
          overrides: [
            themePreferenceStoreProvider.overrideWithValue(
              _MemoryThemePreferenceStore(),
            ),
            ...overrides,
          ],
        ),
      );
      await tester.pump();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      return account;
    }

    testWidgets(
      '${layout.key}: a conversation tile opens the production room route',
      (tester) async {
        final observedChatKeys = <ChatRoomProviderKey>{};
        final liveConversation = _conversation(
          'account-a',
          'roomlive',
          displayName: 'Live peer',
          roomType: 1,
          peerStatus: 'online',
          peerStatusIcon: '🌟',
          peerStatusMessage: 'Focusing',
          rawJson: '{"hasCall":true}',
        );
        final routedAccount = await pumpShell(
          tester,
          conversationsByAccount: {
            'account-a': [liveConversation],
          },
          observedChatKeys: observedChatKeys,
          overrides: [
            callTransportProvider.overrideWith(
              (ref, key) async => CallTransport.internal,
            ),
          ],
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('conversation-tile-roomlive')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // Both layouts render the same pane now: the compact shell shows it in
        // place of the list instead of pushing a route, so a selected
        // conversation survives a resize in either direction.
        expect(find.byType(PresenceChatRoomScreen), findsNothing);
        expect(
          find.byType(PresenceChatRoomPane),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('conversation-presence-text-roomlive')),
          findsOneWidget,
        );
        expect(find.text('🌟 Focusing'), findsOneWidget);
        expect(find.byKey(const Key('call-banner')), findsOneWidget);
        expect(find.byKey(const Key('open-room-details')), findsOneWidget);
        expect(
          observedChatKeys,
          contains((
            accountId: routedAccount.id,
            roomToken: liveConversation.token,
            threadId: null,
          )),
        );

        await tester.tap(find.byKey(const Key('open-room-details')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(RoomDetailsScreen), findsOneWidget);
      },
    );

    testWidgets(
      '${layout.key}: the shell reaches the new conversation screen',
      (tester) async {
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
      },
    );

    testWidgets('${layout.key}: arrows walk the conversation list', (
      tester,
    ) async {
      await pumpShell(
        tester,
        conversationsByAccount: {
          'account-a': [
            _conversation('account-a', 'roomone'),
            _conversation('account-a', 'roomtwo'),
            _conversation('account-a', 'roomthree'),
          ],
        },
      );

      // Flutter's directional traversal already does this; the test is here so
      // a later wrapper around the tiles cannot quietly take it away.
      String? focusedToken() {
        final context = FocusManager.instance.primaryFocus?.context;
        if (context == null) {
          return null;
        }
        String? token;
        context.visitAncestorElements((element) {
          final key = element.widget.key;
          if (key is ValueKey<String> &&
              key.value.startsWith('conversation-tile-')) {
            token = key.value.substring('conversation-tile-'.length);
            return false;
          }
          return true;
        });
        return token;
      }

      // Tab first: without focus inside the list there is nothing to move.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      var seen = <String?>[focusedToken()];
      for (var step = 0; step < 6 && seen.last == null; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        seen = [...seen, focusedToken()];
      }
      final first = seen.last;
      expect(first, isNotNull, reason: 'Tab must reach a conversation tile');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final second = focusedToken();
      expect(second, isNotNull);
      expect(second, isNot(first), reason: 'Down must move to the next room');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(focusedToken(), first, reason: 'Up must come back');
    });

    testWidgets('${layout.key}: no search without unified-search', (
      tester,
    ) async {
      // The server has no provider to ask, so the entry point would only ever
      // reach a dead end.
      await pumpShell(tester, talkFeatures: const ['avatar']);

      expect(find.byKey(const Key('open-message-search')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('message-search-field')), findsNothing);
    });

    testWidgets('${layout.key}: Ctrl+F opens the message search', (
      tester,
    ) async {
      await pumpShell(tester);
      expect(find.byKey(const Key('message-search-field')), findsNothing);

      // A shortcut only reaches its binding through the focused node's
      // ancestors, so put focus inside the shell first — which is also the
      // cheapest check that Tab traversal finds anything at all here.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.context,
        isNotNull,
        reason: 'Tab must land on something focusable in the shell',
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('message-search-field')), findsOneWidget);
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

    testWidgets('${layout.key}: an account switch resets archive filtering', (
      tester,
    ) async {
      tester.view.physicalSize = layout.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = openTestDatabase();
      addTearDown(database.close);
      late StoredAccount accountA;
      late StoredAccount accountB;
      await tester.runAsync(() async {
        accountA = await seedAccount(
          database,
          talkFeatures: const {'archived-conversations-v2'},
        );
        accountB = await seedAccount(
          database,
          accountId: 'account-b',
          talkFeatures: const {'archived-conversations-v2'},
        );
      });
      final selectedAccounts = StreamController<StoredAccount?>();
      addTearDown(selectedAccounts.close);

      await tester.pumpWidget(
        wrapShell(
          database,
          accountA,
          availableAccounts: [accountA, accountB],
          selectedAccounts: selectedAccounts.stream,
          conversationsByAccount: {
            accountA.id: [
              _conversation(accountA.id, 'roomaa'),
              _conversation(accountA.id, 'roomab', archived: true),
            ],
            accountB.id: [
              _conversation(accountB.id, 'roomba'),
              _conversation(accountB.id, 'roombb', archived: true),
            ],
          },
          overrides: [
            themePreferenceStoreProvider.overrideWithValue(
              _MemoryThemePreferenceStore(),
            ),
          ],
        ),
      );
      selectedAccounts.add(accountA);
      await tester.pump();
      await tester.pump();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });

      expect(find.byKey(const Key('conversation-tile-roomaa')), findsOneWidget);
      await tester.tap(find.byKey(const Key('conversation-filter-archived')));
      await tester.pump();
      expect(find.byKey(const Key('conversation-tile-roomab')), findsOneWidget);

      selectedAccounts.add(accountB);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('conversation-tile-roomba')), findsOneWidget);
      expect(find.byKey(const Key('conversation-tile-roombb')), findsNothing);
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const Key('conversation-filter-archived')),
            )
            .selected,
        isFalse,
      );
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
            // No server behind this tree, so the live channel stays off.
            clientPushEnabledProvider.overrideWithValue(false),
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

CachedConversation _conversation(
  String accountId,
  String token, {
  bool archived = false,
  String? displayName,
  int roomType = 2,
  String? peerStatus,
  String? peerStatusIcon,
  String? peerStatusMessage,
  String rawJson = '{}',
}) {
  return CachedConversation(
    accountId: accountId,
    token: token,
    displayName: displayName ?? token,
    description: '',
    lastActivity: 1,
    unreadMessages: 0,
    favorite: false,
    isArchived: archived,
    readOnly: 0,
    roomType: roomType,
    roomName: '',
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    peerStatus: peerStatus,
    peerStatusIcon: peerStatusIcon,
    peerStatusMessage: peerStatusMessage,
    lastMessageText: 'Preview',
    lastMessageTimestamp: 1,
    rawJson: rawJson,
  );
}

final class _MemoryThemePreferenceStore implements ThemePreferenceStore {
  ThemeMode stored = ThemeMode.system;

  @override
  Future<ThemeMode> read() async => stored;

  @override
  Future<void> write(ThemeMode mode) async => stored = mode;
}
