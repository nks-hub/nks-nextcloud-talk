part of 'emoji_picker.dart';

final class _ComposerEmojiBrowser extends StatefulWidget {
  const _ComposerEmojiBrowser({
    required this.catalog,
    required this.labels,
    required this.usage,
    required this.usageLoaded,
    required this.updatingFavorites,
    required this.unsupported,
    required this.onSelected,
    required this.onToggleFavorite,
    super.key,
  });

  final EmojiCatalog catalog;
  final EmojiPickerLabels labels;
  final EmojiUsage usage;
  final bool usageLoaded;
  final bool updatingFavorites;
  final Set<String>? unsupported;
  final ValueChanged<EmojiChoice> onSelected;
  final ValueChanged<EmojiChoice> onToggleFavorite;

  @override
  State<_ComposerEmojiBrowser> createState() => _ComposerEmojiBrowserState();
}

final class _ComposerEmojiBrowserState extends State<_ComposerEmojiBrowser> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _recentScrollController = ScrollController();
  final _categoryHeaders = <EmojiCategory, GlobalKey>{};
  List<String>? _recentGlyphs;
  bool _showFavorites = false;
  bool _managing = false;

  String get _query => _searchController.text.trim();

  String get _favoritesTitle =>
      widget.labels.categoryLabels[EmojiCategory.favorites] ??
      widget.labels.manageFavorites;

  bool get _canToggleFavorite =>
      widget.usageLoaded && !widget.updatingFavorites;

  @override
  void initState() {
    super.initState();
    _captureRecents();
  }

  @override
  void didUpdateWidget(covariant _ComposerEmojiBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    _captureRecents();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _recentScrollController.dispose();
    super.dispose();
  }

  void _captureRecents() {
    if (widget.usageLoaded) {
      _recentGlyphs ??= List.of(widget.usage.recent.toSet());
    }
  }

  // A late preference read must not move a cell the user is already pressing.
  void _freezeRecents() => _recentGlyphs ??= const [];

  void _rewind() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  void _searchChanged() {
    setState(() {});
    _rewind();
  }

  void _clearSearch() {
    _searchController.clear();
    _searchChanged();
  }

  void _toggleFavoritesView() {
    setState(() => _showFavorites = !_showFavorites);
    _rewind();
  }

  void _setManaging(bool enabled) {
    setState(() {
      _managing = enabled;
      _showFavorites = !enabled;
    });
    _rewind();
  }

  void _jumpToCategory(EmojiCategory category) {
    _searchController.clear();
    setState(() => _showFavorites = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _categoryHeaders[category]?.currentContext;
      if (mounted && target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 180),
          ),
        );
      }
    });
  }

  bool _isDrawable(String glyph) => EmojiGlyphSupport.isDrawable(
    glyph,
    widget.unsupported ?? const <String>{},
  );

  List<EmojiChoice> _storedChoices(
    Iterable<String> glyphs,
    EmojiCategory category,
  ) => [
    for (final glyph in glyphs.toSet())
      if (_isDrawable(glyph)) _storedChoice(glyph, category),
  ];

  EmojiChoice _storedChoice(String glyph, EmojiCategory category) {
    final choice = widget.catalog.byGlyph(glyph);
    if (choice != null) return choice;
    const presentation = '\uFE0F';
    final alternate = glyph.contains(presentation)
        ? glyph.replaceAll(presentation, '')
        : '$glyph$presentation';
    final metadata = widget.catalog.byGlyph(alternate);
    return EmojiChoice(
      glyph: glyph,
      name: metadata?.name ?? glyph,
      keywords: metadata?.keywords ?? const [],
      category: category,
      stableKey:
          'stored-${glyph.runes.map((rune) => rune.toRadixString(16)).join('-')}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = <EmojiCategory, List<EmojiChoice>>{};
    for (final choice in widget.catalog.choices) {
      if (_isDrawable(choice.glyph)) {
        (categories[choice.category] ??= []).add(choice);
      }
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final cell = bounds.maxWidth >= 600 ? 56.0 : 48.0;
        final showLabels = MediaQuery.textScalerOf(context).scale(1) <= 1.3;
        return Column(
          children: [
            _toolbar(
              context,
              categories.keys,
              showFavoriteText: showLabels && bounds.maxWidth >= 380,
              showCategoryText: showLabels && bounds.maxWidth >= 540,
            ),
            Expanded(
              child: Listener(
                onPointerDown: (_) => _freezeRecents(),
                child: CustomScrollView(
                  key: const Key('composer-emoji-scroll'),
                  controller: _scrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: _sections(context, categories, cell),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _toolbar(
    BuildContext context,
    Iterable<EmojiCategory> categories, {
    required bool showFavoriteText,
    required bool showCategoryText,
  }) {
    final materialLabels = MaterialLocalizations.of(context);
    final categoryLabel =
        widget.labels.composerCategories ?? materialLabels.showMenuTooltip;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('emoji-search'),
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: (_) => _searchChanged(),
              decoration: InputDecoration(
                hintText: _showFavorites
                    ? widget.labels.composerSearchFavorites ??
                          widget.labels.searchHint
                    : widget.labels.searchHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        key: const Key('emoji-clear-search'),
                        tooltip: materialLabels.deleteButtonTooltip,
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (_managing)
            TextButton(
              key: const Key('emoji-favorites-done'),
              onPressed: () => _setManaging(false),
              child: Text(
                widget.labels.composerDone ?? materialLabels.okButtonLabel,
              ),
            )
          else if (showFavoriteText)
            Tooltip(
              message: _favoritesTitle,
              child: Semantics(
                selected: _showFavorites,
                child: TextButton.icon(
                  key: const Key('emoji-favorites'),
                  onPressed: _toggleFavoritesView,
                  icon: Icon(
                    _showFavorites
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                  ),
                  label: Text(_favoritesTitle),
                ),
              ),
            )
          else
            IconButton(
              key: const Key('emoji-favorites'),
              tooltip: _favoritesTitle,
              isSelected: _showFavorites,
              onPressed: _toggleFavoritesView,
              icon: const Icon(Icons.star_outline_rounded),
              selectedIcon: const Icon(Icons.star_rounded),
            ),
          PopupMenuButton<EmojiCategory>(
            key: const Key('emoji-categories'),
            tooltip: categoryLabel,
            icon: showCategoryText ? null : const Icon(Icons.category_outlined),
            enabled: categories.isNotEmpty,
            onSelected: _jumpToCategory,
            itemBuilder: (context) => [
              for (final category in categories)
                PopupMenuItem(
                  key: Key('emoji-category-${category.name}'),
                  value: category,
                  child: Text(
                    widget.labels.categoryLabels[category] ?? category.name,
                  ),
                ),
            ],
            child: showCategoryText
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.category_outlined, size: 18),
                          const SizedBox(width: 6),
                          Text(categoryLabel),
                        ],
                      ),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  List<Widget> _sections(
    BuildContext context,
    Map<EmojiCategory, List<EmojiChoice>> categories,
    double cell,
  ) {
    final favorites = widget.usage.favorites.toSet();
    if (_showFavorites) {
      final stored = _storedChoices(favorites, EmojiCategory.favorites);
      final query = _query.toLowerCase();
      final choices = query.isEmpty
          ? stored
          : stored
                .where(
                  (choice) =>
                      choice.glyph == _query ||
                      choice.searchTerms.any(
                        (term) => term.toLowerCase().contains(query),
                      ),
                )
                .toList(growable: false);
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _favoritesTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Flexible(
                  child: TextButton(
                    key: const Key('emoji-manage-favorites'),
                    onPressed: widget.usageLoaded
                        ? () => _setManaging(true)
                        : null,
                    child: Text(widget.labels.manageFavorites),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (choices.isEmpty && widget.usageLoaded)
          _caption(
            context,
            query.isEmpty ? widget.labels.noFavorites : widget.labels.noResults,
          ),
        _grid(choices, favorites, cell, 'emoji-favorite-choice'),
      ];
    }

    if (_query.isNotEmpty) {
      final choices = widget.catalog
          .search(_query)
          .where((choice) => _isDrawable(choice.glyph))
          .toList(growable: false);
      return [
        if (_managing) _managementHint(context),
        if (choices.isEmpty) _caption(context, widget.labels.noResults),
        _grid(choices, favorites, cell, 'emoji-choice'),
      ];
    }

    final recent = _storedChoices(
      _recentGlyphs ?? const [],
      EmojiCategory.recent,
    );
    final saved = _managing
        ? _storedChoices(favorites, EmojiCategory.favorites)
        : const <EmojiChoice>[];
    return [
      if (_managing) _managementHint(context),
      if (saved.isNotEmpty) ...[
        _caption(context, _favoritesTitle),
        _grid(saved, favorites, cell, 'emoji-favorite-choice'),
      ],
      if (!_managing && recent.isNotEmpty) ...[
        _caption(
          context,
          widget.labels.categoryLabels[EmojiCategory.recent] ??
              widget.labels.noRecents,
          key: const Key('emoji-recent-section'),
        ),
        _recentRow(context, recent, favorites, cell),
      ],
      for (final entry in categories.entries) ...[
        _caption(
          context,
          widget.labels.categoryLabels[entry.key] ?? entry.key.name,
          key: _categoryHeaders.putIfAbsent(entry.key, GlobalKey.new),
        ),
        _grid(entry.value, favorites, cell, 'emoji-choice'),
      ],
    ];
  }

  Widget _managementHint(BuildContext context) => SliverToBoxAdapter(
    child: Container(
      key: const Key('emoji-favorite-mode-hint'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Text(widget.labels.favoriteModeHint),
    ),
  );

  Widget _caption(BuildContext context, String text, {Key? key}) =>
      SliverToBoxAdapter(
        child: Padding(
          key: key,
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 2),
          child: Semantics(
            header: true,
            child: Text(text, style: Theme.of(context).textTheme.titleSmall),
          ),
        ),
      );

  Widget _recentRow(
    BuildContext context,
    List<EmojiChoice> recent,
    Set<String> favorites,
    double cell,
  ) {
    final behavior = ScrollConfiguration.of(context);
    return SliverToBoxAdapter(
      child: SizedBox(
        height: cell,
        child: ScrollConfiguration(
          behavior: behavior.copyWith(
            scrollbars: false,
            dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
          ),
          child: Scrollbar(
            controller: _recentScrollController,
            thumbVisibility: true,
            thickness: 3,
            child: SingleChildScrollView(
              key: const Key('emoji-recent-scroll'),
              controller: _recentScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  for (final choice in recent)
                    SizedBox(
                      width: cell,
                      child: _cell(
                        context,
                        choice,
                        favorites.contains(choice.glyph),
                        cell,
                        'emoji-recent-choice',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _grid(
    List<EmojiChoice> choices,
    Set<String> favorites,
    double cell,
    String keyPrefix,
  ) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    sliver: SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: cell + 8,
        mainAxisExtent: cell,
      ),
      itemCount: choices.length,
      itemBuilder: (context, index) {
        final choice = choices[index];
        return _cell(
          context,
          choice,
          favorites.contains(choice.glyph),
          cell,
          keyPrefix,
        );
      },
    ),
  );

  Widget _cell(
    BuildContext context,
    EmojiChoice choice,
    bool favorite,
    double cell,
    String keyPrefix,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final name = choice.nameFor(Localizations.maybeLocaleOf(context));
    final action = favorite
        ? widget.labels.removeFavoriteLabel
        : widget.labels.addFavoriteLabel;
    final toggle = _canToggleFavorite
        ? () => widget.onToggleFavorite(choice)
        : null;
    final select = _managing
        ? toggle
        : () {
            _freezeRecents();
            widget.onSelected(choice);
          };
    return Center(
      child: Semantics(
        key: Key('$keyPrefix-${choice.keyName}'),
        container: true,
        button: true,
        label: _managing ? '$name. $action' : name,
        selected: _managing ? favorite : null,
        onTap: select,
        onLongPress: toggle,
        child: Tooltip(
          message: _managing ? '$name. $action' : name,
          excludeFromSemantics: true,
          triggerMode: TooltipTriggerMode.manual,
          child: SizedBox.square(
            dimension: cell,
            child: InkWell(
              excludeFromSemantics: true,
              customBorder: const CircleBorder(),
              onTap: select,
              onLongPress: toggle,
              onSecondaryTap: toggle,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    choice.glyph,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: cell * 0.55),
                  ),
                  if (favorite || _managing)
                    PositionedDirectional(
                      end: 2,
                      bottom: 2,
                      child: Icon(
                        favorite
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        size: 14,
                        color: favorite
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
