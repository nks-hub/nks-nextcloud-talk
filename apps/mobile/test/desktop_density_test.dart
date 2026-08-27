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
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
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
                context.listPaneWidth,
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

    // 1400 wide viewport, so the touch width is the >= 1100 variant.
    expect(await metrics(TargetPlatform.android), [80, 24, 72, 72, 56, 390]);
    expect(await metrics(TargetPlatform.iOS), [80, 24, 72, 72, 56, 390]);
    for (final platform in const [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      expect(
        await metrics(platform),
        [56, 20, 52, 52, 44, 300],
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

  /// The measured symptom this guards: on a 1400 px window a settings row put
  /// its label at the left edge and its switch at x ~ 1353, leaving over a
  /// thousand pixels of nothing between them.
  ///
  /// Driven by [VisualDensity] rather than a platform override, because that
  /// is the signal `AppMetrics` actually reads.
  testWidgets('a settings row does not stretch across a wide window', (
    tester,
  ) async {
    Future<double> rowWidth(VisualDensity density) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(visualDensity: density),
          home: Scaffold(
            body: ContentColumn(
              child: ListView(
                children: [
                  SwitchListTile(
                    key: const Key('probe-row'),
                    title: const Text('Call notifications'),
                    value: true,
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final width = tester.getSize(find.byKey(const Key('probe-row'))).width;
      // Unmount between measurements: reusing the element tree would let the
      // second density silently inherit the first one's layout.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      return width;
    }

    expect(
      await rowWidth(VisualDensity.compact),
      lessThanOrEqualTo(700),
      reason: 'a pointer-first row must stay inside the content column',
    );
    // A phone is never wide enough for the gap to matter, and capping there
    // would waste the little width it has.
    expect(await rowWidth(VisualDensity.standard), 1400);
  });
}
