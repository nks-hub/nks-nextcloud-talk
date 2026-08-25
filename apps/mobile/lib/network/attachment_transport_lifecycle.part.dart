part of 'attachment_transport.dart';

final class _AttachmentCancellationState
    implements AttachmentCancellationSignal {
  final Set<_AttachmentSignalRegistration> _registrations =
      <_AttachmentSignalRegistration>{};
  bool _isCancelled = false;

  @override
  bool get isCancelled => _isCancelled;

  @override
  AttachmentCancellationRegistration register(
    FutureOr<void> Function() action,
  ) {
    final registration = _AttachmentSignalRegistration(this, action);
    if (_isCancelled) {
      unawaited(registration.invoke().catchError((Object _, StackTrace _) {}));
    } else {
      _registrations.add(registration);
    }
    return registration;
  }

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    for (final registration in _registrations.toList(growable: false)) {
      unawaited(registration.invoke().catchError((Object _, StackTrace _) {}));
    }
  }

  void detach(_AttachmentSignalRegistration registration) {
    _registrations.remove(registration);
  }
}

final class _AttachmentSignalRegistration
    implements AttachmentCancellationRegistration {
  _AttachmentSignalRegistration(this._owner, this._action);

  _AttachmentCancellationState? _owner;
  final FutureOr<void> Function() _action;
  Future<void>? _invocation;

  Future<void> invoke() {
    detach();
    return _invocation ??= Future<void>.sync(_action);
  }

  @override
  void detach() {
    final owner = _owner;
    _owner = null;
    owner?.detach(this);
  }
}

final class _OperationAbortController implements AttachmentCancellationSignal {
  _OperationAbortController(
    AttachmentCancellationSignal? callerCancellation, {
    required this._stage,
    required this._requestMayHaveReachedServer,
    required this._step,
  }) {
    _callerCancellationRegistration = callerCancellation?.register(
      () => abort(AttachmentTransportError.cancelled, protocolCode: null),
    );
    if (callerCancellation?.isCancelled ?? false) {
      abort(AttachmentTransportError.cancelled, protocolCode: null);
    }
  }

  final Completer<void> _abortTrigger = Completer<void>.sync();
  final Set<_CancellationRegistration> _cancellations =
      <_CancellationRegistration>{};
  AttachmentCancellationRegistration? _callerCancellationRegistration;
  AttachmentTransportStage _stage;
  bool _requestMayHaveReachedServer;
  AttachmentRequestStep _step;
  bool _disposed = false;

  Future<void> get abortTrigger => _abortTrigger.future;

  AttachmentTransportException? get failure => _completedFailure;

  @override
  bool get isCancelled => _completedFailure != null;

  AttachmentTransportException? _completedFailure;

  void updateContext({
    required AttachmentTransportStage stage,
    required bool requestMayHaveReachedServer,
    AttachmentRequestStep? step,
  }) {
    _stage = stage;
    _requestMayHaveReachedServer = requestMayHaveReachedServer;
    _step = step ?? _step;
  }

  void abort(
    AttachmentTransportError code, {
    required TalkProtocolErrorCode? protocolCode,
  }) {
    abortWithFailure(
      _transportFailure(
        code,
        _step,
        _stage,
        protocolCode: protocolCode,
        requestMayHaveReachedServer: _requestMayHaveReachedServer,
      ),
    );
  }

  void abortWithFailure(AttachmentTransportException error) {
    if (_completedFailure != null || _disposed) {
      return;
    }
    _completedFailure = error;
    if (!_abortTrigger.isCompleted) {
      _abortTrigger.complete();
    }
    for (final cancellation in _cancellations.toList(growable: false)) {
      unawaited(cancellation.invoke().catchError((Object _, StackTrace _) {}));
    }
  }

  void throwIfAborted() {
    final error = _completedFailure;
    if (error != null) {
      throw error;
    }
  }

  @override
  _CancellationRegistration register(FutureOr<void> Function() action) {
    final cancellation = _CancellationRegistration(this, action);
    if (!_disposed) {
      _cancellations.add(cancellation);
    }
    if (_completedFailure != null) {
      unawaited(cancellation.invoke().catchError((Object _, StackTrace _) {}));
    }
    return cancellation;
  }

