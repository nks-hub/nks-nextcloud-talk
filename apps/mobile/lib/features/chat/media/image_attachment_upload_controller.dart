import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';

enum ImageAttachmentUploadPhase {
  idle,
  preparing,
  queued,
  uploading,
  awaitingConfirmation,
  cancelling,
  completed,
  failed,
  cancelled,
}

@immutable
final class ImageAttachmentUploadRequest {
  const ImageAttachmentUploadRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.source,
    required this.metadata,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final PreparedAttachmentSource source;
  final AttachmentMetadata metadata;

  @override
  String toString() => 'ImageAttachmentUploadRequest(<redacted>)';
}

@immutable
final class ImageAttachmentUploadEvent {
  ImageAttachmentUploadEvent._({
    required this.phase,
    required this.progress,
    required this.failureCode,
    required this.retryAllowed,
  }) {
    if (phase == ImageAttachmentUploadPhase.idle ||
        phase == ImageAttachmentUploadPhase.preparing ||
        phase == ImageAttachmentUploadPhase.cancelling) {
      throw ArgumentError.value(phase, 'phase', 'is controller-owned');
    }
    if (progress != null &&
        (progress!.isNaN || progress! < 0 || progress! > 1)) {
      throw ArgumentError.value(progress, 'progress', 'must be within 0..1');
    }
    if (phase == ImageAttachmentUploadPhase.uploading && progress == null) {
      throw ArgumentError.value(progress, 'progress', 'is required');
    }
    if (phase == ImageAttachmentUploadPhase.completed && progress != 1) {
      throw ArgumentError.value(progress, 'progress', 'must equal 1');
    }
    if ((phase == ImageAttachmentUploadPhase.failed) != (failureCode != null)) {
      throw ArgumentError.value(failureCode, 'failureCode');
    }
    if (failureCode != null && !_validFailureCode(failureCode!)) {
      throw ArgumentError.value(failureCode, 'failureCode');
    }
    if (phase != ImageAttachmentUploadPhase.failed && retryAllowed) {
      throw ArgumentError.value(retryAllowed, 'retryAllowed');
    }
  }

  factory ImageAttachmentUploadEvent.queued() => ImageAttachmentUploadEvent._(
    phase: ImageAttachmentUploadPhase.queued,
    progress: null,
    failureCode: null,
    retryAllowed: false,
  );

  factory ImageAttachmentUploadEvent.uploading(double progress) =>
      ImageAttachmentUploadEvent._(
        phase: ImageAttachmentUploadPhase.uploading,
        progress: progress,
        failureCode: null,
        retryAllowed: false,
      );

  factory ImageAttachmentUploadEvent.awaitingConfirmation() =>
      ImageAttachmentUploadEvent._(
        phase: ImageAttachmentUploadPhase.awaitingConfirmation,
        progress: 1,
        failureCode: null,
        retryAllowed: false,
      );

  factory ImageAttachmentUploadEvent.completed() =>
      ImageAttachmentUploadEvent._(
        phase: ImageAttachmentUploadPhase.completed,
        progress: 1,
        failureCode: null,
        retryAllowed: false,
      );

  factory ImageAttachmentUploadEvent.failed(
    String failureCode, {
    required bool retryAllowed,
  }) => ImageAttachmentUploadEvent._(
    phase: ImageAttachmentUploadPhase.failed,
    progress: null,
    failureCode: failureCode,
    retryAllowed: retryAllowed,
  );

  factory ImageAttachmentUploadEvent.cancelled() =>
      ImageAttachmentUploadEvent._(
        phase: ImageAttachmentUploadPhase.cancelled,
        progress: null,
        failureCode: null,
        retryAllowed: false,
      );

  final ImageAttachmentUploadPhase phase;
  final double? progress;
  final String? failureCode;
  final bool retryAllowed;
}

