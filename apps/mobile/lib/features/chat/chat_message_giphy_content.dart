part of 'chat_message_content.dart';

const _maximumGiphyReferencesPerMessage = 4;

final class ChatPendingGiphyReference extends ConsumerWidget {
  const ChatPendingGiphyReference({
    super.key,
    required this.account,
    required this.resourceUrl,
    required this.foregroundColor,
  });

  final StoredAccount account;
  final Uri resourceUrl;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isSupportedGiphyResource(resourceUrl)) {
      return _GiphyReferenceFailure(index: 0, foregroundColor: foregroundColor);
    }
    final request = GiphyReferenceRequest(
      accountId: account.id,
      resourceUrl: resourceUrl,
    );
    final provider = giphyReferenceMediaProvider(request);
    final media = ref.watch(provider);
    return media.when(
      data: (value) => value.resourceUrl == resourceUrl
          ? _GiphyReferenceImage(
              media: value,
              foregroundColor: foregroundColor,
              index: 0,
            )
          : _GiphyReferenceFailure(
              index: 0,
              foregroundColor: foregroundColor,
              onRetry: () => _retryGiphyReference(ref, account.id, resourceUrl),
            ),
      error: (error, _) {
        final unavailable = _isUnavailableGiphyError(error);
        return _GiphyReferenceFailure(
          index: 0,
          foregroundColor: foregroundColor,
          integrationUnavailable: unavailable,
          onRetry: unavailable
              ? null
              : () => _retryGiphyReference(ref, account.id, resourceUrl),
        );
      },
      loading: () => const _GiphyReferenceLoading(index: 0),
    );
  }
}

final class _GiphyRichDocument extends ConsumerWidget {
  const _GiphyRichDocument({
    required this.accountId,
    required this.document,
    required this.foregroundColor,
    required this.references,
    required this.hasOverflow,
  });

  final String accountId;
  final RichChatDocument document;
  final Color foregroundColor;
  final List<Uri> references;
  final bool hasOverflow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolutions = <AsyncValue<GiphyReferenceMedia>>[
      for (final resourceUrl in references)
        ref.watch(
          giphyReferenceMediaProvider(
            GiphyReferenceRequest(
              accountId: accountId,
              resourceUrl: resourceUrl,
            ),
          ),
        ),
    ];
    final hiddenLinks = references.toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RichDocument(
          document: document,
          foregroundColor: foregroundColor,
          hiddenLinks: hiddenLinks,
        ),
        for (var index = 0; index < references.length; index++)
          resolutions[index].when(
            data: (media) => media.resourceUrl == references[index]
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _GiphyReferenceImage(
                      media: media,
                      foregroundColor: foregroundColor,
                      index: index,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _GiphyReferenceFailure(
                      index: index,
                      foregroundColor: foregroundColor,
                      onRetry: () => _retryGiphyReference(
                        ref,
                        accountId,
                        references[index],
                      ),
                    ),
                  ),
            error: (error, _) {
              final unavailable = _isUnavailableGiphyError(error);
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _GiphyReferenceFailure(
                  index: index,
                  foregroundColor: foregroundColor,
                  integrationUnavailable: unavailable,
                  onRetry: unavailable
                      ? null
                      : () => _retryGiphyReference(
                          ref,
                          accountId,
                          references[index],
                        ),
                ),
              );
            },
            loading: () => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _GiphyReferenceLoading(index: index),
            ),
          ),
        if (hasOverflow)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _GiphyReferenceFailure(
              index: _maximumGiphyReferencesPerMessage,
              foregroundColor: foregroundColor,
            ),
          ),
      ],
    );
  }
}

void _retryGiphyReference(WidgetRef ref, String accountId, Uri resourceUrl) {
  ref.invalidate(giphyRepositoryProvider(accountId));
  ref.invalidate(
    giphyReferenceMediaProvider(
      GiphyReferenceRequest(accountId: accountId, resourceUrl: resourceUrl),
    ),
  );
}

