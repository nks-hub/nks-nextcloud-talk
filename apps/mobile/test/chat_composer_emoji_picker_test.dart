import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_picker.dart';

void main() {
  const labels = EmojiPickerLabels(
    searchHint: 'Search emoji',
    noResults: 'No emoji found',
    categoryLabels: <EmojiCategory, String>{
      EmojiCategory.smileys: 'Smileys',
      EmojiCategory.people: 'People',
      EmojiCategory.animals: 'Animals',
      EmojiCategory.food: 'Food',
      EmojiCategory.activities: 'Activities',
      EmojiCategory.travel: 'Travel',
      EmojiCategory.objects: 'Objects',
      EmojiCategory.symbols: 'Symbols',
    },
  );

  test('catalog search matches localized names and keywords', () {
    final catalog = EmojiCatalog.standard();

    expect(
      catalog.search('wave').map((choice) => choice.glyph),
      contains('👋'),
    );
    expect(catalog.search('CAT').map((choice) => choice.glyph), contains('🐱'));
    expect(catalog.inCategory(EmojiCategory.food), isNotEmpty);
    expect(catalog.search('definitely absent'), isEmpty);
  });

  testWidgets('tap returns the exact Unicode choice', (tester) async {
    EmojiChoice? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmojiPicker(
            labels: labels,
            catalog: EmojiCatalog(const <EmojiChoice>[
              EmojiChoice(
                glyph: '👋',
                name: 'Waving hand',
                keywords: <String>['wave', 'hello'],
                category: EmojiCategory.people,
              ),
            ]),
            onSelected: (choice) => selected = choice,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('emoji-choice-waving-hand')));

    expect(selected?.glyph, '👋');
  });

  testWidgets('search filters choices and exposes an empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmojiPicker(
            labels: labels,
            catalog: EmojiCatalog(const <EmojiChoice>[
              EmojiChoice(
                glyph: '😀',
                name: 'Grinning face',
                keywords: <String>['smile'],
                category: EmojiCategory.smileys,
              ),
              EmojiChoice(
                glyph: '🐱',
                name: 'Cat',
                keywords: <String>['pet'],
                category: EmojiCategory.animals,
              ),
            ]),
            onSelected: (_) {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('emoji-search')), 'cat');
    await tester.pump();
    expect(find.text('🐱'), findsOneWidget);
    expect(find.text('😀'), findsNothing);

    await tester.enterText(find.byKey(const Key('emoji-search')), 'missing');
    await tester.pump();
    expect(find.text('No emoji found'), findsOneWidget);
  });

  testWidgets('choice is semantic button with a 48dp target', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmojiPicker(
            labels: labels,
            catalog: EmojiCatalog(const <EmojiChoice>[
              EmojiChoice(
                glyph: '😀',
                name: 'Grinning face',
                keywords: <String>['smile'],
                category: EmojiCategory.smileys,
              ),
            ]),
            onSelected: (_) {},
          ),
        ),
      ),
    );

    final choice = find.byKey(const Key('emoji-choice-grinning-face'));
    expect(tester.getSize(choice), const Size.square(48));
    final semanticsData = tester.getSemantics(choice).getSemanticsData();
    expect(semanticsData.label, 'Grinning face');
    expect(semanticsData.flagsCollection.isButton, isTrue);
    expect(semanticsData.hasAction(ui.SemanticsAction.tap), isTrue);
    semantics.dispose();
  });
}
