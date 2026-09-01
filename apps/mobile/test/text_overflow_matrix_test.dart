import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

/// The screenshot half of the accessibility matrix, written as an assertion.
///
/// A screenshot proves one frame on one device and stops being evidence the
/// moment the build changes — which is why the older contrast and screenshot
/// reports could not be carried to a new hash. This pumps the real widgets at
/// 200 % text on a narrow screen, in both themes and both locales, and fails
/// on the overflow Flutter reports while painting.
///
/// A naive version of this file passed even at nine times the text size, so
/// the harness now proves it can fail: the last test feeds it a row that
/// really does overflow and requires a complaint.
void main() {
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

  final variants = <({String name, Locale locale, ThemeData theme})>[
    (name: 'cs light', locale: const Locale('cs'), theme: AppTheme.light()),
    (name: 'cs dark', locale: const Locale('cs'), theme: AppTheme.dark()),
    (name: 'en light', locale: const Locale('en'), theme: AppTheme.light()),
    (name: 'en dark', locale: const Locale('en'), theme: AppTheme.dark()),
  ];

  for (final variant in variants) {
    testWidgets(
      'the re-authentication banner fits at 200 % text — ${variant.name}',
      (tester) async {
        final overflows = await _overflowsWhilePainting(
          tester,
          variant: variant,
          child: ConversationWorkspace(
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

        expect(
          overflows,
          isEmpty,
          reason: '${variant.name}: ${overflows.join(' | ')}',
        );
        expect(
          find.byKey(const Key('reauthenticate-account')),
          findsOneWidget,
          reason: 'the action must survive the stacked layout',
        );
      },
    );
  }

  testWidgets('the harness complains about a row that really overflows', (
    tester,
  ) async {
    final overflows = await _overflowsWhilePainting(
      tester,
      variant: (
        name: 'guard',
        locale: const Locale('en'),
        theme: AppTheme.light(),
      ),
      child: const Row(
        children: [
          SizedBox(width: 900, height: 20),
          SizedBox(width: 900, height: 20),
        ],
      ),
    );

    expect(
      overflows,
      isNotEmpty,
      reason: 'without this the matrix above could not fail at all',
    );
  });
}

/// Pumps [child] on a narrow screen at 200 % text and returns every overflow
/// Flutter reported while painting it.
Future<List<String>> _overflowsWhilePainting(
  WidgetTester tester, {
  required ({String name, Locale locale, ThemeData theme}) variant,
  required Widget child,
}) async {
  // A small phone at double text is the tightest combination the app ships
  // for; anything wider only gets easier.
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final overflows = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString();
    if (message.contains('overflowed')) {
      overflows.add(message.split('\n').first);
      return;
    }
    previous?.call(details);
  };
  try {
    await tester.pumpWidget(
      MaterialApp(
        locale: variant.locale,
        theme: variant.theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, inner) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: inner!,
        ),
        home: ProviderScope(child: child),
      ),
    );
    await tester.pump();
  } finally {
    FlutterError.onError = previous;
  }
  return overflows;
}