final class ImageAttachmentUploadSession {
  factory ImageAttachmentUploadSession({
    required Stream<ImageAttachmentUploadEvent> events,
    required Future<void> Function() cancel,
  }) => ImageAttachmentUploadSession._(events: events, cancel: cancel);

  const ImageAttachmentUploadSession._({
    required this.events,
    required this._cancel,
  });

  final Stream<ImageAttachmentUploadEvent> events;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

typedef StartImageAttachmentUpload =
    Future<ImageAttachmentUploadSession> Function(
      ImageAttachmentUploadRequest request,
    );

typedef PrepareImageAttachment =
    Future<ImageAttachmentUploadRequest?> Function();

/// Lets [ImageAttachmentUploadController.pickAndStart] report why picking a
/// source failed instead of collapsing every cause into one generic code.
/// Anything else thrown by the prepare callback stays generic.
final class ImageAttachmentPreparationFailure implements Exception {
  const ImageAttachmentPreparationFailure(this.code);

  final String code;

  @override
  String toString() => 'ImageAttachmentPreparationFailure($code)';
}

@immutable
final class ImageAttachmentUploadState {
  const ImageAttachmentUploadState._({
    required this.phase,
    required this.request,
    required this.progress,
    required this.failureCode,
    required this.retryAllowed,
  });

  const ImageAttachmentUploadState.idle()
    : this._(
        phase: ImageAttachmentUploadPhase.idle,
        request: null,
        progress: null,
        failureCode: null,
        retryAllowed: false,
      );

  factory ImageAttachmentUploadState.preparing() =>
      const ImageAttachmentUploadState._(
        phase: ImageAttachmentUploadPhase.preparing,
        request: null,
        progress: null,
        failureCode: null,
        retryAllowed: false,
      );

  factory ImageAttachmentUploadState.fromEvent(
    ImageAttachmentUploadRequest request,
    ImageAttachmentUploadEvent event,
  ) => ImageAttachmentUploadState._(
    phase: event.phase,
    request: request,
    progress: event.progress,
    failureCode: event.failureCode,
    retryAllowed: event.retryAllowed,
  );

  factory ImageAttachmentUploadState.queued(
    ImageAttachmentUploadRequest request,
  ) => ImageAttachmentUploadState._(
    phase: ImageAttachmentUploadPhase.queued,
    request: request,
    progress: null,
    failureCode: null,
    retryAllowed: false,
  );

  factory ImageAttachmentUploadState.cancelling(
    ImageAttachmentUploadRequest request,
  ) => ImageAttachmentUploadState._(
    phase: ImageAttachmentUploadPhase.cancelling,
    request: request,
    progress: null,
    failureCode: null,
    retryAllowed: false,
  );

  factory ImageAttachmentUploadState.failed(
    ImageAttachmentUploadRequest? request,
    String failureCode, {
    required bool retryAllowed,
  }) => ImageAttachmentUploadState._(
    phase: ImageAttachmentUploadPhase.failed,
    request: request,
    progress: null,
    failureCode: failureCode,
    retryAllowed: retryAllowed && request != null,
  );

  final ImageAttachmentUploadPhase phase;
  final ImageAttachmentUploadRequest? request;
  final double? progress;
  final String? failureCode;
  final bool retryAllowed;

  bool get isActive => switch (phase) {
    ImageAttachmentUploadPhase.preparing ||
    ImageAttachmentUploadPhase.queued ||
    ImageAttachmentUploadPhase.uploading ||
    ImageAttachmentUploadPhase.awaitingConfirmation ||
    ImageAttachmentUploadPhase.cancelling => true,
    _ => false,
  };

  bool get isTerminal => switch (phase) {
    ImageAttachmentUploadPhase.completed ||
    ImageAttachmentUploadPhase.failed ||
    ImageAttachmentUploadPhase.cancelled => true,
    _ => false,
  };
}

final class ImageAttachmentUploadController extends ChangeNotifier {
  factory ImageAttachmentUploadController({
    required StartImageAttachmentUpload startUpload,
  }) => ImageAttachmentUploadController._(startUpload);

