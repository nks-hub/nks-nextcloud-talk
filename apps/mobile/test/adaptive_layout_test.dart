import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/onboarding/onboarding_screen.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

import 'test_support.dart';

void main() {
  testWidgets('onboarding becomes side-by-side on desktop', (tester) async {
    await _setViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(
      ProviderScope(child: localizedTestApp(home: const OnboardingScreen())),
    );
    await tester.pumpAndSettle();

    final introduction = tester.getRect(
      find.byKey(const Key('onboarding-introduction')),
    );
    final serverCard = tester.getRect(
      find.byKey(const Key('onboarding-server-card')),
    );
    expect(serverCard.left, greaterThan(introduction.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('onboarding stacks vertically on a phone in dark mode', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      ProviderScope(
        child: localizedTestApp(
          home: const OnboardingScreen(),
          theme: AppTheme.dark(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final introduction = tester.getRect(
      find.byKey(const Key('onboarding-introduction')),
    );
    final serverCard = tester.getRect(
      find.byKey(const Key('onboarding-server-card')),
    );
    final context = tester.element(
      find.byKey(const Key('onboarding-server-card')),
    );
    expect(serverCard.top, greaterThan(introduction.top));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reauthentication locks the stored server identity', (
    tester,
  ) async {
    const account = StoredAccount(
      id: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeaturesJson: '[]',
      selected: true,
      createdAtMillis: 1767225600000,
      lastSyncError: 'reauthenticationRequired',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: localizedTestApp(
          home: const OnboardingScreen(reauthenticateAccount: account),
        ),
      ),
    );
    await tester.pump();

    final serverField = tester.widget<TextField>(find.byType(TextField));
    expect(serverField.controller?.text, account.serverUrl);
    expect(serverField.enabled, isFalse);
    expect(find.text('Sign in to this account again'), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);
  });

  testWidgets('reauthentication notice exposes an explicit recovery action', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    var calls = 0;
    const account = StoredAccount(
      id: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeaturesJson: '[]',
      selected: true,
      createdAtMillis: 1767225600000,
      lastSyncError: 'reauthenticationRequired',
    );
    await tester.pumpWidget(
      localizedTestApp(
        home: ConversationWorkspace(
          account: account,
          accounts: const [account],
          conversations: const [],
          selectedConversationToken: null,
          loading: false,
          syncing: false,
          onRefresh: _completedRefresh,
          onReauthenticate: () async {
            calls++;
          },
          onSelectAccount: _ignoreString,
          onAddAccount: _ignore,
          onOpenConversation: _ignoreConversation,
          onCloseConversation: () {},
          onSelectConversation: _ignoreConversation,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('reauthenticate-account')));
    await tester.pump();

    expect(calls, 1);
    expect(find.text('This account must be signed in again.'), findsOneWidget);
  });

  testWidgets('conversation shell switches between desktop and compact modes', (
    tester,
  ) async {
    const account = StoredAccount(
      id: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeaturesJson: '[]',
      selected: true,
      createdAtMillis: 1767225600000,
    );
    const conversation = CachedConversation(
      accountId: 'account-a',
      token: 'room-a',
      displayName: 'Synthetic room A',
      description: 'Synthetic conversation',
      lastActivity: 1724300000,
      unreadMessages: 2,
      favorite: false,
      isArchived: false,
      readOnly: 0,
      roomType: 2,
      roomName: 'synthetic-room-a',
      objectType: '',
      avatarVersion: '1',
      isCustomAvatar: false,
      lastMessageText: 'Synthetic preview',
      lastMessageTimestamp: 1724300000,
      rawJson: '{}',
    );

    Widget app() => localizedTestApp(
      home: ConversationWorkspace(
        account: account,
        accounts: const [account],
        conversations: const [conversation],
        selectedConversationToken: null,
        loading: false,
        syncing: false,
        onRefresh: () async {},
        onSelectAccount: (_) {},
        onAddAccount: () {},
        onOpenConversation: (_) {},
        onCloseConversation: () {},
        onSelectConversation: (_) {},
      ),
    );

    await _setViewport(tester, const Size(1200, 800));
    await tester.pumpWidget(app());
    await tester.pump();
    expect(
      find.byKey(const Key('conversation-shell-expanded')),
      findsOneWidget,
    );
    final accountRail = tester.getRect(find.byKey(const Key('account-rail')));
    final conversationList = tester.getRect(
      find.byKey(const Key('conversation-list-pane')),
    );
    final conversationDetail = tester.getRect(
      find.byKey(const Key('conversation-detail-pane')),
    );
    expect(accountRail.right, lessThan(conversationList.left));
    expect(conversationList.right, lessThan(conversationDetail.left));

    await _setViewport(tester, const Size(390, 844));
    await tester.pump();
    expect(find.byKey(const Key('conversation-shell-compact')), findsOneWidget);
    expect(find.byKey(const Key('account-rail')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('expanded conversation header grows at 200 percent text scale', (
    tester,
  ) async {
    await _setViewport(tester, const Size(900, 800));

    await tester.pumpWidget(
      localizedTestApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(900, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: _accessibilityWorkspace(),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const Key('conversation-list-header'))).height,
      greaterThan(72),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected conversation is one labeled semantic button', (
    tester,
  ) async {
    await _setViewport(tester, const Size(900, 800));
    final semantics = tester.ensureSemantics();
    final database = openTestDatabase();
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(MemoryCredentialVault()),
        ],
        child: localizedTestApp(
          home: _accessibilityWorkspace(
            selectedConversationToken: _accessibilityConversation.token,
          ),
        ),
      ),
    );
    await tester.pump();

    final tile = find.byKey(const Key('conversation-tile-room-accessibility'));
    final tileContext = tester.element(tile);
    final expectedActivity = MaterialLocalizations.of(tileContext)
        .formatCompactDate(
          DateTime.fromMillisecondsSinceEpoch(
            _accessibilityConversation.lastActivity * 1000,
          ).toLocal(),
        );
    final expectedUnread = AppLocalizations.of(
      tileContext,
    ).unreadMessages(_accessibilityConversation.unreadMessages);
    final node = tester.getSemantics(tile);
    final data = node.getSemanticsData();
    expect(node.childrenCount, 0);
    expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
    expect(data.label, _accessibilityConversation.displayName);
    expect(data.value, contains(_accessibilityConversation.lastMessageText));
    expect(data.value, contains(expectedActivity));
    expect(data.value, contains(expectedUnread));
    expect(data.flagsCollection.isSelected, Tristate.isTrue);
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isImage, isFalse);
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('expanded selection renders the reusable chat room pane', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1200, 800));
    final database = openTestDatabase();
    addTearDown(database.close);
    const account = StoredAccount(
      id: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeaturesJson: '["avatar"]',
      selected: true,
      createdAtMillis: 1767225600000,
    );
    const conversation = CachedConversation(
      accountId: 'account-a',
      token: 'room-a',
      displayName: 'Synthetic room A',
      description: 'Synthetic conversation',
      lastActivity: 1724300000,
      unreadMessages: 2,
      favorite: false,
      isArchived: false,
      readOnly: 0,
      roomType: 2,
      roomName: 'synthetic-room-a',
      objectType: '',
      avatarVersion: '',
      isCustomAvatar: false,
      lastMessageText: 'Synthetic preview',
      lastMessageTimestamp: 1724300000,
      rawJson: '{}',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
        child: localizedTestApp(
          home: ConversationWorkspace(
            account: account,
            accounts: const [account],
            conversations: const [conversation],
            selectedConversationToken: conversation.token,
            loading: false,
            syncing: false,
            onRefresh: () async {},
            onSelectAccount: (_) {},
            onAddAccount: () {},
            onOpenConversation: (_) {},
            onCloseConversation: () {},
            onSelectConversation: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-room-pane')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

const _accessibilityAccount = StoredAccount(
  id: 'account-accessibility',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

const _accessibilityConversation = CachedConversation(
  accountId: 'account-accessibility',
  token: 'room-accessibility',
  displayName: 'Accessible room',
  description: 'Synthetic conversation',
  lastActivity: 1724300000,
  unreadMessages: 2,
  favorite: false,
  isArchived: false,
  readOnly: 0,
  roomType: 2,
  roomName: 'accessible-room',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  lastMessageText: 'Accessible preview',
  lastMessageTimestamp: 1724300000,
  rawJson: '{}',
);

ConversationWorkspace _accessibilityWorkspace({
  String? selectedConversationToken,
}) {
  return ConversationWorkspace(
    account: _accessibilityAccount,
    accounts: const [_accessibilityAccount],
    conversations: const [_accessibilityConversation],
    selectedConversationToken: selectedConversationToken,
    loading: false,
    syncing: false,
    onRefresh: _completedRefresh,
    onSelectAccount: _ignoreString,
    onAddAccount: _ignore,
    onOpenConversation: _ignoreConversation,
    onCloseConversation: () {},
    onSelectConversation: _ignoreConversation,
  );
}

Future<void> _completedRefresh() async {}

void _ignoreString(String _) {}

void _ignore() {}

void _ignoreConversation(CachedConversation _) {}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}
