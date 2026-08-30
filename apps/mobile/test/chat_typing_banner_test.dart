import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';

import 'test_support.dart';

void main() {
  testWidgets('formats one through many participants in English', (
    tester,
  ) async {
    for (final entry in <(List<String>, String)>[
      (['Alice'], 'Alice is typing…'),
      (['Alice', 'Bob'], 'Alice and Bob are typing…'),
      (['Alice', 'Bob', 'Carol'], 'Alice, Bob and Carol are typing…'),
      (
        ['Alice', 'Bob', 'Carol', 'Dora'],
        'Alice, Bob, Carol and 1 other are typing…',
      ),
      (
        ['Alice', 'Bob', 'Carol', 'Dora', 'Eve'],
        'Alice, Bob, Carol and 2 others are typing…',
      ),
    ]) {
      await tester.pumpWidget(_app(names: entry.$1));
      await tester.pumpAndSettle();
      expect(find.text(entry.$2), findsOneWidget);
    }
  });

  testWidgets('uses Czech grammar and exposes a live-region label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        names: const ['Alice', 'Bob', 'Carol', 'Dora', 'Eve'],
        locale: const Locale('cs'),
      ),
    );
    await tester.pumpAndSettle();

    const label = 'Alice, Bob, Carol a 2 dalších píší…';
    expect(find.text(label), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('chat-typing-indicator'))),
      matchesSemantics(label: label, isLiveRegion: true),
    );
    semantics.dispose();
  });

  testWidgets('is readable in both application themes', (tester) async {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      await tester.pumpWidget(_app(names: const ['Alice'], theme: theme));
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text('Alice is typing…'));
      final foreground = text.style!.color!;
      final background = theme.colorScheme.surface;
      expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets('collapses completely when nobody is typing', (tester) async {
    await tester.pumpWidget(_app(names: const []));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-typing-indicator')), findsNothing);
    expect(
      find.byKey(const Key('chat-typing-indicator-hidden')),
      findsOneWidget,
    );
  });
}

Widget _app({
  required List<String> names,
  Locale locale = const Locale('en'),
  ThemeData? theme,
}) => localizedTestApp(
  locale: locale,
  theme: theme,
  home: Scaffold(
    body: Column(
      children: [
        const Expanded(child: SizedBox()),
        ChatTypingBanner(names: names),
        const SizedBox(height: 48),
      ],
    ),
  ),
);

double _contrast(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance()
      ? foreground
      : background;
  final darker = identical(lighter, foreground) ? background : foreground;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}
