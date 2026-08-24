import 'dart:async';

import 'package:talk_protocol/talk_protocol.dart';

import '../attachment_service.dart';
import '../media/image_attachment_upload_controller.dart';
import 'voice_message.dart';

typedef PrepareAttachmentEnqueueRequest =
    Future<AttachmentEnqueueRequest> Function({
      required AccountId accountId,
      required ConversationToken roomToken,
      required PreparedAttachmentSource source,
      required AttachmentMetadata metadata,
    });

typedef EnqueueDurableAttachment =
    Future<AttachmentSubmissionDurableSession> Function(
      AttachmentEnqueueRequest request,
    );

abstract interface class AttachmentSubmissionDurableSession {
  AccountId get accountId;

  AttachmentJobId get jobId;

  Stream<AttachmentJobProgress> get events;

  Future<void> cancel();

  Future<void> retry();
}

enum AttachmentSubmissionFailure { invalidBinding, unsupported }

final class AttachmentSubmissionException implements Exception {
  const AttachmentSubmissionException(this.failure);

  final AttachmentSubmissionFailure failure;

  @override
  String toString() => 'AttachmentSubmissionException(${failure.name})';
}

final class AttachmentSubmissionBridge implements VoiceAttachmentSubmitter {
  factory AttachmentSubmissionBridge({
    required AccountId accountId,
    required ServerBase server,
    required ConversationToken roomToken,
    required PrepareAttachmentEnqueueRequest prepare,
    required EnqueueDurableAttachment enqueue,
  }) => AttachmentSubmissionBridge._(
    accountId,
    server,
    roomToken,
    prepare,
    enqueue,
  );

  AttachmentSubmissionBridge._(
    this.accountId,
    this.server,
    this.roomToken,
    this._prepare,
    this._enqueue,
  );

  factory AttachmentSubmissionBridge.withService({
    required AccountId accountId,
    required ServerBase server,
    required ConversationToken roomToken,
    required PrepareAttachmentEnqueueRequest prepare,
    required AttachmentService service,
  }) => AttachmentSubmissionBridge(
    accountId: accountId,
    server: server,
    roomToken: roomToken,
    prepare: prepare,
    enqueue: (request) async =>
        _AttachmentServiceSession(await service.enqueue(request)),
  );

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final PrepareAttachmentEnqueueRequest _prepare;
  final EnqueueDurableAttachment _enqueue;
  final Map<_ImageSubmissionKey, _DurableImageBinding> _imageBindings = {};

  Future<ImageAttachmentUploadSession> startImageUpload(
    ImageAttachmentUploadRequest request,
  ) async {
    _validateImageRequest(request);
    final key = _imageKey(request);
    final existing = _imageBindings[key];
    if (existing != null) {
      final progress = existing.lastProgress;
      if (progress?.retryAllowed ?? false) {
        await existing.session.retry();
      }
      return _imageSession(key, existing);
    }

    final prepared = await _prepare(
      accountId: request.accountId,
      roomToken: request.roomToken,
      source: request.source,
      metadata: request.metadata,
    );
    _validatePreparedRequest(
      prepared,
      source: request.source,
      metadata: request.metadata,
    );
    final session = await _enqueue(prepared);
    await _validateDurableSession(session);
    final binding = _DurableImageBinding(session);
    _imageBindings[key] = binding;
    return _imageSession(key, binding);
  }

  @override
  Future<VoiceAttachmentAcceptance> submit(
    VoiceAttachmentSubmission submission,
  ) async {
    if (submission.duration <= Duration.zero ||
        submission.duration > const Duration(hours: 24) ||
        submission.metadata.kind != AttachmentMessageKind.voice) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
    final prepared = await _prepare(
      accountId: accountId,
      roomToken: roomToken,
      source: submission.source,
      metadata: submission.metadata,
    );
    _validatePreparedRequest(
      prepared,
      source: submission.source,
      metadata: submission.metadata,
    );
    final session = await _enqueue(prepared);
    await _validateDurableSession(session);
    return const VoiceAttachmentAcceptance(durablyAccepted: true);
  }