  void _detach(_CancellationRegistration cancellation) {
    _cancellations.remove(cancellation);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final callerCancellationRegistration = _callerCancellationRegistration;
    _callerCancellationRegistration = null;
    for (final cancellation in _cancellations.toList(growable: false)) {
      cancellation.detach();
    }
    if (!_abortTrigger.isCompleted) {
      _abortTrigger.complete();
    }
    if (callerCancellationRegistration != null) {
      try {
        callerCancellationRegistration.detach();
      } on Object {
        // The completed operation keeps its result if an external signal has
        // a broken detach implementation.
      }
    }
  }
}

final class _CancellationRegistration
    implements AttachmentCancellationRegistration {
  _CancellationRegistration(this._owner, this._action);

  _OperationAbortController? _owner;
  final FutureOr<void> Function() _action;
  Future<void>? _invocation;

  Future<void> invoke() => _invocation ??= Future<void>.sync(_action);

  Future<void> runForCleanup() {
    detach();
    return invoke();
  }

  @override
  void detach() {
    final owner = _owner;
    _owner = null;
    owner?._detach(this);
  }
}

final class _TransferActivity {
  _TransferActivity({
    required this.abort,
    required this.connectTimeout,
    required this.idleTimeout,
  });

  final _OperationAbortController abort;
  final Duration connectTimeout;
  final Duration idleTimeout;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  Duration _lastActivity = Duration.zero;
  Duration _limit = Duration.zero;
  AttachmentTransportError _timeoutCode =
      AttachmentTransportError.connectTimeout;
  bool _stopped = false;

  void startConnect({
    required AttachmentTransportStage stage,
    required bool requestMayHaveReachedServer,
  }) {
    _start(
      limit: connectTimeout,
      timeoutCode: AttachmentTransportError.connectTimeout,
      stage: stage,
      requestMayHaveReachedServer: requestMayHaveReachedServer,
    );
  }

  void startIdle({
    required AttachmentTransportStage stage,
    required bool requestMayHaveReachedServer,
  }) {
    _start(
      limit: idleTimeout,
      timeoutCode: AttachmentTransportError.idleTimeout,
      stage: stage,
      requestMayHaveReachedServer: requestMayHaveReachedServer,
    );
  }

  void _start({
    required Duration limit,
    required AttachmentTransportError timeoutCode,
    required AttachmentTransportStage stage,
    required bool requestMayHaveReachedServer,
  }) {
    _clock.start();
    _lastActivity = _clock.elapsed;
    _limit = limit;
    _timeoutCode = timeoutCode;
    abort.updateContext(
      stage: stage,
      requestMayHaveReachedServer: requestMayHaveReachedServer,
    );
    _schedule();
  }

  void markProgress({
    required AttachmentTransportStage stage,
    required bool requestMayHaveReachedServer,
  }) {
    if (_stopped || abort.failure != null) {
      return;
    }
    _lastActivity = _clock.elapsed;
    _limit = idleTimeout;
    _timeoutCode = AttachmentTransportError.idleTimeout;
    abort.updateContext(
      stage: stage,
      requestMayHaveReachedServer: requestMayHaveReachedServer,
    );
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (_stopped || abort.failure != null) {
      return;
    }
    final elapsed = _clock.elapsed - _lastActivity;
    final remaining = _limit - elapsed;
    if (remaining <= Duration.zero) {
      _timeout();
      return;
    }
    _timer = Timer(remaining, _check);
  }

  void _check() {
    if (_stopped || abort.failure != null) {
      return;
    }
    if (_clock.elapsed - _lastActivity >= _limit) {
      _timeout();
    } else {
      _schedule();
    }
  }

  void _timeout() {
    abort.abort(_timeoutCode, protocolCode: null);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _clock.stop();
  }
}

final class _CleanupBudget {
  _CleanupBudget(this.timeout) : _clock = Stopwatch()..start();

  final Duration timeout;
  final Stopwatch _clock;

  Future<bool> run(Future<void> Function() action) async {
    final remaining = timeout - _clock.elapsed;
    if (remaining <= Duration.zero) {
      unawaited(
        Future<void>.sync(action).catchError((Object _, StackTrace _) {}),
      );
      return false;
    }
    try {
      await Future<void>.sync(action).timeout(remaining);
      return true;
    } on Object {
      return false;
    }
  }
}

final class _CapturedFailure {
  const _CapturedFailure(this.error, this.stackTrace);

  final AttachmentTransportException error;
  final StackTrace stackTrace;

  Never throwFailure() => Error.throwWithStackTrace(error, stackTrace);
}

final class _AttachmentWirePayload {
  const _AttachmentWirePayload(this.statusCode, this.body);

  final int statusCode;
  final Uint8List body;
}
