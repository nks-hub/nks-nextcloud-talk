import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/core/section_header_style.dart';
import 'package:nextcloudtalk/features/chat/chat_background_theme.dart';

void main() {
  for (final theme in [AppTheme.light(), AppTheme.dark()]) {
    testWidgets('section headings read at 4.5:1 on the surface in '
        '${theme.brightness.name}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: SectionHeaderText('Participants')),
        ),
      );

      final style = tester.widget<Text>(find.text('Participants')).style!;
      expect(style.color, theme.colorScheme.tertiary);
      expect(style.fontWeight, FontWeight.w600);
      expect(
        chatBackgroundContrast(style.color!, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  testWidgets('a section heading is a header for screen readers', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: SectionHeaderText('Participants')),
      ),
    );

    expect(
      tester.getSemantics(find.text('Participants')),
      matchesSemantics(label: 'Participants', isHeader: true),
    );
    semantics.dispose();
  });

  test(
    'the dark inset colour is darker than the surface but not near-black',
    () {
      final scheme = AppTheme.dark().colorScheme;

      expect(
        scheme.surfaceContainerLowest.computeLuminance(),
        lessThan(scheme.surface.computeLuminance()),
      );
      expect(
        scheme.surfaceContainerLowest.computeLuminance(),
        greaterThan(0.005),
      );
      expect(
        chatBackgroundContrast(scheme.onSurface, scheme.surfaceContainerLowest),
        greaterThanOrEqualTo(4.5),
      );
    },
  );
}
