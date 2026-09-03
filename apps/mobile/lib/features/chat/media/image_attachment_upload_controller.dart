import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nextcloudtalk/core/attachment_upload_telemetry.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/chat_attachment_context.dart';
import 'package:talk_protocol/talk_protocol.dart';

typedef CreateImageUploadWatchdogTimer =
    Timer Function(Duration delay, void Function() callback);

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

enum AttachmentUploadPresentation { image, file, contact }

@immutable
final class ImageAttachmentUploadRequest {
  const ImageAttachmentUploadRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.source,
    required this.metadata,
    this.presentation = AttachmentUploadPresentation.image,
    this.diagnosticSource = AttachmentUploadSource.unknown,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final PreparedAttachmentSource source;
  final AttachmentMetadata metadata;
  final AttachmentUploadPresentation presentation;
  final AttachmentUploadSource diagnosticSource;

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
    required this.durablePhase,
    required this.resumePhase,
    required this.attemptCount,
    required this.automaticRetryCount,
    required this.retryScheduled,
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

  factory ImageAttachmentUploadEvent.queued({
    AttachmentJobPhase? durablePhase,
    AttachmentJobPhase? resumePhase,
    int attemptCount = 0,
    int automaticRetryCount = 0,
    bool retryScheduled = false,
  }) => ImageAttachmentUploadEvent._(
    phase: ImageAttachmentUploadPhase.queued,
    progress: null,
    failureCode: null,
    retryAllowed: false,
    durablePhase: durablePhase,
    resumePhase: resumePhase,
    attemptCount: attemptCount,
    automaticRetryCount: automaticRetryCount,
    retryScheduled: retryScheduled,
  );

  factory ImageAttachmentUploadEvent.uploading(
    double progress, {
    AttachmentJobPhase? durablePhase,
    AttachmentJobPhase? resumePhase,
    int attemptCount = 0,
    int automaticRetryCount = 0,
    bool retryScheduled = false,
  }) => ImageAttachmentUploadEvent._(
    phase: ImageAttachmentUploadPhase.uploading,
    progress: progress,
    failureCode: null,
    retryAllowed: false,
    durablePhase: durablePhase,
    resumePhase: resumePhase,
    attemptCount: attemptCount,
    automaticRetryCount: automaticRetryCount,
    retryScheduled: retryScheduled,
  );

  factory ImageAttachmentUploadEvent.awaitingConfirmation({
    AttachmentJobPhase? durablePhase,
    AttachmentJobPhase? resumePhase,
    int attemptCount = 0,
    int automaticRetryCount = 0,
    bool retryScheduled = false,
  }) => ImageAttachmentUploadEvent._(
    phase: ImageAttachmentUploadPhase.awaitingConfirmation,
    progress: 1,
    failureCode: null,
    retryAllowed: false,
    durablePhase: durablePhase,
    resumePhase: resumePhase,
    attemptCount: attemptCount,
    automaticRetryCount: automaticRetryCount,
    retryScheduled: retryScheduled,
  );

  factory ImageAttachmentUploadEvent.completed({
    AttachmentJobPhase? durablePhase,
    AttachmentJobPhase? resumePhase,
    int attemptCount = 0,
    int automaticRetryCount = 0,
    bool retryScheduled = false,
  }) => ImageAttachmentUploadEvent._(
    phase: ImageAttachmentUploadPhase.completed,
    progress: 1,
    failureCode: null,
    retryAllowed: false,
    durablePhase: durablePhase,
    resumePhase: resumePhase,
    attemptCount: attemptCount,
    automaticRetryCount: automaticRetryCount,
    retryScheduled: retryScheduled,
  );

