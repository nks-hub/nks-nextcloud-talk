part of 'chat_message_content.dart';

final class _InlineChatImagePreview extends StatefulWidget {
  const _InlineChatImagePreview({
    super.key,
    required this.parameter,
    required this.image,
    required this.name,
    required this.messageId,
    required this.index,
    required this.onOpen,
    required this.onRetry,
  });

  final ChatRichObjectParameter parameter;
  final AsyncValue<ChatMediaImage?> image;
  final String name;
  final int messageId;
  final int index;
  final VoidCallback? onOpen;
  final Future<void> Function() onRetry;

  @override
  State<_InlineChatImagePreview> createState() =>
      _InlineChatImagePreviewState();
}

final class _InlineChatImagePreviewState
    extends State<_InlineChatImagePreview> {
  ChatMediaImage? _image;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _decodedSize;
  bool _decodeFailed = false;
  bool _retrying = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveDimensions();
  }

  @override
  void didUpdateWidget(_InlineChatImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolveDimensions();
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _resolveDimensions() {
    final image = widget.image.asData?.value;
    if (identical(image, _image)) return;
    _stopListening();
    final generation = ++_generation;
    _image = image;
    _decodeFailed = false;
    if (image == null) return;
    final cached = image.decodedDimensions;
    if (cached != null) {
      _decodedSize = Size(cached.width.toDouble(), cached.height.toDouble());
      return;
    }
    _stream = MemoryImage(
      image.body,
    ).resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, synchronous) {
        try {
          if (!mounted || generation != _generation) return;
          image.rememberDecodedDimensions(
            width: info.image.width,
            height: info.image.height,
          );
          setState(
            () => _decodedSize = Size(
              info.image.width.toDouble(),
              info.image.height.toDouble(),
            ),
          );
        } finally {
          info.dispose();
          if (generation == _generation) _stopListening();
        }
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!mounted || generation != _generation) return;
        _stopListening();
        setState(() => _decodeFailed = true);
      },
    );
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    _generation++;
    _stopListening();
    super.dispose();
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } on Object {
      if (mounted) setState(() => _decodeFailed = true);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Widget _loading(Size box) => Container(
    key: Key('chat-image-loading-${widget.messageId}-${widget.index}'),
    width: box.width,
    height: box.height,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: const CircularProgressIndicator(strokeWidth: 2),
  );

  Widget _error(Size box) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final retry = IconButton(
      key: Key('chat-image-retry-${widget.messageId}-${widget.index}'),
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      visualDensity: VisualDensity.standard,
      onPressed: _retrying ? null : () => unawaited(_retry()),
      tooltip: '${strings.imageLoadFailed}. ${strings.retry}',
      icon: const Icon(Icons.refresh_rounded),
    );
    return Container(
      key: Key('chat-image-error-${widget.messageId}-${widget.index}'),
      width: box.width,
      height: box.height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: box.width < 200
          ? Center(child: retry)
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Icon(Icons.broken_image_outlined, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      strings.imageLoadFailed,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  retry,
                ],
              ),
            ),
    );
  }

  Widget _preview(Size box) {
    if (_retrying || widget.image.isLoading) return _loading(box);
    final image = _image;
    if (_decodeFailed || image == null) return _error(box);
    final strings = AppLocalizations.of(context);
    return Semantics(
      key: Key('chat-open-image-${widget.messageId}-${widget.index}'),
      image: true,
      button: widget.onOpen != null,
      label: '${strings.openImage}: ${widget.name}',
      onTap: widget.onOpen,
      explicitChildNodes: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onOpen,
            excludeFromSemantics: true,
            child: SizedBox(
              width: box.width,
              height: box.height,
              child: Image.memory(
                image.body,
                key: Key('chat-image-${widget.messageId}-${widget.index}'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                frameBuilder: (_, image, frame, synchronous) =>
                    _showAfterFirstImageFrame(
                      image: image,
                      frame: frame,
                      wasSynchronouslyLoaded: synchronous,
                      placeholder: _loading(box),
                    ),
                errorBuilder: (_, _, _) => _error(box),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preferred = _reservedImageBox(
      widget.parameter,
      decoded: _decodedSize,
    );
    return SizedBox(
      width: preferred.width,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final box = _reservedImageBox(
            widget.parameter,
            decoded: _decodedSize,
            maxWidth: constraints.maxWidth,
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _preview(box),
              const SizedBox(height: 4),
              Tooltip(
                message: widget.name,
                child: Text(
                  widget.name,
                  key: Key(
                    'chat-image-name-${widget.messageId}-${widget.index}',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
