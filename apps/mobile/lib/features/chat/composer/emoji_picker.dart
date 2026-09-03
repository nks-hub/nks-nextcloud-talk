import 'dart:async';

import 'package:emojis/emoji.dart' as unicode;
import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'emoji_usage_store.dart';

part 'emoji_czech_names.g.dart';

enum EmojiCategory {
  favorites,
  recent,
  smileys,
  people,
  animals,
  food,
  activities,
  travel,
  objects,
  symbols,
  flags,
}

final class EmojiChoice {
  const EmojiChoice({
    required this.glyph,
    required this.name,
    required this.keywords,
    required this.category,
    this.stableKey,
  });

  final String glyph;
  final String name;
  final List<String> keywords;
  final EmojiCategory category;
  final String? stableKey;

  /// Stable widget-key slug derived from the English name, never localized.
  String get keyName => (stableKey ?? name)
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');

  /// Display name for [locale], falling back to the English one.
  String nameFor(Locale? locale) =>
      locale?.languageCode == 'cs' ? _sentenceCase(_czech?.name ?? name) : name;

  /// Every name and keyword in every supported language, so search keeps
  /// working no matter which language the user types in.
  List<String> get searchTerms {
    final czech = _czech;
    return <String>[
      name,
      ...keywords,
      if (czech != null) ...<String>[czech.name, ...czech.keywords],
    ];
  }

  /// The hand-written table wins, the CLDR table covers the rest. CLDR keys
  /// some glyphs without the variation selector this catalog carries, so the
  /// bare sequence is tried second.
  EmojiTranslation? get _czech =>
      _czechEmoji[glyph] ??
      _cldrCzechEmoji[glyph] ??
      _cldrCzechEmoji[glyph.replaceAll('️', '')];
}

/// Localized name and keywords for a single glyph.
final class EmojiTranslation {
  const EmojiTranslation({required this.name, required this.keywords});

  final String name;
  final List<String> keywords;
}

final class EmojiCatalog {
  EmojiCatalog(Iterable<EmojiChoice> choices)
    : choices = List<EmojiChoice>.unmodifiable(choices) {
    _byGlyph = <String, EmojiChoice>{
      for (final choice in this.choices) choice.glyph: choice,
    };
    _searchIndex = <EmojiChoice, String>{
      for (final choice in this.choices)
        choice: choice.searchTerms.join('\n').toLowerCase(),
    };
  }

  factory EmojiCatalog.standard() => _standardCatalog;

  final List<EmojiChoice> choices;
  late final Map<String, EmojiChoice> _byGlyph;
  late final Map<EmojiChoice, String> _searchIndex;

  List<EmojiCategory> get categories => List<EmojiCategory>.unmodifiable({
    for (final choice in choices) choice.category,
  });

  List<EmojiChoice> inCategory(EmojiCategory category) =>
      List.unmodifiable(choices.where((choice) => choice.category == category));

  EmojiChoice? byGlyph(String glyph) => _byGlyph[glyph];

  List<EmojiChoice> resolveGlyphs(Iterable<String> glyphs) =>
      List<EmojiChoice>.unmodifiable(
        glyphs.map(byGlyph).whereType<EmojiChoice>(),
      );

  List<EmojiChoice> search(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return List<EmojiChoice>.unmodifiable(choices);
    }
    return List<EmojiChoice>.unmodifiable(
      choices.where(
        (choice) =>
            choice.glyph == normalized ||
            (_searchIndex[choice]?.contains(normalized) ?? false),
      ),
    );
  }
}

final class EmojiPickerLabels {
  const EmojiPickerLabels({
    required this.title,
    required this.closeTooltip,
    required this.manageFavorites,
    required this.finishManagingFavorites,
    required this.favoriteModeHint,
    required this.addFavoriteLabel,
    required this.removeFavoriteLabel,
    required this.searchHint,
    required this.noResults,
    required this.noRecents,
    required this.noFavorites,
    required this.categoryLabels,
  });

  final String title;
  final String closeTooltip;
  final String manageFavorites;
  final String finishManagingFavorites;
  final String favoriteModeHint;
  final String addFavoriteLabel;
  final String removeFavoriteLabel;
  final String searchHint;
  final String noResults;
  final String noRecents;
  final String noFavorites;
  final Map<EmojiCategory, String> categoryLabels;
}

final class EmojiPicker extends StatefulWidget {
  const EmojiPicker({
    required this.accountId,
    required this.usageStore,
    required this.labels,
    required this.onClose,
    required this.onSelected,
    this.catalog,
    super.key,
  });