  factory ImageAttachmentUploadEvent.failed(
    String failureCode, {
    required bool retryAllowed,
    AttachmentJobPhase? durablePhase,
    AttachmentJobPhase? resumePhase,
    int attemptCount = 0,
    int automaticRetryCount = 0,
    bool retryScheduled = false,
  }) => ImageAttachmentUploadEvent._(
    phase: ImageAttachmentUploadPhase.failed,
    progress: null,
    failureCode: failureCode,
    retryAllowed: retryAllowed,
    durablePhase: durablePhase,
    resumePhase: resumePhase,
    attemptCount: attemptCount,
    automaticRetryCount: automaticRetryCount,
    retryScheduled: retryScheduled,
  );

  factory ImageAttachmentUploadEvent.cancelled({
    AttachmentJobPhase? durablePhase,
    AttachmentJobPhase? resumePhase,
    int attemptCount = 0,
    int automaticRetryCount = 0,
    bool retryScheduled = false,
  }) => ImageAttachmentUploadEvent._(
    phase: ImageAttachmentUploadPhase.cancelled,
    progress: null,
    failureCode: null,
    retryAllowed: false,
    durablePhase: durablePhase,
    resumePhase: resumePhase,
    attemptCount: attemptCount,
    automaticRetryCount: automaticRetryCount,
    retryScheduled: retryScheduled,
  );

