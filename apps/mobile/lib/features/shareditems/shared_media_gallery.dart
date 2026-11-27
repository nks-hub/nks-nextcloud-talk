part of 'shared_items_screen.dart';

typedef _Photo = ({ChatMessage message, ChatGalleryImage image, int index});
typedef _PhotoPage = ({List<_Photo> photos, bool more, bool failed});

extension _SharedMedia on _SharedItemsScreenState {
  List<_Photo> _photos() => [
    for (final message in _messages)
      for (final (index, image) in sharedPhotosInMessage(
        widget.account,
        message,
      ).indexed)
        (message: message, image: image, index: index),
  ];

  Widget _mediaGrid(AppLocalizations strings) {
    final photos = _photos();
    final counts = <int, int>{};
    for (final photo in photos) {
      final id = photo.message.messageId;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    final others = _messages.where((m) {
      final pictures = counts[m.messageId] ?? 0;
      final files = m.messageParameters.values
          .where((p) => p.type == 'file')
          .length;
      return pictures == 0 || pictures < files;
    }).toList();
    return CustomScrollView(
      key: const Key('shared-items-list'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(8),
          sliver: SliverGrid.builder(
            key: const Key('shared-media-grid'),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: photos.length,
            itemBuilder: (_, i) => _PhotoTile(
              account: widget.account,
              photo: photos[i],
              onTap: () => _openGallery(photos, i),
            ),
          ),
        ),
        SliverList.builder(
          itemCount: others.length,
          itemBuilder: (_, i) => _SharedMessageTile(
            account: widget.account,
            message: others[i],
            onTap: _openingMessage ? null : () => _openMessage(others[i]),
          ),
        ),
        if (_moreItemsPossible || _loadMoreError != null)
          SliverToBoxAdapter(child: _pageFooter(strings)),
      ],
    );
  }

  Future<void> _openGallery(List<_Photo> photos, int index) async {
    final owner = widget.account;
    final token = widget.conversation.token;
    bool current() =>
        mounted &&
        widget.account.id == owner.id &&
        widget.conversation.token == token &&
        _selectedType == SharedItemType.media;
    final original = await Navigator.of(context).push<ChatMessage>(
      MaterialPageRoute<ChatMessage>(
        settings: const RouteSettings(name: '/conversation/shared-items/media'),
        fullscreenDialog: true,
        builder: (_) => _SharedViewer(
          account: owner,
          initial: (photos: photos, more: _moreItemsPossible, failed: false),
          index: index,
          next: () async {
            if (!current()) return null;
            await _loadMore();
            if (!current()) return null;
            return (
              photos: _photos(),
              more: _moreItemsPossible,
              failed: _loadMoreError != null,
            );
          },
        ),
      ),
    );
    if (original != null && current()) _openMessage(original);
  }
}

final class _PhotoTile extends ConsumerWidget {
  const _PhotoTile({
    required this.account,
    required this.photo,
    required this.onTap,
  });
  final StoredAccount account;
  final _Photo photo;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = photo.image;
    final uri = image.smallerPreviewUri;
    final thumbnail = uri?.replace(
      queryParameters: {...uri.queryParameters, 'x': '384', 'y': '384'},
    );
    final preview = thumbnail == null
        ? null
        : ref
              .watch(
                chatMediaProvider(
                  ChatMediaProviderKey(account: account, uri: thumbnail),
                ),
              )
              .valueOrNull;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: ValueKey('shared-photo-${photo.message.messageId}-${photo.index}'),
        onTap: onTap,
        child: Semantics(
          image: true,
          label: image.name,
          child: preview == null
              ? const Icon(Icons.image_outlined)
              : Image.memory(
                  preview.body,
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined),
                ),
        ),
      ),
    );
  }
}

final class _SharedViewer extends ConsumerStatefulWidget {
  const _SharedViewer({
    required this.account,
    required this.initial,
    required this.index,
    required this.next,
  });
  final StoredAccount account;
  final _PhotoPage initial;
  final int index;
  final Future<_PhotoPage?> Function() next;
  @override
  ConsumerState<_SharedViewer> createState() => _SharedViewerState();
}

final class _SharedViewerState extends ConsumerState<_SharedViewer> {
  late _PhotoPage page = widget.initial;
  late int index = widget.index;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetch();
    });
  }

  void _prefetch() {
    if (index >= page.photos.length - 2 && !page.failed) unawaited(_next());
  }

  Future<void> _next() async {
    if (loading || !page.more) return;
    setState(() => loading = true);
    final result = await widget.next();
    if (!mounted) return;
    if (result == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      page = result;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Stack(
      children: [
        AuthenticatedImageGallery(
          account: widget.account,
          initialIndex: widget.index,
          images: [for (final p in page.photos) p.image],
          repository: ref.watch(chatMediaRepositoryProvider),
          openAppSettings: () => ref.read(appSettingsOpenerProvider).open(),
          onIndexChanged: (i) {
            setState(() => index = i);
            _prefetch();
          },
          onOpenSource: (i) =>
              Navigator.of(context).pop(page.photos[i].message),
        ),
        if (index == page.photos.length - 1 && page.more)
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FilledButton.icon(
                key: const Key('shared-media-next-page'),
                onPressed: loading ? null : _next,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(
                  page.failed ? strings.retry : strings.sharedItemsLoadMore,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
