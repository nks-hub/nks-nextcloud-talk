import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

import 'accessibility_probe.dart';

/// How much of a wide window the app is allowed to spend on chrome.
///
/// The rationale is in `docs/architecture/desktop-chrome.md`. The short of it:
/// the account rail is 88 px of window height whose only job is switching
/// accounts, and with one account it switches nothing — its own list item has
/// a null onTap, so it is not even a target. The same three actions already
/// live in the account menu the narrow layout uses.
void main() {
  StoredAccount account(String id) => StoredAccount(
    id: id,
    serverUrl: 'https://$id.example.invalid',
    loginName: 'user-$id',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '[]',
    selected: id == 'account-a',
    createdAtMillis: 1767225600000,
  );

  testWidgets('one account gets no rail, and keeps every action it carried', (
    tester,
  ) async {
    await _pumpWide(tester, accounts: [account('account-a')]);

    expect(find.byKey(const Key('account-rail')), findsNothing);
    // The actions the rail used to hold have to survive its removal, or this
    // reclaims space by hiding features.
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('a second account brings the rail back', (tester) async {
    await _pumpWide(
      tester,
      accounts: [account('account-a'), account('account-b')],
    );

    expect(find.byKey(const Key('account-rail')), findsOneWidget);
  });

  testWidgets('dropping the rail hands its width to the conversation', (
    tester,
  ) async {
    await _pumpWide(tester, accounts: [account('account-a')]);
    final single = tester
        .getSize(find.byKey(const Key('conversation-detail-pane')))
        .width;

    await _pumpWide(
      tester,
      accounts: [account('account-a'), account('account-b')],
    );
    final withRail = tester
        .getSize(find.byKey(const Key('conversation-detail-pane')))
        .width;

    // 88 for the rail and 1 for its divider. Asserted as a number because
    // "looks wider" is what let it sit there unnoticed.
    expect(single - withRail, 89);
  });

  testWidgets('the list is not folded away while no conversation is open', (
    tester,
  ) async {
    // Folding exists to give a conversation room. With no conversation the
    // folded window held only the "select a conversation" placeholder, and
    // the toggle that brings the list back lives in the conversation pane
    // that was not there — found on a 7-inch tablet on 6 September 2026.
    // What folding does once a room IS open is measured in
    // `adaptive_breakpoint_test.dart`, where one can be opened.
    await _pumpWide(
      tester,
      accounts: [account('account-a')],
      listCollapsed: true,
      onResizeList: (_) {},
    );

    expect(find.byKey(const Key('conversation-list-pane')), findsOneWidget);
    expect(find.byKey(const Key('conversation-list-splitter')), findsOneWidget);
  });

  testWidgets('nothing offers to fold the list while no room is open', (
    tester,
  ) async {
    // The toggle lives in the conversation header, and with no conversation
    // there is no header — folding the list would leave an empty window.
    await _pumpWide(tester, accounts: [account('account-a')]);

    expect(find.byKey(const Key('toggle-conversation-list')), findsNothing);
  });

  testWidgets('a narrow window offers no fold, having nowhere to fold to', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpShell(tester, accounts: [account('account-a')]);

    expect(find.byKey(const Key('toggle-conversation-list')), findsNothing);
  });
  testWidgets('the divider between list and conversation can be grabbed', (
    tester,
  ) async {
    var dragged = 0.0;
    await _pumpWide(
      tester,
      accounts: [account('account-a')],
      onResizeList: (width) => dragged = width,
    );
    final splitter = find.byKey(const Key('conversation-list-splitter'));
    expect(splitter, findsOneWidget);

    // The widget's width does not move during the gesture (nothing feeds the
    // drag back here), so a drag measured from the start lands exactly 60 px
    // further; a drag adding deltas to a stale width would have jittered.
    final before = tester.getSize(
      find.byKey(const Key('conversation-list-pane')),
    );
    await tester.drag(splitter, const Offset(60, 0));
    expect(dragged, before.width + 60);

  });

  testWidgets('a cramped window keeps the list until a room is open', (
    tester,
  ) async {
    // Two panes fit long before the conversation has room to be used: at
    // 1000 px the rail and the list leave the chat under 620. That is a reason
    // to fold the list once a conversation needs the room, and no reason at
    // all while the window holds nothing but the placeholder — the automatic
    // fold with a room open is guarded in `adaptive_breakpoint_test.dart`.
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpShell(
      tester,
      accounts: [account('account-a'), account('account-b')],
    );

    expect(find.byKey(const Key('conversation-list-pane')), findsOneWidget);
  });

  testWidgets('the list header fits its pane instead of breaking a word', (
    tester,
  ) async {
    // The pane is 300 px wide and the header already carries the account
    // avatar and three actions. A title there wrapped mid-syllable, which is
    // what this guards against - on both account counts, because the avatar
    // only appears when the rail is gone.
    for (final list in [
      [account('account-a')],
      [account('account-a'), account('account-b')],
    ]) {
      final overflows = await overflowsWhile(
        () => _pumpWide(tester, accounts: list),
      );
      expect(overflows, isEmpty, reason: overflows.join('\n'));
    }
  });
}

Future<void> _pumpWide(
  WidgetTester tester, {
  required List<StoredAccount> accounts,
  bool listCollapsed = false,
  ValueChanged<double>? onResizeList,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await _pumpShell(
    tester,
    accounts: accounts,
    listCollapsed: listCollapsed,
    onResizeList: onResizeList,
  );
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required List<StoredAccount> accounts,
  bool listCollapsed = false,
  ValueChanged<double>? onResizeList,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConversationWorkspace(
          account: accounts.first,
          accounts: accounts,
          conversations: const [],
          selectedConversationToken: null,
          loading: false,
          syncing: false,
          onRefresh: () async {},
          onSelectAccount: (_) {},
          onAddAccount: () {},
          onOpenConversation: (_) {},
          onCloseConversation: () {},
          onSelectConversation: (_) {},
          listCollapsed: listCollapsed,
          onResizeList: onResizeList,
        ),
      ),
    ),
  );
  await tester.pump();
}
