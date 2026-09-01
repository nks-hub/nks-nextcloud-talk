import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

/// Every control that shows only an icon has to say what it does.
///
/// A screen reader reads the tooltip of an [IconButton] as its name; without
/// one the user hears "button" and has to guess. Auditing this by hand is what
/// the older accessibility passes did, and the result stopped being true the
/// moment a screen changed — so it is asserted instead.
///
/// Only screens that actually have icon-only controls belong here. Onboarding
/// was tried and dropped: it has none, so the case proved nothing.
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
    await _pump(
      tester,
      ConversationWorkspace(
        account: account,
        accounts: const [account],
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
      ),
    );

    _expectEveryIconButtonNamed(tester);
  });

  testWidgets('the audit notices a button that says nothing', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
      ),
    );

    // Without this the two audits above could pass on a screen that has no
    // icon buttons at all, or on a matcher that never looks.
    expect(
      _unnamedIconButtons(tester),
      isNotEmpty,
      reason: 'the audit has to be able to fail',
    );
  });
}

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

List<IconButton> _unnamedIconButtons(WidgetTester tester) => tester
    .widgetList<IconButton>(find.byType(IconButton))
    .where((button) => (button.tooltip ?? '').trim().isEmpty)
    .toList(growable: false);

void _expectEveryIconButtonNamed(WidgetTester tester) {
  final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
  expect(
    buttons,
    isNotEmpty,
    reason: 'a screen with no icon buttons would pass without proving anything',
  );
  expect(
    _unnamedIconButtons(tester).map((button) => button.icon.toString()),
    isEmpty,
  );
}