  ImageAttachmentUploadSession _imageSession(
    _ImageSubmissionKey key,
    _DurableImageBinding binding,
  ) {
    return ImageAttachmentUploadSession(
      events: _mapImageEvents(key, binding),
      cancel: () async {
        await binding.session.cancel();
        if (identical(_imageBindings[key], binding)) {
          _imageBindings.remove(key);
        }
      },
    );
  }

  Stream<ImageAttachmentUploadEvent> _mapImageEvents(
    _ImageSubmissionKey key,
    _DurableImageBinding binding,
  ) {
    late final StreamController<ImageAttachmentUploadEvent> controller;
    StreamSubscription<AttachmentJobProgress>? subscription;
    var finished = false;

    Future<void> stopSubscription() async {
      final active = subscription;
      subscription = null;
      if (active != null) {
        await active.cancel();
      }
    }

    void finish() {
      if (finished) {
        return;
      }
      finished = true;
      unawaited(stopSubscription());
      unawaited(controller.close());
    }

    void fail(String code, {required bool retryAllowed}) {
      if (finished) {
        return;
      }
      controller.add(
        ImageAttachmentUploadEvent.failed(code, retryAllowed: retryAllowed),
      );
      finish();
    }

    controller = StreamController<ImageAttachmentUploadEvent>(
      onListen: () {
        subscription = binding.session.events.listen(
          (progress) {
            if (finished) {
              return;
            }
            if (progress.accountId != accountId ||
                progress.jobId != binding.session.jobId) {
              if (identical(_imageBindings[key], binding)) {
                _imageBindings.remove(key);
              }
              fail('durable-scope-mismatch', retryAllowed: false);
              return;
            }
            binding.lastProgress = progress;
            final event = _mapImageProgress(progress);
            controller.add(event);
            if (progress.phase == AttachmentJobPhase.retryable ||
                progress.phase == AttachmentJobPhase.cleanupFailed) {
              finish();
              return;
            }
            if (progress.isTerminal) {
              if (identical(_imageBindings[key], binding)) {
                _imageBindings.remove(key);
              }
              finish();
            }
          },
          onError: (_) {
            fail('durable-event-stream-failed', retryAllowed: true);
          },
          onDone: () {
            if (finished) {
              return;
            }
            fail('durable-event-stream-ended', retryAllowed: true);
          },
          cancelOnError: true,
        );
      },
      onCancel: stopSubscription,
    );
    return controller.stream;
  }

  void _validateImageRequest(ImageAttachmentUploadRequest request) {
    if (request.accountId != accountId ||
        request.server != server ||
        request.roomToken != roomToken) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.invalidBinding,
      );
    }
    if (request.metadata.kind != AttachmentMessageKind.file ||
        !request.source.mimeType.startsWith('image/')) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
  }

  void _validatePreparedRequest(
    AttachmentEnqueueRequest request, {
    required PreparedAttachmentSource source,
    required AttachmentMetadata metadata,
  }) {
    if (request.accountId != accountId ||
        request.server != server ||
        request.roomToken != roomToken ||
        !_sameSource(request.source, source) ||
        !_sameMetadata(request.metadata, metadata)) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.invalidBinding,
      );
    }
    final chunkCount = request.policy.chunkCountFor(source.byteLength);
    if (!request.roomCanWrite ||
        !request.profile.supports(metadata) ||
        !metadata.supportsSource(source) ||
        (request.policy.modeFor(source.byteLength) ==
                AttachmentUploadMode.chunked &&
            chunkCount > attachmentMaximumChunkCount)) {
      throw const AttachmentSubmissionException(
        AttachmentSubmissionFailure.unsupported,
      );
    }
  }

  Future<void> _validateDurableSession(
    AttachmentSubmissionDurableSession session,
  ) async {
    if (session.accountId == accountId) {
      return;
    }
    try {
      await session.cancel();
    } on Object {
      // The binding error remains authoritative even if cleanup also fails.
    }
    throw const AttachmentSubmissionException(
      AttachmentSubmissionFailure.invalidBinding,
    );
  }
}