  final ImageAttachmentUploadPhase phase;
  final double? progress;
  final String? failureCode;
  final bool retryAllowed;
  final AttachmentJobPhase? durablePhase;
  final AttachmentJobPhase? resumePhase;
  final int attemptCount;
  final int automaticRetryCount;
  final bool retryScheduled;
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
    ReportAttachmentUploadDiagnostic reportDiagnostic =
        reportAttachmentUploadDiagnostic,
    Duration queuedWatchdogTimeout = const Duration(seconds: 45),
    CreateImageUploadWatchdogTimer? createWatchdogTimer,
    DateTime Function()? clock,
  }) {
    if (queuedWatchdogTimeout <= Duration.zero) {
      throw ArgumentError.value(queuedWatchdogTimeout, 'queuedWatchdogTimeout');
    }
    return ImageAttachmentUploadController._(
      startUpload,
      reportDiagnostic,
      queuedWatchdogTimeout,
      createWatchdogTimer ?? Timer.new,
      clock ?? DateTime.now,
    );
  }

  ImageAttachmentUploadController._(
    this._startUpload,
    this._reportDiagnostic,
    this._queuedWatchdogTimeout,
    this._createWatchdogTimer,
    this._clock,
  );

  final StartImageAttachmentUpload _startUpload;
  final ReportAttachmentUploadDiagnostic _reportDiagnostic;
  final Duration _queuedWatchdogTimeout;
  final CreateImageUploadWatchdogTimer _createWatchdogTimer;
  final DateTime Function() _clock;

  ImageAttachmentUploadState _state = const ImageAttachmentUploadState.idle();
  StreamSubscription<ImageAttachmentUploadEvent>? _subscription;
  ImageAttachmentUploadSession? _session;
  ImageAttachmentUploadRequest? _lastRequest;
  int _generation = 0;
  bool _cancelRequested = false;
  bool _disposed = false;
  bool _sessionBound = false;
  Timer? _queuedWatchdog;
  DateTime? _queuedSince;
  AttachmentJobPhase? _durablePhase;
  AttachmentJobPhase? _resumePhase;
  int _attemptCount = 0;
  int _automaticRetryCount = 0;
  bool _retryScheduled = false;

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
    _sessionBound = false;
    _durablePhase = null;
    _resumePhase = null;
    _attemptCount = 0;
    _automaticRetryCount = 0;
    _retryScheduled = false;
    _reportDiagnostic(
      AttachmentUploadDiagnostic(
        checkpoint: AttachmentUploadCheckpoint.admissionStarted,
        source: _diagnosticSource(request),
        uiPhase: AttachmentUploadUiPhase.queued,
      ),
    );
    _setState(ImageAttachmentUploadState.queued(request));
    final ImageAttachmentUploadSession session;
    try {
      session = await _startUploadWithAdmissionRetry(request, generation);
    } on Object catch (error) {
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
          _reportDiagnostic(
            AttachmentUploadDiagnostic(
              checkpoint: AttachmentUploadCheckpoint.admissionFailed,
              source: _diagnosticSource(request),
              uiPhase: AttachmentUploadUiPhase.queued,
              failure: _classifyAdmissionFailure(error),
            ),
          );
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
    _sessionBound = true;
    _reportDiagnostic(
      AttachmentUploadDiagnostic(
        checkpoint: AttachmentUploadCheckpoint.admissionCompleted,
        source: _diagnosticSource(request),
        uiPhase: AttachmentUploadUiPhase.queued,
        sessionBound: true,
      ),
    );
    _session = session;
    if (_cancelRequested) {
      _setState(ImageAttachmentUploadState.cancelling(request));
      await _cancelCurrentSession(session, request, generation);
      return;
    }
    _armQueuedWatchdog(request);
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
    _durablePhase = event.durablePhase;
    _resumePhase = event.resumePhase;
    _attemptCount = event.attemptCount;
    _automaticRetryCount = event.automaticRetryCount;
    _retryScheduled = event.retryScheduled;
    final diagnostic = _diagnosticForEvent(request, event);
    _reportDiagnostic(diagnostic);
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
    _reportStreamFailure(request);
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
    _reportStreamFailure(request);
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
    if (value.phase == ImageAttachmentUploadPhase.queued) {
      _armQueuedWatchdog(value.request!);
    } else {
      _cancelQueuedWatchdog();
    }
    notifyListeners();
  }

  void _armQueuedWatchdog(ImageAttachmentUploadRequest request) {
    _queuedWatchdog?.cancel();
    _queuedSince ??= _clock().toUtc();
    final generation = _generation;
    _queuedWatchdog = _createWatchdogTimer(_queuedWatchdogTimeout, () {
      _queuedWatchdog = null;
      if (!_isCurrent(generation) ||
          _state.phase != ImageAttachmentUploadPhase.queued) {
        return;
      }
      _reportDiagnostic(
        AttachmentUploadDiagnostic(
          checkpoint: AttachmentUploadCheckpoint.stalled,
          source: _diagnosticSource(request),
          uiPhase: AttachmentUploadUiPhase.queued,
          durablePhase: attachmentUploadDurablePhase(_durablePhase),
          resumePhase: attachmentUploadDurablePhase(_resumePhase),
          failure: AttachmentUploadFailure.unknown,
          sessionBound: _sessionBound,
          retryScheduled: _retryScheduled,
          attemptCount: _attemptCount,
          automaticRetryCount: _automaticRetryCount,
          elapsed: _clock().toUtc().difference(_queuedSince!),
        ),
      );
    });
  }

  void _cancelQueuedWatchdog() {
    _queuedWatchdog?.cancel();
    _queuedWatchdog = null;
    _queuedSince = null;
  }

  void _reportStreamFailure(ImageAttachmentUploadRequest request) {
    _reportDiagnostic(
      AttachmentUploadDiagnostic(
        checkpoint: AttachmentUploadCheckpoint.streamFailed,
        source: _diagnosticSource(request),
        uiPhase: _diagnosticUiPhase(_state.phase),
        durablePhase: attachmentUploadDurablePhase(_durablePhase),
        resumePhase: attachmentUploadDurablePhase(_resumePhase),
        failure: AttachmentUploadFailure.stream,
        sessionBound: _sessionBound,
        retryScheduled: _retryScheduled,
        attemptCount: _attemptCount,
        automaticRetryCount: _automaticRetryCount,
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelQueuedWatchdog();
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

AttachmentUploadDiagnostic _diagnosticForEvent(
  ImageAttachmentUploadRequest request,
  ImageAttachmentUploadEvent event,
) => AttachmentUploadDiagnostic(
  checkpoint: switch (event.phase) {
    ImageAttachmentUploadPhase.completed =>
      AttachmentUploadCheckpoint.completed,
    ImageAttachmentUploadPhase.cancelled =>
      AttachmentUploadCheckpoint.cancelled,
    ImageAttachmentUploadPhase.failed =>
      AttachmentUploadCheckpoint.durableFailed,
    _ => AttachmentUploadCheckpoint.durableProgress,
  },
  source: _diagnosticSource(request),
  uiPhase: _diagnosticUiPhase(event.phase),
  durablePhase: attachmentUploadDurablePhase(event.durablePhase),
  resumePhase: attachmentUploadDurablePhase(event.resumePhase),
  failure: _diagnosticFailure(event.failureCode),
  progress: _progressBucket(event.progress),
  sessionBound: true,
  retryScheduled: event.retryScheduled,
  attemptCount: event.attemptCount,
  automaticRetryCount: event.automaticRetryCount,
);

AttachmentUploadSource _diagnosticSource(ImageAttachmentUploadRequest request) {
  if (request.diagnosticSource != AttachmentUploadSource.unknown) {
    return request.diagnosticSource;
  }
  return switch (request.presentation) {
    AttachmentUploadPresentation.image => AttachmentUploadSource.image,
    AttachmentUploadPresentation.file => AttachmentUploadSource.file,
    AttachmentUploadPresentation.contact => AttachmentUploadSource.contact,
  };
}

AttachmentUploadUiPhase _diagnosticUiPhase(ImageAttachmentUploadPhase phase) =>
    switch (phase) {
      ImageAttachmentUploadPhase.idle => AttachmentUploadUiPhase.none,
      ImageAttachmentUploadPhase.preparing => AttachmentUploadUiPhase.preparing,
      ImageAttachmentUploadPhase.queued => AttachmentUploadUiPhase.queued,
      ImageAttachmentUploadPhase.uploading => AttachmentUploadUiPhase.uploading,
      ImageAttachmentUploadPhase.awaitingConfirmation =>
        AttachmentUploadUiPhase.awaitingConfirmation,
      ImageAttachmentUploadPhase.cancelling =>
        AttachmentUploadUiPhase.cancelling,
      ImageAttachmentUploadPhase.completed => AttachmentUploadUiPhase.completed,
      ImageAttachmentUploadPhase.failed => AttachmentUploadUiPhase.failed,
      ImageAttachmentUploadPhase.cancelled => AttachmentUploadUiPhase.cancelled,
    };

AttachmentUploadFailure _diagnosticFailure(String? code) {
  if (code == null) {
    return AttachmentUploadFailure.none;
  }
  if (code.contains('permission')) {
    return AttachmentUploadFailure.permission;
  }
  if (code.contains('unavailable')) {
    return AttachmentUploadFailure.unavailable;
  }
  if (code.contains('unsupported') || code.contains('invalid')) {
    return AttachmentUploadFailure.invalidSelection;
  }
  if (code.contains('confirmation')) {
    return AttachmentUploadFailure.confirmation;
  }
  if (code.contains('reauthentication') || code.contains('credential')) {
    return AttachmentUploadFailure.credential;
  }
  if (code.contains('dispatch')) {
    return AttachmentUploadFailure.dispatch;
  }
  if (code.contains('stream')) {
    return AttachmentUploadFailure.stream;
  }
  return AttachmentUploadFailure.durable;
}

AttachmentUploadProgressBucket _progressBucket(double? progress) =>
    switch (progress) {
      null => AttachmentUploadProgressBucket.none,
      <= 0 => AttachmentUploadProgressBucket.zero,
      >= 1 => AttachmentUploadProgressBucket.complete,
      _ => AttachmentUploadProgressBucket.partial,
    };

/// Admission fetches a fresh capability snapshot, and on a slow network that
/// fetch is the first thing to time out. Failing the whole upload on it made
/// a gallery pick die instantly on a throttled emulator (and, by the same
/// class, in the field) although the upload itself would have gone through.
/// Two more attempts, spaced out, cover a slow server; a switched room or a
/// cancelled pick is not retried.
const _admissionRetryDelays = <Duration>[
  Duration(seconds: 3),
  Duration(seconds: 8),
];

extension on ImageAttachmentUploadController {
  Future<ImageAttachmentUploadSession> _startUploadWithAdmissionRetry(
    ImageAttachmentUploadRequest request,
    int generation,
  ) async {
    for (final delay in _admissionRetryDelays) {
      try {
        return await _startUpload(request);
      } on ChatAttachmentContextException catch (error) {
        if (error.code != ChatAttachmentContextError.capabilitiesUnavailable ||
            !_isCurrent(generation) ||
            _cancelRequested) {
          rethrow;
        }
      }
      final paused = Completer<void>();
      _createWatchdogTimer(delay, paused.complete);
      await paused.future;
      if (!_isCurrent(generation) || _cancelRequested) {
        throw const ChatAttachmentContextException(
          ChatAttachmentContextError.capabilitiesUnavailable,
        );
      }
    }
    return _startUpload(request);
  }
}

/// Names why admission refused an upload.
///
/// Everything here used to be reported as `dispatch`, which is why the first
/// field report — a gallery pick that failed instantly on a foldable — could
/// be seen in telemetry but not explained. The causes are genuinely different
/// problems with genuinely different fixes: a room the user may not write to,
/// an account whose server moved, a missing credential, or an app that never
/// came back to the foreground after the picker closed.
AttachmentUploadFailure _classifyAdmissionFailure(Object error) {
  if (error is ChatAttachmentContextException) {
    return _classifyContextFailure(error.code);
  }
  if (error is! AttachmentAdmissionException) {
    return AttachmentUploadFailure.dispatch;
  }
  return switch (error.error) {
    AttachmentAdmissionError.roomUnsupported =>
      AttachmentUploadFailure.roomUnsupported,
    AttachmentAdmissionError.accountBinding ||
    AttachmentAdmissionError.accountStale =>
      AttachmentUploadFailure.accountBinding,
    AttachmentAdmissionError.credentialMissing =>
      AttachmentUploadFailure.credential,
    AttachmentAdmissionError.rejected => AttachmentUploadFailure.admission,
    AttachmentAdmissionError.lifecycleTimeout =>
      AttachmentUploadFailure.lifecycleTimeout,
    AttachmentAdmissionError.composerGone =>
      AttachmentUploadFailure.composerGone,
  };
}

/// The context resolver's refusals, which used to fall through as `dispatch`
/// because they are not admission exceptions. Found on 2026-09-03 when a
/// throttled emulator reproduced the foldable report's exact class.
AttachmentUploadFailure _classifyContextFailure(
  ChatAttachmentContextError code,
) => switch (code) {
  ChatAttachmentContextError.capabilitiesUnavailable =>
    AttachmentUploadFailure.serverUnreachable,
  ChatAttachmentContextError.invalidCapabilities ||
  ChatAttachmentContextError.talkUnavailable ||
  ChatAttachmentContextError.attachmentUnsupported ||
  ChatAttachmentContextError.sourceUnsupported ||
  ChatAttachmentContextError.readOnly ||
  ChatAttachmentContextError.federatedUnsupported ||
  ChatAttachmentContextError.invalidConversation =>
    AttachmentUploadFailure.roomUnsupported,
  ChatAttachmentContextError.credentialMissing ||
  ChatAttachmentContextError.reauthenticationRequired =>
    AttachmentUploadFailure.credential,
  ChatAttachmentContextError.accountMissing ||
  ChatAttachmentContextError.conversationMissing ||
  ChatAttachmentContextError.contextChanged ||
  ChatAttachmentContextError.identityUnverified =>
    AttachmentUploadFailure.accountBinding,
};
