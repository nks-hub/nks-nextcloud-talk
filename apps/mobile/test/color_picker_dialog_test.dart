import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/color_picker_dialog.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

void main() {
  test('hex round trip accepts a missing hash and rejects junk', () {
    expect(colorPickerParse('#1a2B3c'), const Color(0xFF1A2B3C));
    expect(colorPickerParse(' 1A2B3C '), const Color(0xFF1A2B3C));
    expect(colorPickerParse('#12345'), isNull);
    expect(colorPickerParse('#GGGGGG'), isNull);
    expect(colorPickerHex(const Color(0xFF0A0B0C)), '#0A0B0C');
  });

  Future<Future<String?>> open(WidgetTester tester, String initial) async {
    late Future<String?> result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('cs'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showColorPickerDialog(
              context: context,
              title: 'Barva',
              initialValue: initial,
              fieldLabel: 'Hex',
              cancelLabel: 'Zrušit',
              confirmLabel: 'Uložit',
              fieldKey: const Key('field'),
              confirmKey: const Key('save'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('dragging the shade field to the bottom picks black', (
    tester,
  ) async {
    final result = await open(tester, '#2F6FEB');
    final shade = find.byKey(const Key('color-picker-shade'));
    await tester.dragFrom(
      tester.getCenter(shade),
      const Offset(-1000, 1000),
    );
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const Key('field')));
    expect(field.controller!.text, '#000000');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(await result, '#000000');
  });

  testWidgets('typing a hex moves the preview, and an empty field clears', (
    tester,
  ) async {
    final result = await open(tester, '#2F6FEB');
    await tester.enterText(find.byKey(const Key('field')), '#D64545');
    await tester.pump();
    final preview = tester.widget<Container>(
      find.byKey(const Key('color-picker-preview')),
    );
    expect(
      (preview.decoration! as BoxDecoration).color,
      const Color(0xFFD64545),
    );
    await tester.enterText(find.byKey(const Key('field')), '');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(await result, '');
  });

  testWidgets('the hue bar changes the hue and keeps the field in step', (
    tester,
  ) async {
    await open(tester, '#FF0000');
    final hue = find.byKey(const Key('color-picker-hue'));
    await tester.tapAt(tester.getCenter(hue));
    await tester.pump();
    final text = tester
        .widget<TextField>(find.byKey(const Key('field')))
        .controller!
        .text;
    final picked = HSVColor.fromColor(colorPickerParse(text)!);
    expect(picked.hue, closeTo(180, 3));
    expect(picked.saturation, closeTo(1, 0.01));
  });
}
