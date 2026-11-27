part of 'giphy.dart';

enum GiphyLoadPhase { idle, loading, ready, error }

const _coldTrendingRetryDelays = <Duration>[Duration(milliseconds: 500)];

final class GiphyController extends ChangeNotifier {
  GiphyController({
    required this.repository,
    this.pageSize = 20,
    this.searchDebounce = const Duration(milliseconds: 350),
  });

  final GiphyRepository repository;
  final int pageSize;

  /// How long typing has to pause before the term is searched. Long enough
  /// that a whole word is one request, short enough to feel immediate.
  final Duration searchDebounce;

  Timer? _debounce;

  List<GiphyEntry> _entries = const <GiphyEntry>[];
  GiphyLoadPhase _phase = GiphyLoadPhase.idle;
  GiphyError? _error;
  String? _term;
  int _cursor = 0;
  int _generation = 0;
  Completer<void>? _abort;
  bool _disposed = false;

  List<GiphyEntry> get entries => _entries;
  GiphyLoadPhase get phase => _phase;
  GiphyError? get error => _error;
  String? get term => _term;
  int get cursor => _cursor;

  Future<bool> loadTrending() {
    final isColdLoad = _phase == GiphyLoadPhase.idle && _entries.isEmpty;
    return _load(
      term: null,
      append: false,
      retryDelays: isColdLoad ? _coldTrendingRetryDelays : const <Duration>[],
    );
  }

  Future<bool> search(String term) {
    final normalized = term.trim();
    return normalized.isEmpty
        ? loadTrending()
        : _load(
            term: normalized,
            append: false,
            retryDelays: const <Duration>[],
          );
  }

  /// Searches while the user types. Keystrokes are coalesced into one request
  /// and a term that is already showing is not fetched again; clearing the
  /// field falls back to trending like an explicit empty search does.
  void searchAsTyped(String term) {
    _debounce?.cancel();
    if (_disposed) {
      return;
    }
    final normalized = term.trim();
    if (normalized == (_term ?? '') && _phase != GiphyLoadPhase.error) {
      return;
    }
    _debounce = Timer(searchDebounce, () {
      _debounce = null;
      if (_disposed) {
        return;
      }
      unawaited(search(normalized));
    });
  }

  Future<bool> loadMore() =>
      _load(term: _term, append: true, retryDelays: const <Duration>[]);

  Future<bool> _load({
    required String? term,
    required bool append,
    required List<Duration> retryDelays,
  }) async {
    if (_disposed ||
        pageSize < 1 ||
        pageSize > 50 ||
        (_phase == GiphyLoadPhase.loading && append)) {
      return false;
    }
    final generation = ++_generation;
    _abort?.complete();
    final abort = _abort = Completer<void>();
    final requestedCursor = append ? _cursor : 0;
    _phase = GiphyLoadPhase.loading;
    _error = null;
    if (!append) {
      _term = term;
    }
    notifyListeners();
    for (var attempt = 0; ; attempt++) {
      try {
        final page = term == null
            ? await repository.trending(
                cursor: requestedCursor,
                limit: pageSize,
                abortTrigger: abort.future,
              )
            : await repository.search(
                term: term,
                cursor: requestedCursor,
                limit: pageSize,
                abortTrigger: abort.future,
              );
        if (_disposed || generation != _generation) {
          return false;
        }
        _entries = List<GiphyEntry>.unmodifiable(
          append ? <GiphyEntry>[..._entries, ...page.entries] : page.entries,
        );
        _cursor = page.cursor;
        _phase = GiphyLoadPhase.ready;
        notifyListeners();
        return true;
      } on GiphyException catch (error) {
        if (_disposed || generation != _generation) {
          return false;
        }
        if (attempt < retryDelays.length && _isTransient(error.error)) {
          await Future.any<void>(<Future<void>>[
            Future<void>.delayed(retryDelays[attempt]),
            abort.future,
          ]);
          if (_disposed || generation != _generation) {
            return false;
          }
          continue;
        }
        _phase = GiphyLoadPhase.error;
        _error = error.error;
        notifyListeners();
        return false;
      } on Object {
        if (_disposed || generation != _generation) {
          return false;
        }
        if (attempt < retryDelays.length) {
          await Future.any<void>(<Future<void>>[
            Future<void>.delayed(retryDelays[attempt]),
            abort.future,
          ]);
          if (_disposed || generation != _generation) {
            return false;
          }
          continue;
        }
        _phase = GiphyLoadPhase.error;
        _error = GiphyError.network;
        notifyListeners();
        return false;
      }
    }
  }

