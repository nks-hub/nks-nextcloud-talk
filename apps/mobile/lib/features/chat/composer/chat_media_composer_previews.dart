part of 'chat_media_composer.dart';

extension _ChatMediaComposerPreviews on _ChatMediaComposerState {
  Widget _attachmentPreviews() => ListenableBuilder(
    listenable: Listenable.merge([
      _attachmentPreviewScroll,
      ..._images.map((image) => image.controller),
    ]),
    builder: (context, _) {
      final visible = _images
          .where(
            (image) =>
                !image.durablyAccepted &&
                image.controller.state.phase !=
                    ImageAttachmentUploadPhase.idle &&
                image.controller.state.phase !=
                    ImageAttachmentUploadPhase.cancelled &&
                image.controller.state.phase !=
                    ImageAttachmentUploadPhase.completed,
          )
          .toList();
      if (visible.isEmpty) return const SizedBox.shrink();
      final prepared = visible.every(
        (image) => image.controller.state.isPrepared,
      );
      final strings = AppLocalizations.of(context);
      final previews = SizedBox(
        key: const Key('composer-attachment-previews'),
        height: prepared ? 100 : 240,
        child: Scrollbar(
          controller: _attachmentPreviewScroll,
          thumbVisibility: true,
          trackVisibility: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: ListView.separated(
            controller: _attachmentPreviewScroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final image = visible[index];
              final request = image.controller.state.request;
              if (!image.controller.state.isPrepared || request == null) {
                return SizedBox(
                  width: visible.length == 1
                      ? (MediaQuery.sizeOf(context).width - 32).clamp(
                          220.0,
                          520.0,
                        )
                      : 280,
                  child: SingleChildScrollView(
                    child: ImageAttachmentUploadPanel(
                      controller: image.controller,
                      onOpenSettings: widget.openAppSettings == null
                          ? null
                          : () => unawaited(_openAppSettings()),
                    ),
                  ),
                );
              }
              return Container(
                width: 220,
                padding: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 56,
                      child: AttachmentSourceThumbnail(
                        source: request.source,
                        store: image.store,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        request.source.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      key: const Key('remove-prepared-attachment'),
                      tooltip: strings.remove,
                      onPressed: () => unawaited(image.controller.cancel()),
                      icon: const Icon(Icons.close_rounded),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      return NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.horizontal) {
            _updateAttachments(() {});
          }
          return false;
        },
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.attachmentBatchTitle(visible.length),
                      key: const Key('composer-attachment-count'),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (visible.length > 1) ...[
                    IconButton(
                      key: const Key('previous-prepared-attachments'),
                      tooltip: strings.previousAttachments,
                      onPressed:
                          _attachmentPreviewScroll.hasClients &&
                              _attachmentPreviewScroll.offset > 0
                          ? () => _scrollPreparedAttachments(-1)
                          : null,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    IconButton(
                      key: const Key('next-prepared-attachments'),
                      tooltip: strings.nextAttachments,
                      onPressed:
                          !_attachmentPreviewScroll.hasClients ||
                              !_attachmentPreviewScroll
                                  .position
                                  .hasContentDimensions ||
                              _attachmentPreviewScroll.offset <
                                  _attachmentPreviewScroll
                                      .position
                                      .maxScrollExtent
                          ? () => _scrollPreparedAttachments(1)
                          : null,
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                  ],
                ],
              ),
              previews,
            ],
          ),
        ),
      );
    },
  );

  void _scrollPreparedAttachments(int direction) {
    if (!_attachmentPreviewScroll.hasClients) return;
    final position = _attachmentPreviewScroll.position;
    unawaited(
      _attachmentPreviewScroll.animateTo(
        (position.pixels + direction * position.viewportDimension * 0.8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }
}
