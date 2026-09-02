import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

import 'accessibility_probe.dart';

/// Every control that shows only an icon has to say what it does.
///
/// A screen reader announces the name it finds in the semantics tree; without
/// one the user hears "button" and has to guess. Auditing this by hand is what
/// the older accessibility passes did, and the result stopped being true the
/// moment a screen changed — so it is asserted instead.
///
/// Only screens that actually have icon-only controls belong here. Onboarding
/// was tried and dropped: it has none, so the case proved nothing. Screens
/// that need a database and a mocked server are audited inside their own
/// suites, where that harness already exists — see `settings_screen_test.dart`,
/// `diagnostics_screen_test.dart` and `room_details_screen_test.dart`.
void main() {
  const account = StoredAccount(
    id: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '[]',
    selected: true,
    createdAtMillis: 1767225600000,
  );

  testWidgets('the conversation workspace names every icon-only control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _workspace(account));

    expectEveryButtonNamed(tester, screen: 'conversation workspace');
    semantics.dispose();
  });

  testWidgets('the conversation workspace reads in the order it is laid out', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _workspace(account));

    expectReadingOrderFollowsLayout(tester, screen: 'conversation workspace');
    semantics.dispose();
  });

  testWidgets('a quiet workspace announces nothing on its own', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _workspace(account));

    // The one live region the app has belongs to an open room, where an
    // arriving message speaks. A second one on the list would interrupt it.
    expectLiveRegions(tester, screen: 'conversation workspace', count: 0);
    semantics.dispose();
  });

  testWidgets('the audit notices a button that says nothing', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      Scaffold(
        body: IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
      ),
    );

    // Without this the audits above could pass on a screen that has no icon
    // buttons at all, or on a matcher that never looks.
    expect(
      unnamedButtons(tester),
      isNotEmpty,
      reason: 'the audit has to be able to fail',
    );
    semantics.dispose();
  });

  testWidgets('the audit notices a reading order that fights the layout', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      Scaffold(
        body: Column(
          children: [
            Semantics(
              sortKey: const OrdinalSortKey(2),
              child: const Text('spoken second, shown first'),
            ),
            Semantics(
              sortKey: const OrdinalSortKey(1),
              child: const Text('spoken first, shown second'),
            ),
          ],
        ),
      ),
    );

    expect(
      () => expectReadingOrderFollowsLayout(tester, screen: 'guard'),
      throwsA(isA<TestFailure>()),
      reason: 'the order check has to be able to fail',
    );
    expect(semanticsReadingOrder(tester), [
      'spoken first, shown second',
      'spoken second, shown first',
    ]);
    semantics.dispose();
  });

  testWidgets('the live-region count notices an extra announcement', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      Scaffold(
        body: Semantics(
          liveRegion: true,
          child: const Text('speaks on its own'),
        ),
      ),
    );

    expect(
      () => expectLiveRegions(tester, screen: 'guard', count: 0),
      throwsA(isA<TestFailure>()),
      reason: 'the live-region check has to be able to fail',
    );
    semantics.dispose();
  });
}

Widget _workspace(StoredAccount account) => ConversationWorkspace(
  account: account,
  accounts: [account],
  conversations: const [],
  selectedConversationToken: null,
  loading: false,
  syncing: false,
  onRefresh: () async {},
  onReauthenticate: () async {},
  onSelectAccount: (_) {},
  onAddAccount: () {},
  onOpenConversation: (_) {},
  onCloseConversation: () {},
  onSelectConversation: (_) {},
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('cs'),
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
  await tester.pump();
}
