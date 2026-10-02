part of 'chat_media_composer.dart';

extension _ChatMediaComposerPreviews on _ChatMediaComposerState {
  Widget _attachmentPreviews() => ListenableBuilder(
    listenable: Listenable.merge(_images.map((image) => image.controller)),
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
      return SizedBox(
        key: const Key('composer-attachment-previews'),
        height: prepared ? 100 : 240,
        child: ListView.separated(
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
      );
    },
  );
}
