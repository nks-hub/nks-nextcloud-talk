import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/core/desktop_metrics.dart';

/// Mouse and keyboard get tighter controls than fingers do. The touch minimum
/// is an accessibility floor, so the mobile numbers are asserted exactly and
/// must never drift down; the desktop numbers are asserted so nobody silently
/// reverts the pointer-first sizing either.
void main() {
  Future<Map<String, Size>> measure(
    WidgetTester tester,
    TargetPlatform platform,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              IconButton(
                key: const Key('probe-icon'),
                onPressed: () {},
                icon: const Icon(Icons.info_outline_rounded),
              ),
              FilledButton(
                key: const Key('probe-filled'),
                onPressed: () {},
                child: const Text('F'),
              ),
              OutlinedButton(
                key: const Key('probe-outlined'),
                onPressed: () {},
                child: const Text('O'),
              ),
              const SizedBox(
                width: 400,
                child: TextField(key: Key('probe-field')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final sizes = <String, Size>{
      for (final name in const ['icon', 'filled', 'outlined', 'field'])
        name: tester.getSize(find.byKey(Key('probe-$name'))),
    };

    tester.view.reset();
    debugDefaultTargetPlatformOverride = null;
    return sizes;
  }

  testWidgets('touch platforms keep the 48 dp minimum', (tester) async {
    for (final platform in const [TargetPlatform.android, TargetPlatform.iOS]) {
      final sizes = await measure(tester, platform);
      expect(
        sizes['icon'],
        const Size(48, 48),
        reason: '$platform IconButton must stay a 48 dp touch target',
      );
      expect(
        sizes['filled']!.height,
        52,
        reason: '$platform FilledButton must stay 52 dp tall',
      );
      expect(
        sizes['outlined']!.height,
        greaterThanOrEqualTo(48),
        reason: '$platform OutlinedButton must stay a 48 dp touch target',
      );
      expect(sizes['field']!.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('pointer platforms get the tighter controls', (tester) async {
    for (final platform in const [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      final sizes = await measure(tester, platform);
      expect(sizes['icon'], const Size(36, 36), reason: '$platform IconButton');
      expect(sizes['filled']!.height, 38, reason: '$platform FilledButton');
      expect(sizes['outlined']!.height, 36, reason: '$platform OutlinedButton');
      expect(sizes['field']!.height, 40, reason: '$platform TextField');
    }
  });

  testWidgets('widget metrics follow the platform', (tester) async {
    Future<List<double>> metrics(TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      late List<double> read;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) {
              read = [
                context.listRowHeight,
                context.listAvatarRadius,
                context.paneHeaderHeight,
                context.secondaryRowHeight,
                context.actionRowHeight,
              ];
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
      return read;
    }

    expect(await metrics(TargetPlatform.android), [80, 24, 72, 72, 56]);
    expect(await metrics(TargetPlatform.iOS), [80, 24, 72, 72, 56]);
    for (final platform in const [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      expect(
        await metrics(platform),
        [56, 20, 52, 52, 44],
        reason: '$platform',
      );
    }
  });

  testWidgets('every pointer control stays above the small clickable area', (
    tester,
  ) async {
    // Nextcloud's own floor for a secondary control is 24 px. Shrinking past
    // that stops being density and starts being unusable.
    final sizes = await measure(tester, TargetPlatform.windows);
    for (final entry in sizes.entries) {
      expect(
        entry.value.height,
        greaterThanOrEqualTo(24),
        reason: '${entry.key} fell below the small clickable area',
      );
    }
  });
}