  bool _isTransient(GiphyError error) =>
      error == GiphyError.network ||
      error == GiphyError.timeout ||
      error == GiphyError.unexpectedStatus;

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
    _generation++;
    _abort?.complete();
    super.dispose();
  }
}

final class GiphyPickerLabels {
  const GiphyPickerLabels({
    required this.searchHint,
    required this.noResults,
    required this.retry,
    required this.loadMore,
    required this.poweredByGiphy,
    this.sendResult,
  });

  final String searchHint;
  final String noResults;
  final String retry;
  final String loadMore;
  final String poweredByGiphy;
  final String Function(String title)? sendResult;
}

typedef GiphyThumbnailBuilder =
    Widget Function(BuildContext context, GiphyEntry entry);
typedef GiphyAttributionOpener = Future<void> Function(Uri uri);

typedef GiphyPickerFavorites = ({
  List<GiphyEntry> entries,
  bool loading,
  String label,
  String searchHint,
  String emptyHint,
  GiphyThumbnailBuilder buttonBuilder,
});

final class GiphyPicker extends StatefulWidget {
  const GiphyPicker({
    required this.controller,
    required this.labels,
    required this.thumbnailBuilder,
    required this.onSelected,
    required this.onAttributionPressed,
    this.desktop = false,
    this.showAttribution = true,
    this.favorites,
    super.key,
  });

  final GiphyController controller;
  final GiphyPickerLabels labels;
  final GiphyThumbnailBuilder thumbnailBuilder;
  final ValueChanged<GiphyEntry> onSelected;
  final GiphyAttributionOpener onAttributionPressed;
  final bool desktop;
  final bool showAttribution;
  final GiphyPickerFavorites? favorites;

  @override
  State<GiphyPicker> createState() => _GiphyPickerState();
}

final class _GiphyPickerState extends State<GiphyPicker> {
  static const _gridPadding = EdgeInsets.fromLTRB(8, 4, 8, 8);
  static const _gap = 8.0;

  final _query = TextEditingController();
  final _scrollStorage = PageStorageBucket();
  bool _favoritesOnly = false;

  GiphyController get _controller => widget.controller;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _searchChanged(String value) {
    setState(() {});
    if (!_favoritesOnly) _controller.searchAsTyped(value);
  }

