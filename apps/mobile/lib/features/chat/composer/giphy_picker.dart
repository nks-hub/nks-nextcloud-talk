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
  });

  final String searchHint;
  final String noResults;
  final String retry;
  final String loadMore;
  final String poweredByGiphy;
}

typedef GiphyThumbnailBuilder =
    Widget Function(BuildContext context, GiphyEntry entry);
typedef GiphyAttributionOpener = Future<void> Function(Uri uri);

final class GiphyPicker extends StatelessWidget {
  const GiphyPicker({
    required this.controller,
    required this.labels,
    required this.thumbnailBuilder,
    required this.onSelected,
    required this.onAttributionPressed,
    super.key,
  });

  final GiphyController controller;
  final GiphyPickerLabels labels;
  final GiphyThumbnailBuilder thumbnailBuilder;
  final ValueChanged<GiphyEntry> onSelected;
  final GiphyAttributionOpener onAttributionPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('giphy-search'),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: labels.searchHint,
                prefixIcon: const Icon(Icons.search_rounded),
                border: const OutlineInputBorder(),
              ),
              onChanged: controller.searchAsTyped,
              onSubmitted: controller.search,
            ),
          ),
          Expanded(child: _buildResults(context)),
          _GiphyAttributionLink(
            repository: controller.repository,
            label: labels.poweredByGiphy,
            onPressed: onAttributionPressed,
          ),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (controller.phase == GiphyLoadPhase.loading &&
        controller.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.phase == GiphyLoadPhase.error &&
        controller.entries.isEmpty) {
      return Center(
        child: FilledButton(
          onPressed: controller.term == null
              ? controller.loadTrending
              : () => controller.search(controller.term!),
          child: Text(labels.retry),
        ),
      );
    }
    if (controller.entries.isEmpty) {
      return Center(child: Text(labels.noResults));
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(8),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: controller.entries.length,
            itemBuilder: (context, index) {
              final entry = controller.entries[index];
              return Semantics(
                button: true,
                label: entry.title,
                child: InkWell(
                  onTap: () => onSelected(entry),
                  child: thumbnailBuilder(context, entry),
                ),
              );
            },
          ),
        ),
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
    );
  }
}

final class _GiphyAttributionLink extends StatefulWidget {
  const _GiphyAttributionLink({
    required this.repository,
    required this.label,
    required this.onPressed,
  });

  final GiphyRepository repository;
  final String label;
  final GiphyAttributionOpener onPressed;

  @override
  State<_GiphyAttributionLink> createState() => _GiphyAttributionLinkState();
}

final class _GiphyAttributionLinkState extends State<_GiphyAttributionLink> {
  late Future<GiphyAttributionAsset> _asset;
  Completer<void>? _abort;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _GiphyAttributionLink oldWidget) {
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
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: scheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: scheme.primary,
      ),
    );
    return Tooltip(
      message: widget.label,
      child: Material(
        color: scheme.surface,
        child: InkWell(
          key: const Key('giphy-attribution-link'),
          onTap: () => unawaited(_open()),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 160),
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
                    height: 30,
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