bool _isUnavailableGiphyError(Object error) =>
    error is GiphyException && error.error == GiphyError.integrationUnavailable;

final class _GiphyReferenceLoading extends StatelessWidget {
  const _GiphyReferenceLoading({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: Key('chat-giphy-reference-loading-$index'),
      width: 48,
      height: 48,
      child: const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

/// Longest side a Giphy is ever drawn at inside a bubble.
const double _giphyMaximumExtent = 360;

final class _GiphyReferenceImage extends StatelessWidget {
  const _GiphyReferenceImage({
    required this.media,
    required this.foregroundColor,
    required this.index,
  });

  final GiphyReferenceMedia media;
  final Color foregroundColor;
  final int index;

  @override
  Widget build(BuildContext context) {
    final rawAspectRatio = media.aspectRatio;
    final aspectRatio = rawAspectRatio == null || !rawAspectRatio.isFinite
        ? 4 / 3
        : rawAspectRatio.clamp(0.1, 10.0).toDouble();
    // Every frame of an animation is decoded, so the decode size is paid over
    // and over rather than once. 1080 was right only on a 3x screen; asking
    // for the box the bubble actually gives it means a 2x phone stops
    // decoding half again as many pixels per frame, and a denser screen stops
    // getting a picture softer than it could be.
    final decodeWidth =
        (_giphyMaximumExtent * MediaQuery.devicePixelRatioOf(context)).round();
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: _giphyMaximumExtent,
        maxHeight: _giphyMaximumExtent,
      ),
      child: AspectRatio(
        key: Key('chat-giphy-reference-media-$index'),
        aspectRatio: aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            media.body,
            fit: BoxFit.contain,
            cacheWidth: decodeWidth,
            gaplessPlayback: true,
            frameBuilder: (_, image, frame, wasSynchronouslyLoaded) =>
                _showAfterFirstImageFrame(
                  image: image,
                  frame: frame,
                  wasSynchronouslyLoaded: wasSynchronouslyLoaded,
                  placeholder: _GiphyReferenceLoading(index: index),
                ),
            errorBuilder: (_, _, _) => _GiphyReferenceFailure(
              index: index,
              foregroundColor: foregroundColor,
            ),
          ),
        ),
      ),
    );
  }
}

final class _GiphyReferenceFailure extends StatelessWidget {
  const _GiphyReferenceFailure({
    required this.index,
    required this.foregroundColor,
    this.integrationUnavailable = false,
    this.onRetry,
  });

  final int index;
  final Color foregroundColor;
  final bool integrationUnavailable;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Row(
      key: Key('chat-giphy-reference-error-$index'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          integrationUnavailable
              ? Icons.gif_box_outlined
              : Icons.broken_image_outlined,
          size: 18,
          color: foregroundColor,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            integrationUnavailable
                ? strings.giphyUnavailable
                : strings.imageLoadFailed,
            style: TextStyle(color: foregroundColor),
          ),
        ),
        if (onRetry != null)
          IconButton(
            key: Key('chat-giphy-reference-retry-$index'),
            onPressed: onRetry,
            tooltip: strings.retry,
            color: foregroundColor,
            icon: const Icon(Icons.refresh_rounded),
          ),
      ],
    );
  }
}

({List<Uri> references, bool hasOverflow}) _giphyReferences(
  RichChatDocument document,
) {
  final references = <Uri>[];
  final seen = <Uri>{};
  for (final node in document.nodes) {
    if (node.kind != RichChatSemanticKind.link || node.link == null) {
      continue;
    }
    final resourceUrl = Uri.tryParse(node.link!);
    if (resourceUrl == null ||
        !isSupportedGiphyResource(resourceUrl) ||
        !seen.add(resourceUrl)) {
      continue;
    }
    if (references.length == _maximumGiphyReferencesPerMessage) {
      return (
        references: List<Uri>.unmodifiable(references),
        hasOverflow: true,
      );
    }
    references.add(resourceUrl);
  }
  return (references: List<Uri>.unmodifiable(references), hasOverflow: false);
}
