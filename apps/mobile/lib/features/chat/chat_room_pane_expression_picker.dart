part of 'chat_room_pane.dart';

extension _ChatRoomExpressionPicker on _ChatRoomPaneState {
  Widget _expressionPicker(
    AsyncValue<HttpGiphyRepository?>? giphy, {
    required bool checkingAttachments,
    required bool fileAttachmentSupported,
  }) {
    final room = _key;
    final generation = _textSendGeneration;
    final strings = AppLocalizations.of(context);
    return _ExpressionPicker(
      accountId: AccountId.parse(room.accountId),
      usageStore: ref.read(emojiUsageStoreProvider),
      onClose: _closeEmojiPicker,
      onEmoji: _insertEmoji,
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

final class _TimelineWithExpressionPicker extends StatelessWidget {
  const _TimelineWithExpressionPicker({required this.timeline, this.picker});

  final Widget timeline;
  final Widget? picker;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, bounds) {
        final height = math.min(
          320.0,
          MediaQuery.sizeOf(context).height * 0.45,
        );
        return Column(
          children: [
            Expanded(child: timeline),
            if (picker != null)
              SizedBox(
                height: math.min(height, bounds.maxHeight),
                child: SingleChildScrollView(
                  primary: false,
                  child: SizedBox(height: height, child: picker),
                ),
              ),
          ],
        );
      },
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
  });

  final AccountId accountId;
  final EmojiUsageStore usageStore;
  final VoidCallback onClose;
  final ValueChanged<EmojiChoice> onEmoji;
  final VoidCallback onShowGifs;
  final Widget Function() buildGifs;

  @override
  State<_ExpressionPicker> createState() => _ExpressionPickerState();
}

final class _ExpressionPickerState extends State<_ExpressionPicker> {
  bool _gifs = false;

  void _select(bool gifs) {
    if (_gifs == gifs) return;
    if (gifs) widget.onShowGifs();
    setState(() => _gifs = gifs);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final tabs = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          ChoiceChip(
            key: const Key('composer-emoji-tab'),
            label: Text(strings.emojiPickerTitle),
            selected: !_gifs,
            showCheckmark: false,
            onSelected: (_) => _select(false),
          ),
          const SizedBox(width: 4),
          ChoiceChip(
            key: const Key('open-giphy-picker'),
            label: Text(strings.gifTab),
            selected: _gifs,
            showCheckmark: false,
            onSelected: (_) => _select(true),
          ),
        ],
      ),
    );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SizedBox(
        key: const Key('inline-emoji-panel'),
        child: _gifs
            ? Column(
                children: [
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        Expanded(child: tabs),
                        IconButton(
                          key: const Key('emoji-close'),
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).closeButtonTooltip,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: widget.buildGifs()),
                ],
              )
            : EmojiPicker(
                accountId: widget.accountId,
                usageStore: widget.usageStore,
                labels: emojiPickerLabelsFor(strings),
                onClose: widget.onClose,
                onSelected: widget.onEmoji,
                headerTabs: tabs,
              ),
      ),
    );
  }
}

final class _ComposerGifs extends StatefulWidget {
  const _ComposerGifs({
    required this.repository,
    required this.onSelected,
    super.key,
  });

  final HttpGiphyRepository repository;
  final ValueChanged<GiphyEntry> onSelected;

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
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return GiphyPicker(
      controller: _controller,
      labels: GiphyPickerLabels(
        searchHint: strings.giphySearchHint,
        noResults: strings.giphyNoResults,
        retry: strings.retry,
        loadMore: strings.giphyLoadMore,
        poweredByGiphy: strings.giphyPoweredBy,
      ),
      thumbnailBuilder: (_, entry) => ExcludeSemantics(
        child: _GiphyThumbnail(repository: widget.repository, entry: entry),
      ),
      onAttributionPressed: (uri) async {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      onSelected: widget.onSelected,
    );
  }
}