  final AccountId accountId;
  final EmojiUsageStore usageStore;
  final EmojiPickerLabels labels;
  final VoidCallback onClose;
  final ValueChanged<EmojiChoice> onSelected;
  final EmojiCatalog? catalog;

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

final class _EmojiPickerState extends State<EmojiPicker> {
  late final TextEditingController _searchController;
  EmojiCategory? _category;
  EmojiUsage _usage = EmojiUsage.empty;
  bool _usageLoaded = false;
  bool _managingFavorites = false;
  bool _updatingUsage = false;
  bool _categoryExplicitlySelected = false;
  int _loadGeneration = 0;

  EmojiCatalog get _catalog => widget.catalog ?? EmojiCatalog.standard();

  List<EmojiCategory> get _categories => <EmojiCategory>[
    EmojiCategory.favorites,
    EmojiCategory.recent,
    ..._catalog.categories,
  ];

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()..addListener(_onSearchChanged);
    _category = _catalog.categories.firstOrNull;
    unawaited(_loadUsage());
  }

  @override
  void didUpdateWidget(covariant EmojiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId ||
        oldWidget.usageStore != widget.usageStore) {
      _usage = EmojiUsage.empty;
      _usageLoaded = false;
      _category = _catalog.categories.firstOrNull;
      _categoryExplicitlySelected = false;
      unawaited(_loadUsage());
    } else if (oldWidget.catalog != widget.catalog &&
        !_categories.contains(_category)) {
      _category = _firstCategory(_usage);
    }
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() => setState(() {});

  Future<void> _loadUsage() async {
    final generation = ++_loadGeneration;
    final usage = await widget.usageStore.read(widget.accountId);
    if (!mounted || generation != _loadGeneration) {
      return;
    }
    setState(() {
      _usage = usage;
      _usageLoaded = true;
      if (!_categoryExplicitlySelected && usage.recent.isNotEmpty) {
        _category = EmojiCategory.recent;
      } else {
        _category ??= _firstCategory(usage);
      }
    });
  }

  EmojiCategory? _firstCategory(EmojiUsage usage) => usage.recent.isNotEmpty
      ? EmojiCategory.recent
      : _catalog.categories.firstOrNull;

  List<EmojiChoice> _visibleChoices(String query) {
    if (query.isNotEmpty) {
      return _catalog.search(query);
    }
    return switch (_category) {
      EmojiCategory.favorites => _catalog.resolveGlyphs(_usage.favorites),
      EmojiCategory.recent => _catalog.resolveGlyphs(_usage.recent),
      final EmojiCategory category => _catalog.inCategory(category),
      null => _catalog.choices,
    };
  }

  String _emptyLabel(String query) {
    if (query.isNotEmpty) {
      return widget.labels.noResults;
    }
    return switch (_category) {
      EmojiCategory.favorites => widget.labels.noFavorites,
      EmojiCategory.recent => widget.labels.noRecents,
      _ => widget.labels.noResults,
    };
  }

  Future<void> _activate(EmojiChoice choice) async {
    if (_updatingUsage) {
      return;
    }
    if (_managingFavorites) {
      setState(() => _updatingUsage = true);
      try {
        final usage = await widget.usageStore.toggleFavorite(
          widget.accountId,
          choice.glyph,
        );
        if (mounted) {
          setState(() => _usage = usage);
        }
      } on Object {
        // A preference write must never break the picker.
      } finally {
        if (mounted) {
          setState(() => _updatingUsage = false);
        }
      }
      return;
    }

    widget.onSelected(choice);
    try {
      final usage = await widget.usageStore.recordSelection(
        widget.accountId,
        choice.glyph,
      );
      if (mounted) {
        setState(() => _usage = usage);
      }
    } on Object {
      // A preference write must never block composing or reacting.
    }
  }

