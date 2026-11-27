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

  testWidgets(
    'a tablet keyboard keeps both accounts and navigation reachable',
    (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpShell(
        tester,
        accounts: [account('account-a'), account('account-b')],
      );
      expect(find.byKey(const Key('account-rail')), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('account-rail')), findsNothing);
      expect(find.byKey(const Key('inbox-nav-calls')), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('user-account-b'), findsOneWidget);
    },
  );

  testWidgets('wide layout separates the list from the conversation surface', (
    tester,
  ) async {
    await _pumpWide(tester, accounts: [account('account-a')]);

    final surface = tester.widget<Container>(
      find.byKey(const Key('conversation-list-pane')),
    );
    expect(surface.color, AppTheme.light().colorScheme.surfaceContainerLow);
  });

  testWidgets('wide list keeps its loading and empty states', (tester) async {
    await _pumpWide(tester, accounts: [account('account-a')], loading: true);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await _pumpWide(tester, accounts: [account('account-a')]);
    expect(find.text('No conversations yet'), findsOneWidget);
  });

  testWidgets('single and multi-account navigation reserve only their width', (
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

    expect(single - withRail, kAccountRailWidth - 56);
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

  for (final width in [280.0, 300.0, 360.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('the list header is calm at ${width.toInt()} px and '
          '${(scale * 100).toInt()} % text', (tester) async {
        final searchable = StoredAccount(
          id: 'account-a',
          serverUrl: 'https://account-a.example.invalid',
          loginName: 'user-a',
          serverProductName: 'Nextcloud',
          talkFeaturesJson: '["unified-search","archived-conversations-v2"]',
          selected: true,
          createdAtMillis: 1767225600000,
        );
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final overflows = await overflowsWhile(
          () => _pumpShell(
            tester,
            accounts: [searchable],
            listWidth: width,
            textScale: scale,
          ),
        );
        expect(overflows, isEmpty, reason: overflows.join(' | '));

        final pane = tester.getRect(
          find.byKey(const Key('conversation-list-pane')),
        );
        final search = tester.getRect(
          find.byKey(const Key('open-message-search')),
        );
        final add = tester.getRect(
          find.byKey(const Key('open-new-conversation')),
        );
        final refresh = tester.getRect(
          find.byKey(const Key('refresh-conversations')),
        );
        final title = tester.getRect(find.byKey(const Key('inbox-heading')));
        final localSearch = tester.getRect(
          find.byKey(const Key('conversation-name-search')),
        );
        expect(localSearch.left - pane.left, 12);
        expect(pane.right - search.right, 12);
        expect(search.top, greaterThan(title.bottom));
        expect(localSearch.right, lessThanOrEqualTo(search.left));
        for (final action in [add, refresh]) {
          expect(action.width, greaterThanOrEqualTo(48));
          expect(action.height, greaterThanOrEqualTo(48));
          expect(action.center.dy, lessThan(search.top));
          expect(action.left, greaterThan(title.left));
        }
        expect(add.right, lessThanOrEqualTo(refresh.left + 0.5));
        expect(find.byTooltip('New conversation'), findsOneWidget);
        expect(find.byTooltip('Refresh'), findsOneWidget);
      });
    }
  }
}

Future<void> _pumpWide(
  WidgetTester tester, {
  required List<StoredAccount> accounts,
  bool listCollapsed = false,
  bool loading = false,
  ValueChanged<double>? onResizeList,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await _pumpShell(
    tester,
    accounts: accounts,
    listCollapsed: listCollapsed,
    loading: loading,
    onResizeList: onResizeList,
  );
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required List<StoredAccount> accounts,
  bool listCollapsed = false,
  bool loading = false,
  ValueChanged<double>? onResizeList,
  double? listWidth,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConversationWorkspace(
          account: accounts.first,
          accounts: accounts,
          conversations: const [],
          selectedConversationToken: null,
          loading: loading,
          syncing: false,
          onRefresh: () async {},
          onSelectAccount: (_) {},
          onAddAccount: () {},
          onOpenConversation: (_) {},
          onCloseConversation: () {},
          onSelectConversation: (_) {},
          listCollapsed: listCollapsed,
          onResizeList: onResizeList,
          listWidth: listWidth,
        ),
      ),
    ),
  );
  await tester.pump();
}