  void _toggleFavorites() {
    setState(() => _favoritesOnly = !_favoritesOnly);
    if (!_favoritesOnly) _controller.searchAsTyped(_query.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final favorites = widget.favorites;
    final labels = widget.labels;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: TextField(
                    key: const Key('giphy-search'),
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _favoritesOnly
                          ? favorites?.searchHint ?? labels.searchHint
                          : labels.searchHint,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: _query.text.isEmpty
                          ? null
                          : IconButton(
                              key: const Key('giphy-clear-search'),
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).deleteButtonTooltip,
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                _query.clear();
                                _searchChanged('');
                              },
                            ),
                      filled: true,
                      fillColor: scheme.surfaceContainerHigh,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      isDense: true,
                    ),
                    onChanged: _searchChanged,
                    onSubmitted: _favoritesOnly ? null : _controller.search,
                  ),
                ),
              ),
              if (favorites != null) ...[
                const SizedBox(width: 4),
                SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    key: const Key('giphy-my-gifs'),
                    tooltip: favorites.label,
                    isSelected: _favoritesOnly,
                    icon: const Icon(Icons.star_border_rounded),
                    selectedIcon: const Icon(Icons.star_rounded),
                    onPressed: _toggleFavorites,
                  ),
                ),
              ],
              if (widget.showAttribution)
                GiphyAttributionLink(
                  repository: _controller.repository,
                  label: labels.poweredByGiphy,
                  onPressed: widget.onAttributionPressed,
                ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, bounds) => AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => _buildResults(bounds),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResults(BoxConstraints bounds) {
    final controller = _controller;
    final labels = widget.labels;
    final filtered = _favoritesOnly ? widget.favorites : null;
    final query = _query.text.trim().toLowerCase();
    final entries = filtered == null
        ? controller.entries
        : filtered.entries
              .where(
                (entry) =>
                    entry.title.toLowerCase().contains(query) ||
                    entry.subline.toLowerCase().contains(query),
              )
              .toList(growable: false);
    if (entries.isEmpty &&
        (filtered?.loading ?? controller.phase == GiphyLoadPhase.loading)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (filtered == null &&
        controller.phase == GiphyLoadPhase.error &&
        entries.isEmpty) {
      return Center(
        child: FilledButton(
          onPressed: controller.term == null
              ? controller.loadTrending
              : () => controller.search(controller.term!),
          child: Text(labels.retry),
        ),
      );
    }
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            filtered != null && filtered.entries.isEmpty
                ? filtered.emptyHint
                : labels.noResults,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final columns = switch (bounds.maxWidth) {
      >= 400 when widget.desktop => 4,
      >= 280 => 3,
      >= 176 => 2,
      _ => 1,
    };
    final tileHeight = ((bounds.maxHeight - _gridPadding.top - _gap) / 2).clamp(
      48.0,
      widget.desktop ? 103.0 : 90.0,
    );
    return PageStorage(
      bucket: _scrollStorage,
      child: CustomScrollView(
        key: PageStorageKey<String>(
          filtered == null ? 'giphy-grid' : 'giphy-favorites-grid',
        ),
        slivers: [
          SliverPadding(
            padding: _gridPadding,
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: tileHeight,
                mainAxisSpacing: _gap,
                crossAxisSpacing: _gap,
              ),
              itemCount: entries.length,
              itemBuilder: (context, index) =>
                  _buildTile(context, entries[index]),
            ),
          ),
          if (filtered == null)
            SliverToBoxAdapter(
              child: Center(
                child: TextButton(
                  onPressed: controller.phase == GiphyLoadPhase.loading
                      ? null
                      : controller.loadMore,
                  child: Text(labels.loadMore),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context, GiphyEntry entry) {
    final favorites = widget.favorites;
    final label = widget.labels.sendResult?.call(entry.title) ?? entry.title;
    return Stack(
      key: ValueKey(entry.resourceUrl),
      fit: StackFit.expand,
      children: [
        Semantics(
          button: true,
          label: label,
          child: Tooltip(
            message: label,
            excludeFromSemantics: true,
            triggerMode: TooltipTriggerMode.manual,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => widget.onSelected(entry),
              child: widget.thumbnailBuilder(context, entry),
            ),
          ),
        ),
        if (favorites != null)
          PositionedDirectional(
            top: 0,
            end: 0,
            child: favorites.buttonBuilder(context, entry),
          ),
      ],
    );
  }
}

final class GiphyAttributionLink extends StatefulWidget {
  const GiphyAttributionLink({
    super.key,
    required this.repository,
    required this.label,
    required this.onPressed,
  });

  final GiphyRepository repository;
  final String label;
  final GiphyAttributionOpener onPressed;

  @override
  State<GiphyAttributionLink> createState() => _GiphyAttributionLinkState();
}

final class _GiphyAttributionLinkState extends State<GiphyAttributionLink> {
  late Future<GiphyAttributionAsset> _asset;
  Completer<void>? _abort;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant GiphyAttributionLink oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
      _load();
    }
  }

  void _load() {
    final previousAbort = _abort;
    if (previousAbort != null && !previousAbort.isCompleted) {
      previousAbort.complete();
    }
    final abort = _abort = Completer<void>();
    _asset = widget.repository.loadAttributionAsset(abortTrigger: abort.future);
  }

  Future<void> _open() async {
    try {
      await widget.onPressed(giphyAttributionUri);
    } on Object {
      // Failure to open a third-party website must not break the picker.
    }
  }

  @override
  void dispose() {
    final abort = _abort;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: scheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: scheme.primary,
      ),
    );
    return Tooltip(
      message: widget.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('giphy-attribution-link'),
          onTap: () => unawaited(_open()),
          child: SizedBox(
            height: 48,
            width: 104,
            child: Center(
              child: FutureBuilder<GiphyAttributionAsset>(
                future: _asset,
                builder: (context, snapshot) {
                  final asset = snapshot.data;
                  if (snapshot.connectionState != ConnectionState.done ||
                      snapshot.hasError ||
                      asset == null) {
                    return fallback;
                  }
                  return Image.memory(
                    asset.body,
                    key: const Key('giphy-attribution-image'),
                    width: 96,
                    height: 22,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                    errorBuilder: (_, _, _) => fallback,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
