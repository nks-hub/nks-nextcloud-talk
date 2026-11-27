part of 'chat_room_pane.dart';

extension _ChatRoomExpressionPicker on _ChatRoomPaneState {
  Widget _expressionPickerButton(AppLocalizations strings, Widget? picker) {
    final button = IconButton(
      key: const Key('open-emoji-picker'),
      onPressed: _sending ? null : _toggleEmojiPicker,
      tooltip: strings.emojiAndGifs,
      isSelected: _emojiPickerOpen,
      icon: const Icon(Icons.emoji_emotions_outlined),
      selectedIcon: const Icon(Icons.emoji_emotions),
    );
    return picker == null
        ? button
        : _DesktopExpressionPicker(
            paneKey: _expressionPaneKey,
            picker: picker,
            anchor: button,
          );
  }

  Widget _expressionPicker(
    AsyncValue<HttpGiphyRepository?>? giphy, {
    required bool checkingAttachments,
    required bool fileAttachmentSupported,
  }) {
    final room = _key;
    final generation = _textSendGeneration;
    final strings = AppLocalizations.of(context);
    final repository = giphy?.asData?.value;
    return _ExpressionPicker(
      key: ValueKey(room),
      accountId: AccountId.parse(room.accountId),
      usageStore: ref.read(emojiUsageStoreProvider),
      onClose: _closeEmojiPicker,
      onEmoji: _insertEmoji,
      attribution: repository == null
          ? null
          : GiphyAttributionLink(
              repository: repository,
              label: strings.giphyPoweredBy,
              onPressed: _openGiphyAttribution,
            ),
      onShowGifs: () {
        if (!_giphyRequested) _update(() => _giphyRequested = true);
      },
      buildGifs: () {
        if (checkingAttachments || (fileAttachmentSupported && giphy == null)) {
          return Center(child: Text(strings.mediaCapabilityChecking));
        }
        if (!fileAttachmentSupported) {
          return Center(child: Text(strings.mediaCapabilityUnavailable));
        }
        return giphy!.when(
          skipLoadingOnRefresh: false,
          loading: () => Center(child: Text(strings.giphyChecking)),
          error: (_, _) => Center(
            child: TextButton(
              onPressed: () =>
                  ref.invalidate(giphyRepositoryProvider(room.accountId)),
              child: Text(strings.giphyRetry),
            ),
          ),
          data: (repository) => repository == null
              ? Center(child: Text(strings.giphyUnavailable))
              : _ComposerGifs(
                  key: ObjectKey(repository),
                  repository: repository,
                  accountId: AccountId.parse(room.accountId),
                  favoritesStore: ref.read(gifFavoritesStoreProvider),
                  favoritesSync: ref.read(gifFavoritesSyncProvider),
                  onSelected: (entry) {
                    if (!mounted ||
                        !_emojiPickerOpen ||
                        _sending ||
                        room != _key ||
                        generation != _textSendGeneration ||
                        _isReadOnlyNow()) {
                      return;
                    }
                    if (!isSupportedGiphyResource(entry.resourceUrl)) {
                      _update(
                        () => _localError = ChatServiceError.invalidResponse,
                      );
                      return;
                    }
                    _closeEmojiPicker();
                    unawaited(
                      _sendMessage(
                        entry.resourceUrl.toString(),
                        clearComposer: false,
                        expectedKey: room,
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

Future<void> _openGiphyAttribution(Uri uri) async {
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

final class _TimelineWithExpressionPicker extends StatelessWidget {
  const _TimelineWithExpressionPicker({required this.timeline, this.picker});

  final Widget timeline;
  final Widget? picker;

  @override
  Widget build(BuildContext context) {
    final panel = picker;
    return LayoutBuilder(
      builder: (context, bounds) {
        final preferred = (MediaQuery.sizeOf(context).height * 0.45).clamp(
          _ExpressionViewport.minimumHeight,
          320.0,
        );
        return Column(
          children: [
            Expanded(child: timeline),
            if (panel != null)
              _ExpressionViewport(
                height: math.min(preferred, bounds.maxHeight),
                child: panel,
              ),
          ],
        );
      },
    );
  }
}

final class _ExpressionViewport extends StatelessWidget {
  const _ExpressionViewport({required this.height, required this.child});

  static const minimumHeight = 152.0;

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: height < minimumHeight
          ? SingleChildScrollView(
              primary: false,
              child: SizedBox(height: minimumHeight, child: child),
            )
          : child,
    );
  }
}

final class _DesktopExpressionPicker extends StatefulWidget {
  const _DesktopExpressionPicker({
    required this.paneKey,
    required this.picker,
    required this.anchor,
  });

  final GlobalKey paneKey;
  final Widget picker;
  final Widget anchor;

  @override
  State<_DesktopExpressionPicker> createState() =>
      _DesktopExpressionPickerState();
}

final class _DesktopExpressionPickerState
    extends State<_DesktopExpressionPicker> {
  final _portal = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: _buildPanel,
      child: widget.anchor,
    );
  }

  Widget _buildPanel(BuildContext context, OverlayChildLayoutInfo layout) {
    final pane = widget.paneKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (pane is! RenderBox || !pane.hasSize || overlay == null) {
      return const SizedBox.shrink();
    }
    final paneBounds = MatrixUtils.transformRect(
      pane.getTransformTo(overlay),
      Offset.zero & pane.size,
    ).intersect(Offset.zero & layout.overlaySize);
    final anchor = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    final bottom = math.min(paneBounds.bottom, anchor.top - 8);
    final width = math.min(420.0, paneBounds.width);
    final height = math.min(360.0, bottom - paneBounds.top);
    if (height <= 0 || width <= 0) return const SizedBox.shrink();
    final left = (anchor.right - width).clamp(
      paneBounds.left,
      paneBounds.right - width,
    );
    return Stack(
      children: [
        Positioned(
          left: left,
          top: bottom - height,
          width: width,
          height: height,
          child: _ExpressionViewport(height: height, child: widget.picker),
        ),
      ],
    );
  }
}

final class _ExpressionPicker extends StatefulWidget {
  const _ExpressionPicker({
    required this.accountId,
    required this.usageStore,
    required this.onClose,
    required this.onEmoji,
    required this.onShowGifs,
    required this.buildGifs,
    required this.attribution,
    super.key,
  });

  final AccountId accountId;
  final EmojiUsageStore usageStore;
  final VoidCallback onClose;
  final ValueChanged<EmojiChoice> onEmoji;
  final VoidCallback onShowGifs;
  final Widget Function() buildGifs;
  final Widget? attribution;

  @override
  State<_ExpressionPicker> createState() => _ExpressionPickerState();
}

final class _ExpressionPickerState extends State<_ExpressionPicker> {
  final _emojiFocus = FocusScopeNode();
  final _gifFocus = FocusScopeNode();
  _ExpressionTab _tab = _ExpressionTab.emoji;
  bool _openedGifs = false;
  ModalRoute<dynamic>? _route;
  LocalHistoryEntry? _history;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(_route, route)) return;
    _removeHistory();
    _route = route;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_route, route) || !route.isActive) return;
      late final LocalHistoryEntry entry;
      entry = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          if (!identical(_history, entry)) return;
          _history = null;
          if (mounted) _close();
        },
      );
      _history = entry;
      route.addLocalHistoryEntry(entry);
    });
  }

  void _removeHistory() {
    final entry = _history;
    _history = null;
    entry?.remove();
  }

  @override
  void dispose() {
    _removeHistory();
    _emojiFocus.dispose();
    _gifFocus.dispose();
    super.dispose();
  }

  void _close() {
    if (_emojiFocus.hasFocus) _emojiFocus.unfocus();
    if (_gifFocus.hasFocus) _gifFocus.unfocus();
    widget.onClose();
  }

  void _select(int index) {
    final next = _ExpressionTab.values[index];
    if (next == _tab) return;
    final previousFocus = _tab == _ExpressionTab.emoji
        ? _emojiFocus
        : _gifFocus;
    if (previousFocus.hasFocus) previousFocus.unfocus();
    if (next == _ExpressionTab.gifs && !_openedGifs) {
      widget.onShowGifs();
      _openedGifs = true;
    }
    setState(() => _tab = next);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final desktop = context.sendsOnEnter;
    final gifTab = _tab == _ExpressionTab.gifs;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Material(
        color: scheme.surfaceContainerLow,
        elevation: desktop ? 8 : 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: DefaultTabController(
          length: _ExpressionTab.values.length,
          child: Column(
            key: const Key('inline-emoji-panel'),
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    Expanded(
                      child: TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        dividerHeight: 0,
                        indicatorWeight: 2,
                        indicatorColor: scheme.primary,
                        labelStyle: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        unselectedLabelStyle: theme.textTheme.labelLarge,
                        labelPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        onTap: _select,
                        tabs: [
                          _tabLabel(
                            strings.emojiPickerTitle,
                            const Key('composer-emoji-tab'),
                          ),
                          _tabLabel(
                            strings.gifTab,
                            const Key('open-giphy-picker'),
                          ),
                        ],
                      ),
                    ),
                    if (widget.attribution case final attribution?
                        when _openedGifs)
                      Visibility(
                        visible: gifTab,
                        maintainState: true,
                        child: attribution,
                      ),
                    SizedBox.square(
                      dimension: 48,
                      child: IconButton(
                        key: const Key('emoji-close'),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: _close,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Visibility(
                      visible: !gifTab,
                      maintainState: true,
                      child: FocusScope(
                        node: _emojiFocus,
                        child: EmojiPicker(
                          accountId: widget.accountId,
                          usageStore: widget.usageStore,
                          labels: emojiPickerLabelsFor(strings),
                          onClose: _close,
                          onSelected: widget.onEmoji,
                          composer: true,
                        ),
                      ),
                    ),
                    if (_openedGifs)
                      Visibility(
                        visible: gifTab,
                        maintainState: true,
                        child: FocusScope(
                          node: _gifFocus,
                          child: widget.buildGifs(),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabLabel(String label, Key key) => Tab(
    height: 48,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 40),
      child: Center(child: Text(label, key: key)),
    ),
  );
}

enum _ExpressionTab { emoji, gifs }

final class _ComposerGifs extends StatefulWidget {
  const _ComposerGifs({
    required this.repository,
    required this.accountId,
    required this.favoritesStore,
    required this.favoritesSync,
    required this.onSelected,
    super.key,
  });

  final HttpGiphyRepository repository;
  final AccountId accountId;
  final GifFavoritesStore favoritesStore;
  final GifFavoritesSync favoritesSync;
  final ValueChanged<GiphyEntry> onSelected;

  void refreshFavorites() =>
      unawaited(favoritesSync.refresh(accountId, repository.server));

  @override
  State<_ComposerGifs> createState() => _ComposerGifsState();
}

final class _ComposerGifsState extends State<_ComposerGifs> {
  late final GiphyController _controller;

  @override
  void initState() {
    super.initState();
    _controller = GiphyController(repository: widget.repository);
    unawaited(_controller.loadTrending());
    widget.refreshFavorites();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return GifFavoritesScope(
      accountId: widget.accountId,
      store: widget.favoritesStore,
      onChanged: widget.refreshFavorites,
      builder: (context, favorites) => GiphyPicker(
        controller: _controller,
        labels: GiphyPickerLabels(
          searchHint: strings.giphySearchHint,
          noResults: strings.giphyNoResults,
          retry: strings.retry,
          loadMore: strings.giphyLoadMore,
          poweredByGiphy: strings.giphyPoweredBy,
          sendResult: strings.giphySendResult,
        ),
        desktop: context.sendsOnEnter,
        showAttribution: false,
        onFavoritesOpened: widget.refreshFavorites,
        favorites: (
          entries: favorites.entries,
          loading: favorites.loading,
          label: strings.giphyMyGifs,
          searchHint: strings.giphySearchMyGifs,
          emptyHint: strings.giphyMyGifsEmpty,
          buttonBuilder: (_, entry) =>
              GifFavoriteButton(entry: entry, favorites: favorites),
        ),
        thumbnailBuilder: (_, entry) => ExcludeSemantics(
          child: _GiphyThumbnail(repository: widget.repository, entry: entry),
        ),
        onAttributionPressed: _openGiphyAttribution,
        onSelected: widget.onSelected,
      ),
    );
  }
}
