import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_picker.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:nextcloudtalk/platform/emoji_glyph_support.dart';
import 'package:talk_protocol/talk_protocol.dart';

const _labels = EmojiPickerLabels(
  title: 'Emoji',
  closeTooltip: 'Close',
  manageFavorites: 'Manage favourites',
  finishManagingFavorites: 'Finish managing favourites',
  favoriteModeHint: 'Tap emoji to add or remove favourites',
  addFavoriteLabel: 'Add to favourites',
  removeFavoriteLabel: 'Remove from favourites',
  searchHint: 'Search emoji',
  noResults: 'No emoji found',
  noRecents: 'No recently used emoji',
  noFavorites: 'No favourite emoji',
  composerCategories: 'Emoji categories',
  composerDone: 'Done',
  composerFavoriteError: 'Could not save favourites',
  composerSearchFavorites: 'Search favourites',
  categoryLabels: {
    EmojiCategory.favorites: 'Favourites',
    EmojiCategory.recent: 'Recent',
    EmojiCategory.smileys: 'Smileys',
    EmojiCategory.people: 'People',
    EmojiCategory.animals: 'Animals',
    EmojiCategory.flags: 'Flags',
  },
);

const _wave = EmojiChoice(
  glyph: '👋',
  name: 'Waving hand',
  keywords: ['wave'],
  category: EmojiCategory.people,
);
const _cat = EmojiChoice(
  glyph: '🐱',
  name: 'Cat face',
  keywords: ['cat'],
  category: EmojiCategory.animals,
);
final _faces = List.generate(
  28,
  (index) => EmojiChoice(
    glyph: String.fromCharCode(0x1f600 + index),
    name: 'Face $index',
    keywords: const [],
    category: EmojiCategory.smileys,
  ),
);
final _account = AccountId.parse('account-a');

Finder _key(String value) => find.byKey(Key(value));
Finder _choice(String name) => _key('emoji-choice-$name');
Finder _recent(String name) => _key('emoji-recent-choice-$name');
Finder _favorite(String name) => _key('emoji-favorite-choice-$name');

Future<void> _show(
  WidgetTester tester,
  _UsageStore store,
  EmojiCatalog catalog, {
  double width = 390,
  AccountId? account,
  EmojiGlyphSupport? glyphSupport,
  ValueChanged<EmojiChoice>? selected,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: width,
          height: 220,
          child: EmojiPicker(
            composer: true,
            accountId: account ?? _account,
            usageStore: store,
            catalog: catalog,
            glyphSupport: glyphSupport,
            labels: _labels,
            onClose: () {},
            onSelected: selected ?? (_) {},
          ),
        ),
      ),
    ),
  ),
);

