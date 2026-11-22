import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';

void main() {
  test('server color becomes an opaque Material seed', () {
    expect(AppTheme.seedFromServerHex('#00679e'), const Color(0xFF00679E));
    expect(AppTheme.seedFromServerHex('rgba(0, 0, 0, 0)'), isNull);
    expect(AppTheme.seedFromServerHex('#00679e80'), isNull);
  });

  test('server accent keeps primary text contrast in both themes', () {
    final seed = AppTheme.seedFromServerHex('#00679e');

    for (final theme in <ThemeData>[
      AppTheme.light(seedColor: seed),
      AppTheme.dark(seedColor: seed),
    ]) {
      expect(
        _contrast(theme.colorScheme.primary, theme.colorScheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(
          theme.colorScheme.primaryContainer,
          theme.colorScheme.onPrimaryContainer,
        ),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('supporting roles and component edges stay consistent', () {
    for (final theme in <ThemeData>[AppTheme.light(), AppTheme.dark()]) {
      final scheme = theme.colorScheme;

      expect(scheme.secondary, isNot(scheme.primary));
      expect(scheme.tertiary, isNot(scheme.primary));
      expect(scheme.tertiary, isNot(scheme.secondary));
      expect(theme.dividerTheme.color, scheme.outlineVariant);
      expect(theme.chipTheme.backgroundColor, scheme.surfaceContainerLow);
      expect(theme.chipTheme.selectedColor, scheme.secondaryContainer);
      expect(theme.chipTheme.checkmarkColor, scheme.onSecondaryContainer);
      expect(theme.chipTheme.side?.color, scheme.outlineVariant);
    }
  });

  test('a server colour carries its secondary and tertiary roles with it', () {
    const server = Color(0xFFE65100);
    for (final brightness in Brightness.values) {
      final custom =
          (brightness == Brightness.light
                  ? AppTheme.light(seedColor: server)
                  : AppTheme.dark(seedColor: server))
              .colorScheme;
      final expected = ColorScheme.fromSeed(
        seedColor: server,
        brightness: brightness,
      );
      final fallback =
          (brightness == Brightness.light ? AppTheme.light() : AppTheme.dark())
              .colorScheme;
      expect(custom.secondaryContainer, expected.secondaryContainer);
      expect(custom.tertiaryContainer, expected.tertiaryContainer);
      expect(custom.secondaryContainer, isNot(fallback.secondaryContainer));
      expect(custom.tertiaryContainer, isNot(fallback.tertiaryContainer));
    }
  });

  testWidgets('filter labels follow selected and disabled states', (
    tester,
  ) async {
    final theme = AppTheme.light();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Wrap(
            children: [
              FilterChip(
                selected: false,
                label: const Text('Default', key: Key('chip-default')),
                onSelected: (_) {},
              ),
              FilterChip(
                selected: true,
                label: const Text('Selected', key: Key('chip-selected')),
                onSelected: (_) {},
              ),
              const FilterChip(
                selected: false,
                label: Text('Disabled', key: Key('chip-disabled')),
                onSelected: null,
              ),
            ],
          ),
        ),
      ),
    );

    Color? renderedColor(String key) =>
        DefaultTextStyle.of(tester.element(find.byKey(Key(key)))).style.color;

    expect(renderedColor('chip-default'), theme.colorScheme.onSurfaceVariant);
    expect(
      renderedColor('chip-selected'),
      theme.colorScheme.onSecondaryContainer,
    );
    expect(
      renderedColor('chip-disabled'),
      theme.colorScheme.onSurface.withValues(alpha: 0.38),
    );
  });
}

double _contrast(Color first, Color second) {
  final lighter = first.computeLuminance() > second.computeLuminance()
      ? first
      : second;
  final darker = identical(lighter, first) ? second : first;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}