  ImageAttachmentUploadController._(this._startUpload);

  final StartImageAttachmentUpload _startUpload;

  ImageAttachmentUploadState _state = const ImageAttachmentUploadState.idle();
  StreamSubscription<ImageAttachmentUploadEvent>? _subscription;
  ImageAttachmentUploadSession? _session;
  ImageAttachmentUploadRequest? _lastRequest;
  int _generation = 0;
  bool _cancelRequested = false;
  bool _disposed = false;

  ImageAttachmentUploadState get state => _state;

  Future<void> pickAndStart(PrepareImageAttachment prepare) async {
    if (_state.isActive || _disposed) {
      return;
    }
    final generation = ++_generation;
    _cancelRequested = false;
    await _detachSession();
    _setState(ImageAttachmentUploadState.preparing());

    final ImageAttachmentUploadRequest? request;
    try {
      request = await prepare();
    } on Object catch (error) {
      if (_isCurrent(generation)) {
        if (_cancelRequested) {
          _cancelRequested = false;
          _setState(const ImageAttachmentUploadState.idle());
        } else {
          _setState(
            ImageAttachmentUploadState.failed(
              null,
              error is ImageAttachmentPreparationFailure &&
                      _validFailureCode(error.code)
                  ? error.code
                  : 'source-preparation-failed',
              retryAllowed: false,
            ),
          );
        }
      }
      return;
    }
    if (!_isCurrent(generation)) {
      return;
    }
    if (request == null) {
      _cancelRequested = false;
      _setState(const ImageAttachmentUploadState.idle());
      return;
    }
    _lastRequest = request;
    if (_cancelRequested) {
      _cancelRequested = false;
      _setState(
        ImageAttachmentUploadState.fromEvent(
          request,
          ImageAttachmentUploadEvent.cancelled(),
        ),
      );
      return;
    }
    await _begin(request, generation);
  }

  Future<void> startPrepared(ImageAttachmentUploadRequest request) async {
    if (_state.isActive || _disposed) {
      return;
    }
    final generation = ++_generation;
    _cancelRequested = false;
    await _detachSession();
    _lastRequest = request;
    await _begin(request, generation);
  }

  Future<void> retry() async {
    final request = _lastRequest;
    if (_disposed ||
        _state.phase != ImageAttachmentUploadPhase.failed ||
        !_state.retryAllowed ||
        request == null) {
      return;
    }
    final generation = ++_generation;
    _cancelRequested = false;
    await _detachSession();
    await _begin(request, generation);
  }

  Future<void> cancel() async {
    if (!_state.isActive ||
        _state.phase == ImageAttachmentUploadPhase.cancelling ||
        _disposed) {
      return;
    }
    final generation = _generation;
    _cancelRequested = true;
    final request = _state.request ?? _lastRequest;
    if (request != null) {
      _setState(ImageAttachmentUploadState.cancelling(request));
    }
    final session = _session;
    if (session == null) {
      return;
    }
    await _cancelCurrentSession(session, request!, generation);
  }

  void dismiss() {
    if (!_state.isTerminal || _disposed) {
      return;
    }
    _generation++;
    _lastRequest = null;
    _session = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _setState(const ImageAttachmentUploadState.idle());
  }

