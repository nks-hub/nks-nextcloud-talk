part of 'chat_media_composer.dart';

final class _ComposerAttachment {
  _ComposerAttachment(this.store);

  final DurableAttachmentSourceStore store;
  late final ImageAttachmentUploadController controller;
  AttachmentSubmissionBridge? bridge;
  AttachmentCancellationController? cancellation;
  PreparedAttachmentSource? source;
  bool preparing = false;
  bool admissionPending = false;
  bool durablyAccepted = false;
  bool discardAfterAdmission = false;
  bool disposed = false;

  void discard() {
    final prepared = source;
    if (prepared != null && admissionPending) {
      discardAfterAdmission = true;
      return;
    }
    source = null;
    if (prepared != null) {
      unawaited(store.discard(prepared.handle));
    }
  }

  void dispose() {
    disposed = true;
    cancellation?.cancel();
    controller.dispose();
    bridge = null;
    discard();
  }
}

extension _ChatMediaComposerPending on _ChatMediaComposerState {
  _ComposerAttachment _createImageAttachment() {
    final image = _ComposerAttachment(widget.sourceStore);
    image.controller = ImageAttachmentUploadController(
      startUpload: (request) => _startImageUpload(image, request),
    )..addListener(() => _handleImageState(image));
    _images.add(image);
    return image;
  }

  void _handleImageState(_ComposerAttachment image) {
    final state = image.controller.state;
    if (image.durablyAccepted && !state.isActive) {
      scheduleMicrotask(() {
        if (_disposed || image.disposed) return;
        _updateAttachments(() => _images.remove(image));
        image.dispose();
      });
    }
    if (!state.isActive &&
        !(state.phase == ImageAttachmentUploadPhase.failed &&
            state.retryAllowed)) {
      image.bridge = null;
    }
    if (state.phase == ImageAttachmentUploadPhase.cancelling) {
      image.cancellation?.cancel();
    }
    if (state.phase == ImageAttachmentUploadPhase.cancelled ||
        state.phase == ImageAttachmentUploadPhase.idle) {
      image.discard();
    }
  }

  Future<bool> _attachFiles(List<String> paths) async {
    final scope = _image;
    if (paths.isEmpty) return false;
    for (final path in paths) {
      if (!identical(scope, _image) ||
          !await _submitDroppedAttachment(DropItemFile(path))) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _sendPreparedAttachment() async {
    if (_disposed || _sendingAttachments) {
      return false;
    }
    final admission = _captureAdmission(AttachmentMessageKind.file);
    final pending = _images
        .where((image) => image.controller.state.isPrepared)
        .toList();
    if (admission == null || pending.isEmpty) {
      return false;
    }
    _sendingAttachments = true;
    final silenceRemaining = widget.capabilityProfile.silent;
    final albums = <_ComposerAttachment, ChatPhotoAlbumReference>{};
    for (var start = 0; start < pending.length;) {
      var end = start;
      while (end < pending.length &&
          pending[end].source?.mimeType.startsWith('image/') == true &&
          end - start < 9999) {
        end++;
      }
      final count = end - start;
      if (count > 1) {
        final id = const Uuid().v4().replaceAll('-', '');
        for (var index = start; index < end; index++) {
          albums[pending[index]] = ChatPhotoAlbumReference(
            albumId: id,
            index: index - start,
            count: count,
          );
        }
      }
      start = end > start ? end : start + 1;
    }
    var includeCaption = true;
    try {
      for (final image in pending) {
        if (_disposed || image.disposed || !_imageSupported) {
          break;
        }
        final metadata = admission.metadata;
        await image.controller.sendPrepared(
          refresh: (held) => ImageAttachmentUploadRequest(
            accountId: admission.accountId,
            server: admission.server,
            roomToken: admission.roomToken,
            source: held.source,
            metadata: AttachmentMetadata(
              kind: metadata.kind,
              photoAlbum: albums[image],
              caption: includeCaption ? metadata.caption : null,
              replyTo: metadata.replyTo,
              threadId: metadata.threadId,
              silent: metadata.silent || (!includeCaption && silenceRemaining),
            ),
            presentation: held.presentation,
            diagnosticSource: held.diagnosticSource,
          ),
        );
        // A failed admission keeps its caption for retry as well.
        includeCaption = false;
      }
    } finally {
      _sendingAttachments = false;
    }
    return true;
  }
}
