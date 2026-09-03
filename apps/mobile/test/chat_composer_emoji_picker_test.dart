import 'dart:ui' as ui;

import 'package:emojis/emoji.dart' as unicode;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_picker.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  const labels = EmojiPickerLabels(
    title: 'Emoji',
    closeTooltip: 'Close emoji picker',
    manageFavorites: 'Manage favorites',
    finishManagingFavorites: 'Finish managing favorites',
    favoriteModeHint: 'Tap emoji to add or remove favorites',
    addFavoriteLabel: 'Add to favorites',
    removeFavoriteLabel: 'Remove from favorites',
    searchHint: 'Search emoji',
    noResults: 'No emoji found',
    noRecents: 'No recently used emoji',
    noFavorites: 'No favorite emoji',
    categoryLabels: <EmojiCategory, String>{
      EmojiCategory.favorites: 'Favorites',
      EmojiCategory.recent: 'Recent',
      EmojiCategory.smileys: 'Smileys',
      EmojiCategory.people: 'People',
      EmojiCategory.animals: 'Animals',
      EmojiCategory.food: 'Food',
      EmojiCategory.activities: 'Activities',
      EmojiCategory.travel: 'Travel',
      EmojiCategory.objects: 'Objects',
      EmojiCategory.symbols: 'Symbols',
      EmojiCategory.flags: 'Flags',
    },
  );

  test(
    'standard catalog exposes every Unicode 17 emoji from the data source',
    () {
      final catalog = EmojiCatalog.standard();

      expect(catalog.choices.length, unicode.Emoji.all().length);
      expect(catalog.choices.length, greaterThanOrEqualTo(3900));
      expect(catalog.categories, contains(EmojiCategory.flags));
      expect(
        catalog.search('flag: Czechia').map((choice) => choice.glyph),
        contains('🇨🇿'),
      );
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
            accountId: AccountId.parse('account-a'),
            usageStore: _MemoryEmojiUsageStore(),
            labels: labels,
            catalog: EmojiCatalog(const <EmojiChoice>[
              EmojiChoice(
                glyph: '👋',
                name: 'Waving hand',
                keywords: <String>['wave', 'hello'],
                category: EmojiCategory.people,
              ),
            ]),
            onClose: () {},
            onSelected: (choice) => selected = choice,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('emoji-choice-waving-hand')));
    await tester.pumpAndSettle();

    expect(selected?.glyph, '👋');
  });

  testWidgets('search filters choices and exposes an empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmojiPicker(
            accountId: AccountId.parse('account-a'),
            usageStore: _MemoryEmojiUsageStore(),
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
            onClose: () {},
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

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
            accountId: AccountId.parse('account-a'),
            usageStore: _MemoryEmojiUsageStore(),
            labels: labels,
            catalog: EmojiCatalog(const <EmojiChoice>[
              EmojiChoice(
                glyph: '😀',
                name: 'Grinning face',
                keywords: <String>['smile'],
                category: EmojiCategory.smileys,
              ),
            ]),
            onClose: () {},
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final choice = find.byKey(const Key('emoji-choice-grinning-face'));
    expect(tester.getSize(choice), const Size.square(48));
    final semanticsData = tester.getSemantics(choice).getSemanticsData();
    expect(semanticsData.label, 'Grinning face');
    expect(semanticsData.flagsCollection.isButton, isTrue);
    expect(semanticsData.hasAction(ui.SemanticsAction.tap), isTrue);
    semantics.dispose();
  });

  test('search finds the same emoji in Czech and in English', () {
    final catalog = EmojiCatalog.standard();

    for (final pair in const <List<String>>[
      <String>['heart', 'srdce'],
      <String>['love', 'láska'],
      <String>['dog', 'pes'],
      <String>['coffee', 'káva'],
      <String>['thumbs up', 'palec nahoru'],
    ]) {
      final english = catalog.search(pair.first).map((c) => c.glyph).toSet();
      final czech = catalog.search(pair.last).map((c) => c.glyph).toSet();
      expect(english, isNotEmpty, reason: 'English query "${pair.first}"');
      expect(
        czech.intersection(english),
        isNotEmpty,
        reason: 'Czech query "${pair.last}" must reach the English matches',
      );
    }

    expect(catalog.search('srdce').map((c) => c.glyph), contains('❤️'));
    expect(catalog.search('heart').map((c) => c.glyph), contains('❤️'));
  });

  test('the whole Unicode catalog has Czech names and keywords from CLDR', () {
    final catalog = EmojiCatalog.standard();
    // Nothing in the hand-written table covers these; CLDR does.
    final beaver = catalog.choices.firstWhere((choice) => choice.glyph == '🦫');
    expect(beaver.nameFor(const Locale('cs')), 'Bobr');
    expect(catalog.search('hlodavec').map((c) => c.glyph), contains('🦫'));
    expect(catalog.search('tající').map((c) => c.glyph), contains('🫠'));

    // Coverage, not a sample: every glyph the picker offers must translate.
    final untranslated = catalog.choices
        .where((choice) => choice.nameFor(const Locale('cs')) == choice.name)
        .where((choice) => choice.category != EmojiCategory.flags)
        .map((choice) => choice.glyph)
        .toList();
    // Cognates such as Pizza or Panda and the 26 regional indicators read
    // the same in both languages, so the bar is 2 %, not zero.
    expect(
      untranslated.length,
      lessThan(catalog.choices.length ~/ 50),
      reason: 'more than 2 % of glyphs fall back to English: $untranslated',
    );
  });

  test('display name follows the locale, widget key does not', () {
    final heart = EmojiCatalog.standard().choices.firstWhere(
      (choice) => choice.glyph == '❤️',
    );

    expect(heart.nameFor(const Locale('cs')), 'Červené srdce');
    expect(heart.nameFor(const Locale('en')), 'Red heart');
    expect(heart.nameFor(null), 'Red heart');
    expect(heart.keyName, 'red-heart');
  });

  testWidgets('semantic label is localized for a Czech locale', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      localizedTestApp(
        locale: const Locale('cs'),
        home: Scaffold(
          body: EmojiPicker(
            accountId: AccountId.parse('account-a'),
            usageStore: _MemoryEmojiUsageStore(),
            labels: labels,
            catalog: EmojiCatalog(const <EmojiChoice>[
              EmojiChoice(
                glyph: '❤️',
                name: 'Red heart',
                keywords: <String>['heart', 'love'],
                category: EmojiCategory.symbols,
              ),
            ]),
            onClose: () {},
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final choice = find.byKey(const Key('emoji-choice-red-heart'));
    expect(
      tester.getSemantics(choice).getSemanticsData().label,
      'Červené srdce',
    );
    semantics.dispose();
  });

  testWidgets('picker has a header, close action, recents and favorites', (
    tester,
  ) async {
    var closed = false;
    final store = _MemoryEmojiUsageStore(
      initial: EmojiUsage(recent: <String>['👋'], favorites: <String>['❤️']),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmojiPicker(
            accountId: AccountId.parse('account-a'),
            usageStore: store,
            labels: labels,
            catalog: EmojiCatalog(const <EmojiChoice>[
              EmojiChoice(
                glyph: '👋',
                name: 'Waving hand',
                keywords: <String>['wave'],
                category: EmojiCategory.people,
              ),
              EmojiChoice(
                glyph: '❤️',
                name: 'Red heart',
                keywords: <String>['heart'],
                category: EmojiCategory.symbols,
              ),
            ]),
            onClose: () => closed = true,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Emoji'), findsOneWidget);
    expect(find.byKey(const Key('emoji-close')), findsOneWidget);
    expect(find.byKey(const Key('emoji-category-recent')), findsOneWidget);
    expect(find.byKey(const Key('emoji-category-favorites')), findsOneWidget);
    expect(find.text('👋'), findsOneWidget);

    await tester.tap(find.byKey(const Key('emoji-close')));
    expect(closed, isTrue);
  });

  testWidgets('selected emoji becomes the first recent choice', (tester) async {
    final store = _MemoryEmojiUsageStore();
    EmojiChoice? selected;
    final catalog = EmojiCatalog(const <EmojiChoice>[
      EmojiChoice(
        glyph: '👋',
        name: 'Waving hand',
        keywords: <String>['wave'],
        category: EmojiCategory.people,
      ),
    ]);

    Widget picker() => MaterialApp(
      home: Scaffold(
        body: EmojiPicker(
          accountId: AccountId.parse('account-a'),
          usageStore: store,
          labels: labels,
          catalog: catalog,
          onClose: () {},
          onSelected: (choice) => selected = choice,
        ),
      ),
    );

    await tester.pumpWidget(picker());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('emoji-choice-waving-hand')));
    await tester.pumpAndSettle();
    expect(selected?.glyph, '👋');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    selected = null;
    await tester.pumpWidget(picker());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('emoji-category-recent')), findsOneWidget);
    expect(find.text('👋'), findsOneWidget);
  });

  testWidgets('favorite management toggles without selecting the emoji', (
    tester,
  ) async {
    final store = _MemoryEmojiUsageStore();
    EmojiChoice? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmojiPicker(
            accountId: AccountId.parse('account-a'),
            usageStore: store,
            labels: labels,
            catalog: EmojiCatalog(const <EmojiChoice>[
              EmojiChoice(
                glyph: '❤️',
                name: 'Red heart',
                keywords: <String>['heart'],
                category: EmojiCategory.symbols,
              ),
            ]),
            onClose: () {},
            onSelected: (choice) => selected = choice,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('emoji-manage-favorites')));
    await tester.pump();
    expect(find.text('Tap emoji to add or remove favorites'), findsOneWidget);
    await tester.tap(find.byKey(const Key('emoji-choice-red-heart')));
    await tester.pumpAndSettle();

    expect(selected, isNull);
    expect((await store.read(AccountId.parse('account-a'))).favorites, <String>[
      '❤️',
    ]);
    expect(find.byKey(const Key('emoji-favorite-red-heart')), findsOneWidget);
  });
}

final class _MemoryEmojiUsageStore implements EmojiUsageStore {
  _MemoryEmojiUsageStore({EmojiUsage initial = EmojiUsage.empty})
    : _usage = initial;

  EmojiUsage _usage;

  @override
  Future<void> delete(AccountId accountId) async {
    _usage = EmojiUsage.empty;
  }

  @override
  Future<EmojiUsage> read(AccountId accountId) async => _usage;

  @override
  Future<EmojiUsage> recordSelection(AccountId accountId, String glyph) async {
    _usage = EmojiUsage(
      recent: <String>[glyph, ..._usage.recent.where((item) => item != glyph)],
      favorites: _usage.favorites,
    );
    return _usage;
  }

  @override
  Future<EmojiUsage> toggleFavorite(AccountId accountId, String glyph) async {
    final favorites = List<String>.of(_usage.favorites);
    favorites.contains(glyph) ? favorites.remove(glyph) : favorites.add(glyph);
    _usage = EmojiUsage(recent: _usage.recent, favorites: favorites);
    return _usage;
  }
}