final class _AttachmentServiceSession
    implements AttachmentSubmissionDurableSession {
  const _AttachmentServiceSession(this._session);

  final DurableAttachmentSession _session;

  @override
  AccountId get accountId => _session.accountId;

  @override
  AttachmentJobId get jobId => _session.jobId;

  @override
  Stream<AttachmentJobProgress> get events => _session.events;

  @override
  Future<void> cancel() => _session.cancel();

  @override
  Future<void> retry() => _session.retry();
}

final class _DurableImageBinding {
  _DurableImageBinding(this.session);

  final AttachmentSubmissionDurableSession session;
  AttachmentJobProgress? lastProgress;
}

ImageAttachmentUploadEvent _mapImageProgress(AttachmentJobProgress progress) {
  return switch (progress.phase) {
    AttachmentJobPhase.localPrepared => ImageAttachmentUploadEvent.queued(),
    AttachmentJobPhase.probing ||
    AttachmentJobPhase.draftResolved ||
    AttachmentJobPhase.uploading ||
    AttachmentJobPhase.uploaded ||
    AttachmentJobPhase.finalizing ||
    AttachmentJobPhase.cancelling => ImageAttachmentUploadEvent.uploading(
      progress.progress.clamp(0.0, 1.0).toDouble(),
    ),
    AttachmentJobPhase.awaitingConfirmation =>
      ImageAttachmentUploadEvent.awaitingConfirmation(),
    AttachmentJobPhase.completed => ImageAttachmentUploadEvent.completed(),
    AttachmentJobPhase.retryable ||
    AttachmentJobPhase.failed ||
    AttachmentJobPhase.cleanupFailed => ImageAttachmentUploadEvent.failed(
      progress.errorClass ?? 'attachment-${progress.phase.name}',
      retryAllowed: progress.retryAllowed,
    ),
    AttachmentJobPhase.cancelled => ImageAttachmentUploadEvent.cancelled(),
  };
}

bool _sameSource(
  PreparedAttachmentSource left,
  PreparedAttachmentSource right,
) =>
    left.handle == right.handle &&
    left.ownership == right.ownership &&
    left.byteLength == right.byteLength &&
    left.sha256 == right.sha256 &&
    left.mimeType == right.mimeType &&
    left.displayName == right.displayName;

bool _sameMetadata(AttachmentMetadata left, AttachmentMetadata right) =>
    left.kind == right.kind &&
    left.caption == right.caption &&
    left.replyTo == right.replyTo &&
    left.threadId == right.threadId &&
    left.threadTitle == right.threadTitle &&
    left.silent == right.silent;

typedef _ImageSubmissionKey = ({
  String accountId,
  String server,
  String roomToken,
  String sourceHandle,
  String sourceHash,
  int sourceLength,
  String sourceMimeType,
  String sourceDisplayName,
  String metadataKind,
  String? caption,
  int? replyTo,
  int? threadId,
  String? threadTitle,
  bool silent,
});

_ImageSubmissionKey _imageKey(ImageAttachmentUploadRequest request) => (
  accountId: request.accountId.value,
  server: request.server.value,
  roomToken: request.roomToken.value,
  sourceHandle: request.source.handle.value,
  sourceHash: request.source.sha256.value,
  sourceLength: request.source.byteLength,
  sourceMimeType: request.source.mimeType,
  sourceDisplayName: request.source.displayName,
  metadataKind: request.metadata.kind.name,
  caption: request.metadata.caption,
  replyTo: request.metadata.replyTo,
  threadId: request.metadata.threadId,
  threadTitle: request.metadata.threadTitle,
  silent: request.metadata.silent,
);
