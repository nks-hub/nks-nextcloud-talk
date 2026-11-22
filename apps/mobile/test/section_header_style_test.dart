import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/core/section_header_style.dart';
import 'package:nextcloudtalk/features/chat/chat_background_theme.dart';

void main() {
  for (final theme in [AppTheme.light(), AppTheme.dark()]) {
    testWidgets('section headings read at 4.5:1 on the surface in '
        '${theme.brightness.name}', (tester) async {
      late TextStyle style;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              style = sectionHeaderStyle(context)!;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(style.color, theme.colorScheme.tertiary);
      expect(style.fontWeight, FontWeight.w600);
      expect(
        chatBackgroundContrast(style.color!, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

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