  Future<void> _begin(
    ImageAttachmentUploadRequest request,
    int generation,
  ) async {
    _setState(ImageAttachmentUploadState.queued(request));
    final ImageAttachmentUploadSession session;
    try {
      session = await _startUpload(request);
    } on Object {
      if (_isCurrent(generation)) {
        if (_cancelRequested) {
          _cancelRequested = false;
          _setState(
            ImageAttachmentUploadState.fromEvent(
              request,
              ImageAttachmentUploadEvent.cancelled(),
            ),
          );
        } else {
          _setState(
            ImageAttachmentUploadState.failed(
              request,
              'dispatch-failed',
              retryAllowed: true,
            ),
          );
        }
      }
      return;
    }
    if (!_isCurrent(generation)) {
      if (_cancelRequested) {
        await _cancelSessionBestEffort(session);
      }
      return;
    }
    _session = session;
    if (_cancelRequested) {
      _setState(ImageAttachmentUploadState.cancelling(request));
      await _cancelCurrentSession(session, request, generation);
      return;
    }
    _subscription = session.events.listen(
      (event) => _handleEvent(generation, request, event),
      onError: (_) => _handleStreamFailure(generation, request),
      onDone: () => _handleStreamDone(generation, request),
      cancelOnError: true,
    );
  }

  void _handleEvent(
    int generation,
    ImageAttachmentUploadRequest request,
    ImageAttachmentUploadEvent event,
  ) {
    if (!_isCurrent(generation) || _cancelRequested) {
      return;
    }
    _setState(ImageAttachmentUploadState.fromEvent(request, event));
    if (_state.isTerminal) {
      unawaited(_subscription?.cancel());
      _subscription = null;
      _session = null;
    }
  }

  void _handleStreamFailure(
    int generation,
    ImageAttachmentUploadRequest request,
  ) {
    if (!_isCurrent(generation) || _cancelRequested) {
      return;
    }
    _session = null;
    _subscription = null;
    _setState(
      ImageAttachmentUploadState.failed(
        request,
        'event-stream-failed',
        retryAllowed: true,
      ),
    );
  }

  void _handleStreamDone(int generation, ImageAttachmentUploadRequest request) {
    if (!_isCurrent(generation) || _cancelRequested || _state.isTerminal) {
      return;
    }
    _session = null;
    _subscription = null;
    _setState(
      ImageAttachmentUploadState.failed(
        request,
        'event-stream-ended',
        retryAllowed: true,
      ),
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> _cancelCurrentSession(
    ImageAttachmentUploadSession session,
    ImageAttachmentUploadRequest request,
    int generation,
  ) async {
    Object? cancellationFailure;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } on Object catch (error) {
        cancellationFailure = error;
      }
    }
    try {
      await session.cancel();
    } on Object catch (error) {
      cancellationFailure ??= error;
    }
    if (identical(_session, session)) {
      _session = null;
    }
    if (!_isCurrent(generation) || !_cancelRequested) {
      return;
    }
    _cancelRequested = false;
    if (cancellationFailure == null) {
      _setState(
        ImageAttachmentUploadState.fromEvent(
          request,
          ImageAttachmentUploadEvent.cancelled(),
        ),
      );
    } else {
      _setState(
        ImageAttachmentUploadState.failed(
          request,
          'cancellation-failed',
          retryAllowed: false,
        ),
      );
    }
  }

  Future<void> _cancelSessionBestEffort(
    ImageAttachmentUploadSession session,
  ) async {
    try {
      await session.cancel();
    } on Object {
      // The explicit cancellation request remains authoritative even when the
      // controller no longer owns a state generation.
    }
  }

  Future<void> _detachSession() async {
    final subscription = _subscription;
    _subscription = null;
    _session = null;
    if (subscription != null) {
      await subscription.cancel();
    }
  }

  void _setState(ImageAttachmentUploadState value) {
    if (_disposed) {
      return;
    }
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    _session = null;
    unawaited(_releaseDetachedResources(subscription));
    super.dispose();
  }

  Future<void> _releaseDetachedResources(
    StreamSubscription<ImageAttachmentUploadEvent>? subscription,
  ) async {
    if (subscription != null) {
      try {
        await subscription.cancel();
      } on Object {
        // Disposed controllers cannot surface cleanup state.
      }
    }
  }
}

bool _validFailureCode(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    value.trim() == value &&
    !value.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f);
