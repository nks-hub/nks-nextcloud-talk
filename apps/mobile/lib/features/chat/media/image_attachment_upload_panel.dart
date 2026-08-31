import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../platform/media/image_attachment_picker.dart';
import 'image_attachment_upload_controller.dart';
import 'proportional_image.dart';

typedef PrepareAttachmentFromSource =
    Future<ImageAttachmentUploadRequest?> Function(
      AttachmentPickerSource source,
    );

final class AttachmentMenuAction {
  const AttachmentMenuAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final Key key;
  final Widget icon;
  final String label;
  final VoidCallback? onSelected;
}

final class ComposerActionMenuButton extends StatelessWidget {
  const ComposerActionMenuButton({super.key, required this.actions});

  final List<AttachmentMenuAction> actions;

  @override
  Widget build(BuildContext context) {
    final enabled = actions.any((action) => action.onSelected != null);
    return IconButton(
      key: const Key('pick-image-attachment'),
      tooltip: AppLocalizations.of(context).addAttachment,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: enabled ? () => unawaited(_open(context)) : null,
      icon: const Icon(Icons.attach_file_rounded),
    );
  }

  Future<void> _open(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          key: const Key('attachment-source-sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              ListTile(
                key: action.key,
                leading: action.icon,
                title: Text(action.label),
                enabled: action.onSelected != null,
                onTap: action.onSelected == null
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        action.onSelected!.call();
                      },
              ),
          ],
        ),
      ),
    );
  }
}

final class ImageAttachmentPickerButton extends StatelessWidget {
  const ImageAttachmentPickerButton({
    super.key,
    required this.controller,
    required this.prepare,
    this.enabled = true,
  });

  final ImageAttachmentUploadController controller;
  final PrepareAttachmentFromSource prepare;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => IconButton(
        key: const Key('pick-image-attachment'),
        tooltip: strings.addAttachment,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: !enabled || controller.state.isActive
            ? null
            : () => unawaited(_chooseSource(context)),
        icon: const Icon(Icons.attach_file_rounded),
      ),
    );
  }

  Future<void> _chooseSource(BuildContext context) async {
    final source = await showModalBottomSheet<AttachmentPickerSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          key: const Key('attachment-source-sheet'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final option in _options(AppLocalizations.of(sheetContext)))
              ListTile(
                key: Key('attach-source-${option.source.name}'),
                leading: Icon(option.icon),
                title: Text(option.label),
                enabled: enabled,
                onTap: enabled
                    ? () => Navigator.of(sheetContext).pop(option.source)
                    : null,
              ),
          ],
        ),
      ),
    );
    if (source == null || controller.state.isActive) {
      return;
    }
    await controller.pickAndStart(() => prepare(source));
  }

  List<_SourceOption> _options(AppLocalizations strings) => <_SourceOption>[
    (
      source: AttachmentPickerSource.gallery,
      icon: Icons.image_outlined,
      label: strings.attachFromGallery,
    ),
    (
      source: AttachmentPickerSource.camera,
      icon: Icons.photo_camera_outlined,
      label: strings.attachFromCamera,
    ),
    (
      source: AttachmentPickerSource.file,
      icon: Icons.insert_drive_file_outlined,
      label: strings.attachFromFile,
    ),
  ];
}

typedef _SourceOption = ({
  AttachmentPickerSource source,
  IconData icon,
  String label,
});

final class ImageAttachmentUploadPanel extends StatelessWidget {
  const ImageAttachmentUploadPanel({
    super.key,
    required this.controller,
    this.previewBytes,
    this.onOpenSettings,
  });

  final ImageAttachmentUploadController controller;
  final Uint8List? previewBytes;
  final VoidCallback? onOpenSettings;

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
          onOpenSettings: onOpenSettings,
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
    required this.onOpenSettings,
  });

  final ImageAttachmentUploadState state;
  final Uint8List? previewBytes;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;
  final VoidCallback? onOpenSettings;

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
      final permissionDenied =
          state.failureCode == 'gallery-permission-denied' ||
          state.failureCode == 'camera-permission-denied';
      return [
        if (permissionDenied && onOpenSettings != null)
          TextButton.icon(
            key: const Key('open-attachment-app-settings'),
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
            label: Text(strings.openAppSettings),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
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
                // Same reason as the composer thumbnail: what is shown
                // before sending must match what is sent.
                : proportionalMemoryImage(
                    bytes: bytes!,
                    maxEdge: 192,
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
    'gallery-permission-denied' => strings.attachmentGalleryDenied,
    'gallery-unavailable' => strings.attachmentGalleryUnavailable,
    'camera-permission-denied' => strings.attachmentCameraDenied,
    'camera-unavailable' => strings.attachmentCameraUnavailable,
    'unsupported-attachment-type' => strings.attachmentTypeUnsupported,
    _ => strings.imageUploadFailed,
  },
  ImageAttachmentUploadPhase.cancelled => strings.uploadCancelled,
};
