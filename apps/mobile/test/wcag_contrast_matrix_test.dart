import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';

/// The contrast matrix of every foreground/background pair the app actually
/// paints text on, for the default theme and for a server accent, in light and
/// dark.
///
/// Written as a computation over `ThemeData` rather than as pixel sampling of
/// screenshots: a screenshot proves one frame on one device, while the pairs
/// below are what every screen composes from. A regression here changes the
/// numbers for every screen at once, which is exactly what the matrix is for.
void main() {
  // Deliberately not the built-in seed (`#00679E`): a server accent equal to
  // the default would produce the default scheme and prove nothing.
  const seedHex = '#8b1e3f';

  final variants = <({String name, ThemeData theme})>[
    (name: 'light default', theme: AppTheme.light()),
    (name: 'dark default', theme: AppTheme.dark()),
    (
      name: 'light server accent',
      theme: AppTheme.light(seedColor: AppTheme.seedFromServerHex(seedHex)),
    ),
    (
      name: 'dark server accent',
      theme: AppTheme.dark(seedColor: AppTheme.seedFromServerHex(seedHex)),
    ),
  ];

  List<({String pair, Color background, Color foreground})> pairsOf(
    ColorScheme scheme,
  ) => <({String pair, Color background, Color foreground})>[
    (pair: 'surface', background: scheme.surface, foreground: scheme.onSurface),
    (
      // Secondary text: timestamps, conversation subtitles, link source lines.
      pair: 'surface variant',
      background: scheme.surfaceContainerHighest,
      foreground: scheme.onSurfaceVariant,
    ),
    (
      // Own message bubble.
      pair: 'primary container',
      background: scheme.primaryContainer,
      foreground: scheme.onPrimaryContainer,
    ),
    (
      // Incoming message bubble.
      pair: 'secondary container',
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
    ),
    (pair: 'primary', background: scheme.primary, foreground: scheme.onPrimary),
    (
      // Sync failures and destructive confirmations.
      pair: 'error container',
      background: scheme.errorContainer,
      foreground: scheme.onErrorContainer,
    ),
    (pair: 'error', background: scheme.error, foreground: scheme.onError),
  ];

  test('every text pair clears WCAG AA for normal text', () {
    final report = StringBuffer();
    var lowest = double.infinity;
    late String lowestLabel;

    for (final variant in variants) {
      for (final pair in pairsOf(variant.theme.colorScheme)) {
        final ratio = _contrast(pair.background, pair.foreground);
        report.writeln(
          '${variant.name} / ${pair.pair}: ${ratio.toStringAsFixed(4)}:1',
        );
        if (ratio < lowest) {
          lowest = ratio;
          lowestLabel = '${variant.name} / ${pair.pair}';
        }
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              '${variant.name} / ${pair.pair} is ${ratio.toStringAsFixed(4)}:1',
        );
      }
    }

    // Printed so a release note can quote the measured floor of this build
    // instead of an older APK's number.
    // ignore: avoid_print
    print(report.toString().trim());
    // ignore: avoid_print
    print('lowest: $lowestLabel ${lowest.toStringAsFixed(4)}:1');
  });

  test('outlines stay visible against their own surface', () {
    for (final variant in variants) {
      final scheme = variant.theme.colorScheme;
      // Non-text contrast: WCAG asks 3:1 for boundaries a user has to see,
      // which is what separates a bubble, a card and a divider here.
      expect(
        _contrast(scheme.surface, scheme.outline),
        greaterThanOrEqualTo(3.0),
        reason: '${variant.name} outline',
      );
    }
  });

  test('a server accent never lowers a pair below the default theme floor', () {
    double floor(ThemeData theme) => pairsOf(theme.colorScheme)
        .map((pair) => _contrast(pair.background, pair.foreground))
        .reduce((a, b) => a < b ? a : b);

    // The accent comes from the server and is not trusted for foreground
    // choice; this is the assertion that keeps that promise measurable.
    expect(
      floor(AppTheme.light(seedColor: AppTheme.seedFromServerHex(seedHex))),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      floor(AppTheme.dark(seedColor: AppTheme.seedFromServerHex(seedHex))),
      greaterThanOrEqualTo(4.5),
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
