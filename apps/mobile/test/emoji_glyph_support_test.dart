import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_picker.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:nextcloudtalk/platform/emoji_glyph_support.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  group('EmojiGlyphSupport', () {
    test('reports the glyphs the probe rejects and asks only once', () async {
      var calls = 0;
      final support = EmojiGlyphSupport(
        probe: (glyphs) async {
          calls++;
          return <bool>[for (final glyph in glyphs) glyph != 'B'];
        },
      );

      expect(await support.unsupported(<String>['A', 'B']), <String>{'B'});
      expect(await support.unsupported(<String>['A', 'B']), <String>{'B'});
      expect(calls, 1);
    });

    test(
      'hides nothing without an answer, on an error or a short answer',
      () async {
        for (final probe in <EmojiGlyphProbe>[
          (_) async => null,
          (_) async => throw PlatformException(code: 'boom'),
          (_) async => <bool>[false],
        ]) {
          final support = EmojiGlyphSupport(probe: probe);
          expect(await support.unsupported(<String>['A', 'B']), isEmpty);
        }
      },
    );

    test('a skin-tone variant follows a missing base', () {
      const unsupported = <String>{'👋'};

      expect(EmojiGlyphSupport.isDrawable('👋🏽', unsupported), isFalse);
      expect(EmojiGlyphSupport.isDrawable('👍🏽', unsupported), isTrue);
      expect(
        EmojiGlyphSupport.isDrawable('👍🏽', const <String>{'👍🏽'}),
        isFalse,
      );
    });
  });

  group('EmojiPicker glyph filter', () {
    final catalog = EmojiCatalog(const <EmojiChoice>[
      EmojiChoice(
        glyph: '😀',
        name: 'Grinning face',
        keywords: <String>['smile'],
        category: EmojiCategory.smileys,
      ),
      EmojiChoice(
        glyph: '🙂',
        name: 'Slightly smiling face',
        keywords: <String>['smile'],
        category: EmojiCategory.smileys,
      ),
    ]);

    Future<void> openPicker(
      WidgetTester tester,
      EmojiGlyphSupport support, {
      EmojiUsage usage = EmojiUsage.empty,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmojiPicker(
              accountId: AccountId.parse('account-a'),
              usageStore: _FixedUsageStore(usage),
              labels: _labels,
              catalog: catalog,
              glyphSupport: support,
              onClose: () {},
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    EmojiGlyphSupport rejecting(String glyph) => EmojiGlyphSupport(
      probe: (glyphs) async => <bool>[for (final g in glyphs) g != glyph],
    );

    testWidgets('hides a glyph the font cannot draw', (tester) async {
      await openPicker(tester, rejecting('😀'));

      expect(find.text('😀'), findsNothing);
      expect(find.text('🙂'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('emoji-search')), 'smile');
      await tester.pumpAndSettle();
      expect(find.text('😀'), findsNothing);
      expect(find.text('🙂'), findsOneWidget);
    });

    testWidgets('hides a recent glyph the font cannot draw', (tester) async {
      await openPicker(
        tester,
        rejecting('😀'),
        usage: EmojiUsage(recent: <String>['😀', '🙂'], favorites: <String>[]),
      );

      expect(find.text('😀'), findsNothing);
      expect(find.text('🙂'), findsOneWidget);
    });

    testWidgets('shows everything when the platform has no answer', (
      tester,
    ) async {
      await openPicker(tester, EmojiGlyphSupport(probe: (_) async => null));

      expect(find.text('😀'), findsOneWidget);
      expect(find.text('🙂'), findsOneWidget);
    });
  });
}

const _labels = EmojiPickerLabels(
  title: 'Emoji',
  closeTooltip: 'Close',
  manageFavorites: 'Manage favorites',
  finishManagingFavorites: 'Finish',
  favoriteModeHint: 'Hint',
  addFavoriteLabel: 'Add',
  removeFavoriteLabel: 'Remove',
  searchHint: 'Search emoji',
  noResults: 'No emoji found',
  noRecents: 'No recent',
  noFavorites: 'No favorites',
  categoryLabels: <EmojiCategory, String>{
    EmojiCategory.favorites: 'Favorites',
    EmojiCategory.recent: 'Recent',
    EmojiCategory.smileys: 'Smileys',
  },
);

final class _FixedUsageStore implements EmojiUsageStore {
  _FixedUsageStore(this._usage);

  final EmojiUsage _usage;

  @override
  Future<void> delete(AccountId accountId) async {}

  @override
  Future<EmojiUsage> read(AccountId accountId) async => _usage;

  @override
  Future<EmojiUsage> recordSelection(AccountId accountId, String glyph) async =>
      _usage;

  @override
  Future<EmojiUsage> toggleFavorite(AccountId accountId, String glyph) async =>
      _usage;
}
