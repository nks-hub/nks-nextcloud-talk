import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/color_palette.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

import 'test_support.dart';

/// Opens the palette and records what it returns.
final class _Host extends StatefulWidget {
  const _Host({required this.current, required this.onResult});

  final String? current;
  final ValueChanged<ColorPaletteChoice?> onResult;

  @override
  State<_Host> createState() => _HostState();
}

final class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const Key('open'),
        onPressed: () async => widget.onResult(
          await showColorPaletteDialog(
            context: context,
            title: 'Pick',
            current: widget.current,
            dialogKey: const Key('palette'),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  Future<void> open(
    WidgetTester tester, {
    String? current,
    required ValueChanged<ColorPaletteChoice?> onResult,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      localizedTestApp(
        textScale: textScale,
        home: _Host(current: current, onResult: onResult),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  group('palette dialog', () {
    testWidgets('offers twelve distinct swatches', (tester) async {
      await open(tester, onResult: (_) {});
      expect(colorPaletteHexes.toSet(), hasLength(12));
      for (final hex in colorPaletteHexes) {
        expect(find.byKey(Key('color-swatch-$hex')), findsOneWidget);
      }
    });

    testWidgets('tapping a swatch returns that colour', (tester) async {
      ColorPaletteChoice? result;
      await open(tester, onResult: (value) => result = value);
      await tester.tap(find.byKey(const Key('color-swatch-#1E3A5F')));
      await tester.pumpAndSettle();
      expect((result as ColorPaletteColor).hex, '#1E3A5F');
      expect(find.byKey(const Key('palette')), findsNothing);
    });

    testWidgets('marks the current swatch with a check and as selected', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      // Compared without regard to case.
      await open(tester, current: '#1e3a5f', onResult: (_) {});

      final selected = find.byKey(const Key('color-swatch-#1E3A5F'));
      expect(
        find.descendant(of: selected, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
      final data = tester.getSemantics(selected).getSemanticsData();
      expect(data.flagsCollection.isSelected, Tristate.isTrue);
      expect(data.flagsCollection.isButton, isTrue);

      final other = tester
          .getSemantics(find.byKey(const Key('color-swatch-#FFFFFF')))
          .getSemanticsData();
      expect(other.flagsCollection.isSelected, Tristate.isFalse);
      semantics.dispose();
    });

    testWidgets('every swatch is labelled with its colour name', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await open(tester, onResult: (_) {});
      final strings = AppLocalizations.of(
        tester.element(find.byKey(const Key('palette'))),
      );
      for (final hex in colorPaletteHexes) {
        final name = colorPaletteName(strings, hex);
        expect(name, isNotNull, reason: hex);
        expect(
          tester
              .getSemantics(find.byKey(Key('color-swatch-$hex')))
              .getSemanticsData()
              .label,
          name,
          reason: hex,
        );
      }
      expect(
        tester
            .getSemantics(find.byKey(const Key('color-swatch-#1E3A5F')))
            .getSemanticsData()
            .label,
        'Navy blue',
      );
      semantics.dispose();
    });

    testWidgets('every swatch is at least 48 x 48 dp', (tester) async {
      await open(tester, onResult: (_) {});
      for (final hex in colorPaletteHexes) {
        final size = tester.getSize(find.byKey(Key('color-swatch-$hex')));
        expect(size.width, greaterThanOrEqualTo(48), reason: hex);
        expect(size.height, greaterThanOrEqualTo(48), reason: hex);
      }
    });

    testWidgets('"Custom" and "Follow the theme" are separate answers', (
      tester,
    ) async {
      ColorPaletteChoice? result;
      await open(tester, onResult: (value) => result = value);
      await tester.tap(find.byKey(const Key('color-palette-custom')));
      await tester.pumpAndSettle();
      expect(result, isA<ColorPaletteCustom>());

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color-palette-theme')));
      await tester.pumpAndSettle();
      expect(result, isA<ColorPaletteTheme>());
    });

    testWidgets('a colour outside the palette shows under "Custom"', (
      tester,
    ) async {
      await open(tester, current: '#123456', onResult: (_) {});
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('color-palette-custom')),
          matching: find.text('#123456'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no colour set marks "Follow the theme"', (tester) async {
      await open(tester, onResult: (_) {});
      expect(
        find.descendant(
          of: find.byKey(const Key('color-palette-theme')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('dismissing returns nothing', (tester) async {
      ColorPaletteChoice? result = const ColorPaletteTheme();
      var answered = false;
      await open(
        tester,
        onResult: (value) {
          result = value;
          answered = true;
        },
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answered, isTrue);
      expect(result, isNull);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('fits a phone held sideways (640 x 360) at text scale $scale '
          'and every swatch can be reached', (tester) async {
        tester.view
          ..physicalSize = const Size(640, 360)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        ColorPaletteChoice? result;
        await open(
          tester,
          textScale: scale,
          onResult: (value) => result = value,
        );
        expect(tester.takeException(), isNull);

        final last = find.byKey(Key('color-swatch-${colorPaletteHexes.last}'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect((result as ColorPaletteColor).hex, colorPaletteHexes.last);
      });
    }
  });

  group('pickColor', () {
    Future<ColorPick?> run(
      WidgetTester tester, {
      String? current,
      required List<String> invalid,
      required Future<void> Function() interact,
    }) async {
      ColorPick? picked;
      var finished = false;
      await tester.pumpWidget(
        localizedTestApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('open'),
                onPressed: () async {
                  picked = await pickColor(
                    context: context,
                    title: 'Pick',
                    current: current,
                    fieldLabel: 'Colour',
                    normalize: (text) =>
                        RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(text)
                        ? text.toUpperCase()
                        : null,
                    onInvalid: () => invalid.add('invalid'),
                    promptKey: const Key('prompt'),
                    fieldKey: const Key('field'),
                    confirmKey: const Key('save'),
                  );
                  finished = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await interact();
      await tester.pumpAndSettle();
      expect(finished, isTrue);
      return picked;
    }

    testWidgets('a swatch is the value, upper case', (tester) async {
      final picked = await run(
        tester,
        invalid: [],
        interact: () =>
            tester.tap(find.byKey(const Key('color-swatch-#2F6FEB'))),
      );
      expect(picked, (value: '#2F6FEB'));
    });

    testWidgets('"Follow the theme" clears the value', (tester) async {
      final picked = await run(
        tester,
        current: '#2F6FEB',
        invalid: [],
        interact: () =>
            tester.tap(find.byKey(const Key('color-palette-theme'))),
      );
      expect(picked, (value: null));
    });

    testWidgets('custom hex is normalised', (tester) async {
      final picked = await run(
        tester,
        invalid: [],
        interact: () async {
          await tester.tap(find.byKey(const Key('color-palette-custom')));
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(const Key('field')), '#abcdef');
          await tester.tap(find.byKey(const Key('save')));
        },
      );
      expect(picked, (value: '#ABCDEF'));
    });

    testWidgets('an empty custom value clears, an invalid one picks nothing', (
      tester,
    ) async {
      final cleared = await run(
        tester,
        current: '#123456',
        invalid: [],
        interact: () async {
          await tester.tap(find.byKey(const Key('color-palette-custom')));
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(const Key('field')), '');
          await tester.tap(find.byKey(const Key('save')));
        },
      );
      expect(cleared, (value: null));

      final invalid = <String>[];
      final rejected = await run(
        tester,
        invalid: invalid,
        interact: () async {
          await tester.tap(find.byKey(const Key('color-palette-custom')));
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(const Key('field')), 'magenta');
          await tester.tap(find.byKey(const Key('save')));
        },
      );
      expect(rejected, isNull);
      expect(invalid, ['invalid']);
    });
  });
}
