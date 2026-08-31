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
}

double _contrast(Color first, Color second) {
  final lighter = first.computeLuminance() > second.computeLuminance()
      ? first
      : second;
  final darker = identical(lighter, first) ? second : first;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}
