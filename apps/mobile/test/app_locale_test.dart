import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';

import 'test_support.dart';

void main() {
  for (final scenario in <({List<Locale> preferred, String expected})>[
    (preferred: [Locale('de', 'DE')], expected: 'en'),
    (preferred: [Locale('cs', 'CZ')], expected: 'cs'),
    (preferred: [Locale('en', 'GB')], expected: 'en'),
    (preferred: [Locale('cs', 'US')], expected: 'cs'),
    (preferred: [Locale('de'), Locale('cs')], expected: 'cs'),
    (preferred: [Locale('en'), Locale('cs')], expected: 'en'),
    (preferred: [Locale('cs'), Locale('en')], expected: 'cs'),
    (preferred: [], expected: 'en'),
  ]) {
    testWidgets('${scenario.preferred} resolves to ${scenario.expected}', (
      tester,
    ) async {
      final database = openTestDatabase();
      addTearDown(database.close);
      tester.binding.platformDispatcher.localesTestValue = scenario.preferred;
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(database)],
          child: const NextcloudTalkApp(),
        ),
      );
      await tester.pump();
      final context = tester.element(find.byType(Navigator).first);
      expect(Localizations.localeOf(context).languageCode, scenario.expected);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }

  testWidgets('a running app follows changes in the device language', (
    tester,
  ) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('cs')];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
        child: const NextcloudTalkApp(),
      ),
    );
    for (final language in ['cs', 'de', 'en', 'cs']) {
      tester.binding.platformDispatcher.localesTestValue = [Locale(language)];
      await tester.pump();
      final context = tester.element(find.byType(Navigator).first);
      expect(
        Localizations.localeOf(context).languageCode,
        language == 'de' ? 'en' : language,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