Future<void> _pressEnter(WidgetTester tester, Finder cell, String text) async {
  final label = find.descendant(of: cell, matching: find.text(text));
  Focus.of(tester.element(label)).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'cold opening shows the catalog before preferences or glyph probe',
    (tester) async {
      final store = _UsageStore();
      final usage = store.pauseRead = Completer<EmojiUsage>();
      final glyphs = Completer<List<bool>?>();
      final inserted = <String>[];
      await _show(
        tester,
        store,
        EmojiCatalog([_wave, _cat]),
        glyphSupport: EmojiGlyphSupport(probe: (_) => glyphs.future),
        selected: (choice) => inserted.add(choice.glyph),
      );
      final center = tester.getCenter(_choice('waving-hand'));
      final pointing = await tester.startGesture(center);

      usage.complete(EmojiUsage(recent: [_cat.glyph], favorites: const []));
      glyphs.complete(null);
      await tester.pump();
      expect(tester.getCenter(_choice('waving-hand')), center);
      expect(_key('emoji-recent-section'), findsNothing);
      await pointing.up();
      await tester.pumpAndSettle();
      expect(inserted, [_wave.glyph]);
    },
  );

  testWidgets('28 recents at 390px use one row and keep rapid taps stable', (
    tester,
  ) async {
    final store = _UsageStore();
    store.rows[_account] = EmojiUsage(
      recent: [_faces.first.glyph, ..._faces.map((choice) => choice.glyph)],
      favorites: const [],
    );
    final catalog = EmojiCatalog([..._faces, _wave]);
    final inserted = <String>[];
    await _show(
      tester,
      store,
      catalog,
      selected: (choice) => inserted.add(choice.glyph),
    );
    await tester.pumpAndSettle();

    final first = tester.getCenter(_recent('face-0'));
    final second = tester.getCenter(_recent('face-1'));
    expect(first.dy, second.dy);
    expect(_recent('face-0'), findsOneWidget);
    expect(_choice('face-0').hitTestable(), findsOneWidget);
    expect(_recent('face-27').hitTestable(), findsNothing);

    await tester.tapAt(second);
    await tester.pumpAndSettle();
    await tester.tapAt(second);
    await tester.pumpAndSettle();
    expect(inserted, [_faces[1].glyph, _faces[1].glyph]);
    expect(tester.getCenter(_recent('face-1')), second);

    await tester.drag(
      _key('emoji-recent-scroll'),
      const Offset(-1300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(_recent('face-27').hitTestable(), findsOneWidget);

    await tester.drag(
      _key('emoji-recent-scroll'),
      const Offset(1300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final firstLabel = find.descendant(
      of: _recent('face-0'),
      matching: find.text(_faces.first.glyph),
    );
    Focus.of(tester.element(firstLabel)).requestFocus();
    await tester.pump();
    for (var index = 1; index < _faces.length; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(_recent('face-27').hitTestable(), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _show(tester, store, catalog);
    await tester.pumpAndSettle();
    expect(tester.getCenter(_recent('face-1')), first);
  });

  testWidgets(
    'categories share a scroll and the menu jumps to the last category',
    (tester) async {
      final store = _UsageStore();
      final catalog = EmojiCatalog.standard();
      final flag = catalog.inCategory(EmojiCategory.flags).first;
      final menu = _key('emoji-categories');
      await _show(tester, store, catalog, width: 640);
      await tester.pumpAndSettle();
      expect(find.text('Emoji categories'), findsOneWidget);
      expect(_key('emoji-recent-section'), findsNothing);
      expect(_choice(flag.keyName).hitTestable(), findsNothing);

      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(_key('emoji-category-flags'));
      await tester.pumpAndSettle();
      expect(_choice(flag.keyName).hitTestable(), findsOneWidget);

      await tester.enterText(_key('emoji-search'), 'waving hand');
      await tester.pumpAndSettle();
      expect(_choice('waving-hand').hitTestable(), findsOneWidget);
      expect(_choice(flag.keyName), findsNothing);
      await tester.tap(_key('emoji-clear-search'));
      await tester.pumpAndSettle();
      expect(
        _choice(catalog.choices.first.keyName).hitTestable(),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'long press and right click save, while keyboard can manage favourites',
    (tester) async {
      final store = _UsageStore();
      final inserted = <String>[];
      await _show(
        tester,
        store,
        EmojiCatalog([_wave, _cat]),
        selected: (choice) => inserted.add(choice.glyph),
      );
      await tester.pumpAndSettle();
      final wave = _choice('waving-hand');

      await tester.longPress(wave);
      await tester.pumpAndSettle();
      expect(store.rows[_account]?.favorites, [_wave.glyph]);
      await tester.tap(
        wave,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(store.rows[_account]?.favorites, isEmpty);

      await tester.tap(_key('emoji-favorites'));
      await tester.pumpAndSettle();
      expect(find.text(_labels.noFavorites), findsOneWidget);
      await _pressEnter(
        tester,
        _key('emoji-manage-favorites'),
        _labels.manageFavorites,
      );
      expect(_key('emoji-favorite-mode-hint'), findsOneWidget);
      await _pressEnter(tester, wave, _wave.glyph);
      await _pressEnter(tester, _key('emoji-favorites-done'), 'Done');
      expect(_favorite('waving-hand').hitTestable(), findsOneWidget);
      expect(inserted, isEmpty);
      expect(store.rows[_account]?.favorites, [_wave.glyph]);
    },
  );

  testWidgets(
    'legacy favourites are reachable and failed writes keep the list',
    (tester) async {
      final store = _UsageStore();
      const oldGlyph = '🧪';
      store.rows[_account] = EmojiUsage(
        recent: const [],
        favorites: [..._faces.map((choice) => choice.glyph), oldGlyph],
      );
      final selected = <String>[];
      await _show(
        tester,
        store,
        EmojiCatalog(_faces),
        selected: (choice) => selected.add(choice.glyph),
      );
      await tester.pumpAndSettle();
      await tester.tap(_key('emoji-favorites'));
      await tester.pumpAndSettle();

      final old = _favorite('stored-1f9ea');
      final scroll = find.descendant(
        of: _key('composer-emoji-scroll'),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(old, 96, scrollable: scroll);
      store.failNextFavorite = true;
      await tester.longPress(old);
      await tester.pumpAndSettle();
      expect(find.text('Could not save favourites'), findsOneWidget);
      expect(store.rows[_account]?.favorites, contains(oldGlyph));
      await tester.tap(old);
      expect(selected, [oldGlyph]);
    },
  );

  testWidgets('the favourites filter preserves the query and stored order', (
    tester,
  ) async {
    const heart = EmojiChoice(
      glyph: '❤️',
      name: 'Red heart',
      keywords: ['love'],
      category: EmojiCategory.symbols,
    );
    const smiling = EmojiChoice(
      glyph: '😺',
      name: 'Smiling cat',
      keywords: ['love'],
      category: EmojiCategory.animals,
    );
    final store = _UsageStore();
    store.rows[_account] = EmojiUsage(
      recent: const [],
      favorites: [heart.glyph.replaceAll('\uFE0F', ''), smiling.glyph],
    );
    await _show(tester, store, EmojiCatalog([smiling, _wave, heart]));
    await tester.pumpAndSettle();

    final search = _key('emoji-search');
    final star = _key('emoji-favorites');
    await tester.enterText(search, 'love');
    await tester.pumpAndSettle();
    expect(_choice('red-heart'), findsOneWidget);
    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller?.text, 'love');
    expect(
      tester.widget<TextField>(search).decoration?.hintText,
      'Search favourites',
    );
    expect(_choice('red-heart'), findsNothing);
    final original = _favorite('stored-2764');
    expect(original, findsOneWidget);
    expect(
      find.descendant(of: original, matching: find.text('❤')),
      findsOneWidget,
    );
    expect(
      tester.getCenter(original).dx,
      lessThan(tester.getCenter(_favorite('smiling-cat')).dx),
    );

    await tester.enterText(search, 'wave');
    await tester.pumpAndSettle();
    expect(find.text(_labels.noResults), findsOneWidget);
    expect(
      tester.widget<TextField>(search).decoration?.hintText,
      'Search favourites',
    );
    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller?.text, 'wave');
    expect(_choice('waving-hand'), findsOneWidget);
  });

  testWidgets('Czech names work with or without accents in both views', (
    tester,
  ) async {
    final standard = EmojiCatalog.standard();
    final turtle = standard.byGlyph('🐢')!;
    final giraffe = standard.byGlyph('🦒')!;
    final store = _UsageStore()
      ..rows[_account] = EmojiUsage(
        recent: const [],
        favorites: [turtle.glyph, giraffe.glyph],
      );
    await _show(tester, store, EmojiCatalog([turtle, giraffe, _cat]));
    await tester.pumpAndSettle();

    for (final (query, emoji) in [
      ('želva', turtle),
      ('zelva', turtle),
      ('z\u030Celva', turtle),
      ('žirafa', giraffe),
      ('zirafa', giraffe),
    ]) {
      await tester.enterText(_key('emoji-search'), query);
      await tester.pumpAndSettle();
      expect(_choice(emoji.keyName), findsOneWidget, reason: query);
      await tester.tap(_key('emoji-favorites'));
      await tester.pumpAndSettle();
      expect(_favorite(emoji.keyName), findsOneWidget, reason: query);
      await tester.tap(_key('emoji-favorites'));
      await tester.pumpAndSettle();
    }
  });
}

final class _UsageStore implements EmojiUsageStore {
  final rows = <AccountId, EmojiUsage>{};
  Completer<EmojiUsage>? pauseRead;
  bool failNextFavorite = false;

  EmojiUsage _current(AccountId account) => rows[account] ?? EmojiUsage.empty;

  @override
  Future<EmojiUsage> read(AccountId account) =>
      pauseRead?.future ?? Future.value(_current(account));

  @override
  Future<EmojiUsage> recordSelection(AccountId account, String emoji) async {
    final current = _current(account);
    return rows[account] = EmojiUsage(
      recent: [emoji, ...current.recent.where((glyph) => glyph != emoji)],
      favorites: current.favorites,
    );
  }

  @override
  Future<EmojiUsage> toggleFavorite(AccountId account, String emoji) async {
    if (failNextFavorite) {
      failNextFavorite = false;
      throw StateError('Preference write failed');
    }
    final current = _current(account);
    final favorites = current.favorites.toSet();
    if (!favorites.remove(emoji)) favorites.add(emoji);
    return rows[account] = EmojiUsage(
      recent: current.recent,
      favorites: favorites,
    );
  }

  @override
  Future<void> delete(AccountId account) async {
    rows.remove(account);
  }
}