  void _toggleFavoriteManagement() {
    setState(() => _managingFavorites = !_managingFavorites);
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.maybeLocaleOf(context);
    final query = _searchController.text.trim();
    final choices = _visibleChoices(query);
    return Column(
      children: [
        SizedBox(
          height: 56,
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 16),
                  child: Text(
                    widget.labels.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              IconButton(
                key: const Key('emoji-manage-favorites'),
                tooltip: _managingFavorites
                    ? widget.labels.finishManagingFavorites
                    : widget.labels.manageFavorites,
                onPressed: _usageLoaded && !_updatingUsage
                    ? _toggleFavoriteManagement
                    : null,
                icon: Icon(
                  _managingFavorites ? Icons.done_rounded : Icons.star_outline,
                ),
              ),
              IconButton(
                key: const Key('emoji-close'),
                tooltip: widget.labels.closeTooltip,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_managingFavorites)
          Container(
            key: const Key('emoji-favorite-mode-hint'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Row(
              children: [
                const Icon(Icons.star_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(widget.labels.favoriteModeHint)),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            key: const Key('emoji-search'),
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: widget.labels.searchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (query.isEmpty)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                for (final category in _categories)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ChoiceChip(
                      key: Key('emoji-category-${category.name}'),
                      label: Text(widget.labels.categoryLabels[category] ?? ''),
                      selected: category == _category,
                      onSelected: (_) => setState(() {
                        _category = category;
                        _categoryExplicitlySelected = true;
                      }),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child:
              !_usageLoaded &&
                  (_category == EmojiCategory.recent ||
                      _category == EmojiCategory.favorites)
              ? const Center(child: CircularProgressIndicator())
              : choices.isEmpty
              ? Center(child: Text(_emptyLabel(query)))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 56,
                    mainAxisExtent: 48,
                  ),
                  itemCount: choices.length,
                  itemBuilder: (context, index) {
                    final choice = choices[index];
                    final favorite = _usage.favorites.contains(choice.glyph);
                    final semanticsLabel = _managingFavorites
                        ? '${choice.nameFor(locale)}. ${favorite ? widget.labels.removeFavoriteLabel : widget.labels.addFavoriteLabel}'
                        : choice.nameFor(locale);
                    return Center(
                      child: Semantics(
                        key: Key('emoji-choice-${choice.keyName}'),
                        container: true,
                        button: true,
                        label: semanticsLabel,
                        selected: _managingFavorites && favorite,
                        onTap: () => unawaited(_activate(choice)),
                        child: SizedBox.square(
                          dimension: 48,
                          child: InkWell(
                            excludeFromSemantics: true,
                            borderRadius: BorderRadius.circular(24),
                            onTap: _updatingUsage
                                ? null
                                : () => unawaited(_activate(choice)),
                            child: Stack(
                              children: [
                                Center(
                                  child: ExcludeSemantics(
                                    child: Text(
                                      choice.glyph,
                                      style: const TextStyle(fontSize: 26),
                                    ),
                                  ),
                                ),
                                if (favorite)
                                  PositionedDirectional(
                                    top: 1,
                                    end: 1,
                                    child: Icon(
                                      Icons.star_rounded,
                                      key: Key(
                                        'emoji-favorite-${choice.keyName}',
                                      ),
                                      size: 13,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

final EmojiCatalog _standardCatalog = EmojiCatalog(
  unicode.Emoji.all().map(_choiceFromUnicode),
);

EmojiChoice _choiceFromUnicode(unicode.Emoji emoji) => EmojiChoice(
  glyph: emoji.char,
  name: _sentenceCase(emoji.name),
  keywords: <String>[
    emoji.shortName,
    ...emoji.keywords,
    ...?_legacyEnglishAliases[emoji.char],
  ],
  category: _categoryFromUnicode(emoji.emojiGroup),
);

EmojiCategory _categoryFromUnicode(unicode.EmojiGroup category) =>
    switch (category) {
      unicode.EmojiGroup.smileysEmotion => EmojiCategory.smileys,
      unicode.EmojiGroup.peopleBody ||
      unicode.EmojiGroup.component => EmojiCategory.people,
      unicode.EmojiGroup.animalsNature => EmojiCategory.animals,
      unicode.EmojiGroup.foodDrink => EmojiCategory.food,
      unicode.EmojiGroup.activities => EmojiCategory.activities,
      unicode.EmojiGroup.travelPlaces => EmojiCategory.travel,
      unicode.EmojiGroup.objects => EmojiCategory.objects,
      unicode.EmojiGroup.symbols => EmojiCategory.symbols,
      unicode.EmojiGroup.flags => EmojiCategory.flags,
    };

String _sentenceCase(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

// Preserve aliases that the original compact catalog exposed but the Unicode
// data source does not include.
const Map<String, List<String>> _legacyEnglishAliases = <String, List<String>>{
  '❤️': <String>['love'],
};

// Emoji names stay in Dart instead of the ARB files: they are a fixed data
// table rather than UI copy, and search has to match every language at once
// regardless of the active locale, which per-locale ARB lookups cannot do.
const Map<String, EmojiTranslation> _czechEmoji = <String, EmojiTranslation>{
  '😀': EmojiTranslation(
    name: 'Usmívající se obličej',
    keywords: <String>['úsměv', 'radost', 'smích'],
  ),
  '😂': EmojiTranslation(
    name: 'Obličej se slzami radosti',
    keywords: <String>['smích', 'sranda', 'vtipné'],
  ),
  '🥰': EmojiTranslation(
    name: 'Usmívající se obličej se srdíčky',
    keywords: <String>['láska', 'zamilovaný'],
  ),
  '🤔': EmojiTranslation(
    name: 'Přemýšlející obličej',
    keywords: <String>['přemýšlení', 'otázka'],
  ),
  '😢': EmojiTranslation(
    name: 'Plačící obličej',
    keywords: <String>['smutek', 'pláč', 'slza'],
  ),
  '👋': EmojiTranslation(
    name: 'Mávající ruka',
    keywords: <String>['mávání', 'ahoj', 'nashledanou'],
  ),
  '👍': EmojiTranslation(
    name: 'Palec nahoru',
    keywords: <String>['ano', 'souhlas', 'líbí'],
  ),
  '👎': EmojiTranslation(
    name: 'Palec dolů',
    keywords: <String>['ne', 'nesouhlas'],
  ),
  '🙏': EmojiTranslation(
    name: 'Sepjaté ruce',
    keywords: <String>['prosím', 'děkuji', 'díky'],
  ),
  '💪': EmojiTranslation(
    name: 'Napnutý biceps',
    keywords: <String>['síla', 'svaly'],
  ),
  '🐱': EmojiTranslation(
    name: 'Kočka',
    keywords: <String>['kočka', 'mazlíček', 'zvíře'],
  ),
  '🐶': EmojiTranslation(
    name: 'Pes',
    keywords: <String>['pes', 'mazlíček', 'zvíře'],
  ),
  '🦊': EmojiTranslation(name: 'Liška', keywords: <String>['liška', 'zvíře']),
  '🐼': EmojiTranslation(name: 'Panda', keywords: <String>['panda', 'zvíře']),
  '🍎': EmojiTranslation(
    name: 'Červené jablko',
    keywords: <String>['jablko', 'ovoce'],
  ),
  '🍕': EmojiTranslation(name: 'Pizza', keywords: <String>['pizza', 'jídlo']),
  '☕': EmojiTranslation(
    name: 'Horký nápoj',
    keywords: <String>['káva', 'čaj', 'nápoj'],
  ),
  '🎂': EmojiTranslation(
    name: 'Narozeninový dort',
    keywords: <String>['dort', 'narozeniny'],
  ),
  '⚽': EmojiTranslation(
    name: 'Fotbalový míč',
    keywords: <String>['fotbal', 'sport', 'míč'],
  ),
  '🎮': EmojiTranslation(
    name: 'Videohra',
    keywords: <String>['hra', 'ovladač'],
  ),
  '🎨': EmojiTranslation(
    name: 'Malířská paleta',
    keywords: <String>['umění', 'malování'],
  ),
  '🚗': EmojiTranslation(name: 'Auto', keywords: <String>['auto', 'cesta']),
  '✈️': EmojiTranslation(
    name: 'Letadlo',
    keywords: <String>['letadlo', 'let', 'cestování'],
  ),
  '🌍': EmojiTranslation(name: 'Zeměkoule', keywords: <String>['země', 'svět']),
  '💡': EmojiTranslation(
    name: 'Žárovka',
    keywords: <String>['nápad', 'světlo'],
  ),
  '📱': EmojiTranslation(
    name: 'Mobilní telefon',
    keywords: <String>['telefon', 'mobil'],
  ),
  '🔑': EmojiTranslation(
    name: 'Klíč',
    keywords: <String>['klíč', 'zabezpečení'],
  ),
  '❤️': EmojiTranslation(
    name: 'Červené srdce',
    keywords: <String>['srdce', 'láska'],
  ),
  '✅': EmojiTranslation(
    name: 'Zaškrtnutí',
    keywords: <String>['zaškrtnout', 'hotovo', 'ano'],
  ),
  '❌': EmojiTranslation(
    name: 'Křížek',
    keywords: <String>['křížek', 'ne', 'chyba'],
  ),
  '⚠️': EmojiTranslation(
    name: 'Varování',
    keywords: <String>['varování', 'pozor'],
  ),
};
