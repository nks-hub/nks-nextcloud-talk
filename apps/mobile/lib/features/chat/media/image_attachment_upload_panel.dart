import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'image_attachment_upload_controller.dart';

final class ImageAttachmentPickerButton extends StatelessWidget {
  const ImageAttachmentPickerButton({
    super.key,
    required this.controller,
    required this.prepare,
    this.enabled = true,
  });

  final ImageAttachmentUploadController controller;
  final PrepareImageAttachment prepare;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => IconButton(
        key: const Key('pick-image-attachment'),
        tooltip: strings.attachImage,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: !enabled || controller.state.isActive
            ? null
            : () => controller.pickAndStart(prepare),
        icon: const Icon(Icons.add_photo_alternate_outlined),
      ),
    );
  }
}

final class ImageAttachmentUploadPanel extends StatelessWidget {
  const ImageAttachmentUploadPanel({
    super.key,
    required this.controller,
    this.previewBytes,
  });

  final ImageAttachmentUploadController controller;
  final Uint8List? previewBytes;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        if (state.phase == ImageAttachmentUploadPhase.idle ||
            state.phase == ImageAttachmentUploadPhase.preparing ||
            state.phase == ImageAttachmentUploadPhase.completed) {
          return const SizedBox.shrink();
        }
        return _UploadCard(
          state: state,
          previewBytes: previewBytes,
          onCancel: controller.cancel,
          onRetry: controller.retry,
          onDismiss: controller.dismiss,
        );
      },
    );
  }
}

final class _UploadCard extends StatelessWidget {
  const _UploadCard({
    required this.state,
    required this.previewBytes,
    required this.onCancel,
    required this.onRetry,
    required this.onDismiss,
  });

  final ImageAttachmentUploadState state;
  final Uint8List? previewBytes;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = _statusText(strings, state);
    final failed = state.phase == ImageAttachmentUploadPhase.failed;
    return Semantics(
      container: true,
      liveRegion: true,
      label: status,
      child: Card(
        key: const Key('image-attachment-upload-panel'),
        margin: EdgeInsets.zero,
        color: failed ? scheme.errorContainer : scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _UploadPreview(bytes: previewBytes, failed: failed),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.request?.source.displayName ??
                              strings.attachment,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: failed
                                    ? scheme.onErrorContainer
                                    : scheme.onSurface,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          status,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: failed
                                    ? scheme.onErrorContainer
                                    : scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (state.isActive) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  key: const Key('image-attachment-upload-progress'),
                  value: state.phase == ImageAttachmentUploadPhase.uploading
                      ? state.progress
                      : null,
                  semanticsLabel: status,
                  semanticsValue:
                      state.phase == ImageAttachmentUploadPhase.uploading
                      ? '${((state.progress ?? 0) * 100).round()}%'
                      : null,
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _actions(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    final strings = AppLocalizations.of(context);
    if (state.phase == ImageAttachmentUploadPhase.failed) {
      return [
        if (state.retryAllowed)
          FilledButton.icon(
            key: const Key('retry-image-attachment-upload'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(strings.retry),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
        IconButton(
          key: const Key('dismiss-image-attachment-upload'),
          tooltip: strings.close,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded),
        ),
      ];
    }
    if (state.phase == ImageAttachmentUploadPhase.completed ||
        state.phase == ImageAttachmentUploadPhase.cancelled) {
      return [
        IconButton(
          key: const Key('dismiss-image-attachment-upload'),
          tooltip: strings.close,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded),
        ),
      ];
    }
    return [
      TextButton.icon(
        key: const Key('cancel-image-attachment-upload'),
        onPressed: state.phase == ImageAttachmentUploadPhase.cancelling
            ? null
            : onCancel,
        icon: const Icon(Icons.close_rounded),
        label: Text(strings.cancel),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
    ];
  }
}

final class _UploadPreview extends StatelessWidget {
  const _UploadPreview({required this.bytes, required this.failed});

  final Uint8List? bytes;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      image: bytes != null,
      label: strings.imageAttachment,
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.square(
            dimension: 72,
            child: bytes == null
                ? ColoredBox(
                    color: failed
                        ? scheme.errorContainer
                        : scheme.surfaceContainerHighest,
                    child: Icon(
                      failed
                          ? Icons.broken_image_outlined
                          : Icons.image_outlined,
                      color: failed
                          ? scheme.onErrorContainer
                          : scheme.onSurfaceVariant,
                    ),
                  )
                : Image.memory(
                    bytes!,
                    cacheWidth: 192,
                    cacheHeight: 192,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

String _statusText(
  AppLocalizations strings,
  ImageAttachmentUploadState state,
) => switch (state.phase) {
  ImageAttachmentUploadPhase.idle => '',
  ImageAttachmentUploadPhase.preparing => strings.preparingImage,
  ImageAttachmentUploadPhase.queued => strings.imageUploadQueued,
  ImageAttachmentUploadPhase.uploading => strings.uploadingImage(
    ((state.progress ?? 0) * 100).round(),
  ),
  ImageAttachmentUploadPhase.awaitingConfirmation =>
    strings.confirmingAttachment,
  ImageAttachmentUploadPhase.cancelling => strings.cancellingUpload,
  ImageAttachmentUploadPhase.completed => strings.imageSent,
  ImageAttachmentUploadPhase.failed => switch (state.failureCode) {
    'dav-quota-exceeded' => strings.imageUploadFailedQuota,
    'dav-permission-denied' => strings.imageUploadFailedPermission,
    _ => strings.imageUploadFailed,
  },
  ImageAttachmentUploadPhase.cancelled => strings.uploadCancelled,
};
