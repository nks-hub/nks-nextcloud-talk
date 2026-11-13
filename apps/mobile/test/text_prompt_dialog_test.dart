import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/text_prompt_dialog.dart';

void main() {
  Future<void> openPrompt(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showTextPromptDialog(
                  context: context,
                  title: 'Pozadí chatu',
                  initialValue: '#1E3A5F',
                  fieldLabel: 'Barva',
                  cancelLabel: 'Zrušit',
                  confirmLabel: 'Uložit',
                  fieldKey: const Key('prompt-field'),
                  confirmKey: const Key('prompt-save'),
                  maxLength: 7,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('on a landscape phone with the keyboard open the field and the '
      'save button stay above the keyboard', (tester) async {
    // Galaxy S9 as measured: 2220x1080 px at 420 dpi (2.625), held sideways,
    // a 63 px status bar and a 580 px keyboard; 500 px stay visible.
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(2220, 1080);
    tester.view.padding = const FakeViewPadding(top: 63);
    tester.view.viewPadding = const FakeViewPadding(top: 63);
    tester.view.viewInsets = const FakeViewPadding(bottom: 580);
    addTearDown(tester.view.reset);

    await openPrompt(tester);

    const visibleBottom = 500 / 2.625;
    final field = tester.getRect(find.byKey(const Key('prompt-field')));
    final save = tester.getRect(find.byKey(const Key('prompt-save')));
    expect(field.top, greaterThanOrEqualTo(63 / 2.625));
    expect(field.bottom, lessThanOrEqualTo(visibleBottom));
    expect(save.bottom, lessThanOrEqualTo(visibleBottom));
    // The field must not just be laid out inside the screen but shown: every
    // scroll viewport around it has to contain it.
    for (final viewport in find
        .ancestor(
          of: find.byKey(const Key('prompt-field')),
          matching: find.byType(Scrollable),
        )
        .evaluate()) {
      final rect = tester.getRect(find.byWidget(viewport.widget));
      expect(field.top, greaterThanOrEqualTo(rect.top - 0.5));
      expect(field.bottom, lessThanOrEqualTo(rect.bottom + 0.5));
    }

    await tester.tap(find.byKey(const Key('prompt-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prompt-field')), findsNothing);
  });

  testWidgets('on a portrait phone the prompt stays an ordinary dialog', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2220);
    addTearDown(tester.view.reset);

    await openPrompt(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(const Key('prompt-field')), findsOneWidget);
  });
}
