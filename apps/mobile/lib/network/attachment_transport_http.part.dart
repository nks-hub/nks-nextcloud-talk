part of 'attachment_transport.dart';

mixin _HttpAttachmentTransportInternals {
  http.Client get _client;
  AttachmentSourceProvider get _sourceProvider;
  Object get _sourceOwner;
  Set<_OperationAbortController> get _activeOperations;
  Duration get connectTimeout;
  Duration get idleTimeout;
  Duration get cleanupTimeout;
  bool get _closed;

  Future<_AttachmentWirePayload> _send({
    required AttachmentRequest request,
    required AttachmentTransportAuthorization authorization,
    required AttachmentCancellationSignal? cancellationSignal,
    required AttachmentVerifiedSource? verifiedSource,
  }) async {
    _ensureOpen(request.step);
    _validateAuthorization(request, authorization);
    _validateOrigin(request);
    final rawBody = request.body;
    final sourceBody = rawBody is AttachmentSourceBody ? rawBody : null;
    if (sourceBody != null) {
      _validateVerifiedSource(
        request: request,
        authorization: authorization,
        body: sourceBody,
        verifiedSource: verifiedSource,
      );
    }

    final abort = _OperationAbortController(
      cancellationSignal,
      stage: AttachmentTransportStage.connect,
      requestMayHaveReachedServer: true,
      step: request.step,
    );
    _activeOperations.add(abort);
    final activity =
        _TransferActivity(
          abort: abort,
          connectTimeout: connectTimeout,
          idleTimeout: idleTimeout,
        )..startConnect(
          stage: AttachmentTransportStage.connect,
          requestMayHaveReachedServer: true,
        );

    try {
      final authorizationHeader = _basicAuthorization(authorization);
      final http.StreamedResponse response;
      if (sourceBody != null) {
        response = await _sendSourceRequest(
          request: request,
          body: sourceBody,
          verifiedSource: verifiedSource!,
          authorizationHeader: authorizationHeader,
          abort: abort,
          activity: activity,
        );
      } else {
        final wireRequest = _regularRequest(
          request,
          authorizationHeader,
          abort.abortTrigger,
        );
        response = await _sendRequest(
          wireRequest,
          step: request.step,
          abort: abort,
          activity: activity,
        );
      }

      if (response.statusCode >= 300 && response.statusCode < 400) {
        await _cancelResponsePreserving(
          response,
          step: request.step,
          primary: _CapturedFailure(
            _transportFailure(
              AttachmentTransportError.redirectRejected,
              request.step,
              AttachmentTransportStage.response,
              statusCode: response.statusCode,
              requestMayHaveReachedServer: true,
            ),
            StackTrace.current,
          ),
        );
      }

      final maximumBytes = request.step == AttachmentRequestStep.chunkPropfind
          ? attachmentMaximumDavXmlBytes
          : attachmentMaximumResponseBytes;
      final body = await _readBounded(
        response,
        maximumBytes: maximumBytes,
        step: request.step,
        abort: abort,
        activity: activity,
      );
      return _AttachmentWirePayload(response.statusCode, body);
    } finally {
      activity.stop();
      await _finishOperation(abort);
    }
  }

  http.AbortableRequest _regularRequest(
    AttachmentRequest request,
    String authorizationHeader,
    Future<void> abortTrigger,
  ) {
    final wireRequest =
        http.AbortableRequest(
            _methodName(request.method),
            request.uri,
            abortTrigger: abortTrigger,
          )
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll(request.headers)
          ..headers['Authorization'] = authorizationHeader;
    switch (request.body) {
      case AttachmentJsonBody(:final fields):
        wireRequest.bodyBytes = utf8.encode(jsonEncode(fields));
      case AttachmentXmlBody(:final value):
        wireRequest.bodyBytes = utf8.encode(value);
      case null:
        wireRequest.bodyBytes = Uint8List(0);
      case AttachmentSourceBody():
        throw StateError('Source bodies use the streaming request path.');
    }
    return wireRequest;
  }

  Future<http.StreamedResponse> _sendSourceRequest({
    required AttachmentRequest request,
    required AttachmentSourceBody body,
    required AttachmentVerifiedSource verifiedSource,
    required String authorizationHeader,
    required _OperationAbortController abort,
    required _TransferActivity activity,
  }) async {
    final wireRequest =
        http.AbortableStreamedRequest(
            _methodName(request.method),
            request.uri,
            abortTrigger: abort.abortTrigger,
          )
          ..followRedirects = false
          ..maxRedirects = 0
          ..contentLength = body.length
          ..headers.addAll(request.headers)
          ..headers['Authorization'] = authorizationHeader;
    verifiedSource._wasDispatched = true;

    http.StreamedResponse? response;
    _CapturedFailure? firstFailure;
    Future<void> captureResponse() async {
      try {
        response = await _sendRequest(
          wireRequest,
          step: request.step,
          abort: abort,
          activity: activity,
        );
      } on Object catch (error, stack) {
        firstFailure ??= _CapturedFailure(
          _normalizePostDispatchFailure(
            error,
            request.step,
            AttachmentTransportStage.connect,
          ),
          stack,
        );
        abort.abortWithFailure(firstFailure!.error);
      }
    }

    Future<void> capturePump() async {
      try {
        await _pumpRange(
          source: verifiedSource,
          body: body,
          sink: wireRequest.sink,
          step: request.step,
          abort: abort,
          activity: activity,
        );
      } on Object catch (error, stack) {
        firstFailure ??= _CapturedFailure(
          _normalizePostDispatchFailure(
            error,
            request.step,
            AttachmentTransportStage.upload,
          ),
          stack,
        );
        abort.abortWithFailure(firstFailure!.error);
      }
    }

    await Future.wait<void>(<Future<void>>[captureResponse(), capturePump()]);
    if (firstFailure != null) {
      firstFailure!.throwFailure();
    }
    return response!;
  }

  Future<void> _pumpRange({
    required AttachmentVerifiedSource source,
    required AttachmentSourceBody body,
    required StreamSink<List<int>> sink,
    required AttachmentRequestStep step,
    required _OperationAbortController abort,
    required _TransferActivity activity,
  }) async {
    StreamIterator<List<int>>? iterator;
    _CancellationRegistration? iteratorCancellation;
    _CapturedFailure? failure;
    try {
      try {
        iterator = StreamIterator<List<int>>(
          source._lease.openRead(offset: body.offset, length: body.length),
        );
        iteratorCancellation = abort.register(iterator.cancel);
      } on Object {
        throw _transportFailure(
          AttachmentTransportError.sourceUnavailable,
          step,
          AttachmentTransportStage.upload,
          requestMayHaveReachedServer: true,
        );
      }
      var remaining = body.length;
      while (remaining > 0) {
        final hasNext = await _nextSourceChunk(
          iterator,
          step: step,
          stage: AttachmentTransportStage.upload,
          requestMayHaveReachedServer: true,
          abort: abort,
        );
        if (!hasNext) {
          break;
        }
        final chunk = iterator.current;
        _validateSourceChunk(
          chunk,
          step,
          stage: AttachmentTransportStage.upload,
          requestMayHaveReachedServer: true,
        );
        final take = chunk.length < remaining ? chunk.length : remaining;
        if (take > 0) {
          try {
            abort.throwIfAborted();
            await sink.addStream(
              Stream<List<int>>.value(
                take == chunk.length ? chunk : chunk.sublist(0, take),
              ),
            );
            abort.throwIfAborted();
          } on AttachmentTransportException {
            rethrow;
          } on Object {
            throw _transportFailure(
              AttachmentTransportError.network,
              step,
              AttachmentTransportStage.upload,
              requestMayHaveReachedServer: true,
            );
          }
          remaining -= take;
          activity.markProgress(
            stage: AttachmentTransportStage.upload,
            requestMayHaveReachedServer: true,
          );
        }
      }
      if (remaining != 0) {
        throw _transportFailure(
          AttachmentTransportError.sourceChanged,
          step,
          AttachmentTransportStage.upload,
          requestMayHaveReachedServer: true,
        );
      }
    } on Object catch (error, stack) {
      failure = _CapturedFailure(
        _normalizePostDispatchFailure(
          error,
          step,
          AttachmentTransportStage.upload,
        ),
        stack,
      );
    }

    final cleanupFailure = await _cleanupActions(
      <Future<void> Function()>[
        sink.close,
        if (iteratorCancellation != null)
          iteratorCancellation.runForCleanup
        else if (iterator != null)
          iterator.cancel,
      ],
      step: step,
      requestMayHaveReachedServer: true,
    );
    if (failure != null) {
      failure.throwFailure();
    }
    if (cleanupFailure != null) {
      throw cleanupFailure;
    }
  }

  Future<http.StreamedResponse> _sendRequest(
    http.BaseRequest request, {
    required AttachmentRequestStep step,
    required _OperationAbortController abort,
    required _TransferActivity activity,
  }) async {
    try {
      abort.throwIfAborted();
      final response = await _client.send(request);
      abort.throwIfAborted();
      activity.markProgress(
        stage: AttachmentTransportStage.response,
        requestMayHaveReachedServer: true,
      );
      return response;
    } on AttachmentTransportException {
      rethrow;
    } on http.RequestAbortedException {
      final abortFailure = abort.failure;
      if (abortFailure != null) {
        throw abortFailure;
      }
      throw _transportFailure(
        AttachmentTransportError.network,
        step,
        AttachmentTransportStage.connect,
        requestMayHaveReachedServer: true,
      );
    } on Object {
      throw _transportFailure(
        AttachmentTransportError.network,
        step,
        AttachmentTransportStage.connect,
        requestMayHaveReachedServer: true,
      );
    }
  }

  Future<Uint8List> _readBounded(
    http.StreamedResponse response, {
    required int maximumBytes,
    required AttachmentRequestStep step,
    required _OperationAbortController abort,
    required _TransferActivity activity,
  }) async {
    if (response.contentLength case final contentLength?
        when contentLength > maximumBytes) {
      final primary = _CapturedFailure(
        _transportFailure(
          AttachmentTransportError.responseTooLarge,
          step,
          AttachmentTransportStage.response,
          statusCode: response.statusCode,
          requestMayHaveReachedServer: true,
        ),
        StackTrace.current,
      );
      await _cancelResponsePreserving(response, step: step, primary: primary);
    }

    final bytes = BytesBuilder(copy: false);
    var byteLength = 0;
    final iterator = StreamIterator<List<int>>(response.stream);
    final cancellation = abort.register(iterator.cancel);
    _CapturedFailure? failure;
    try {
      while (await _nextStreamChunk(
        iterator,
        abort: abort,
        fallback: () => _transportFailure(
          AttachmentTransportError.network,
          step,
          AttachmentTransportStage.response,
          statusCode: response.statusCode,
          requestMayHaveReachedServer: true,
        ),
      )) {
        final chunk = iterator.current;
        byteLength += chunk.length;
        if (byteLength > maximumBytes) {
          throw _transportFailure(
            AttachmentTransportError.responseTooLarge,
            step,
            AttachmentTransportStage.response,
            statusCode: response.statusCode,
            requestMayHaveReachedServer: true,
          );
        }
        bytes.add(chunk);
        activity.markProgress(
          stage: AttachmentTransportStage.response,
          requestMayHaveReachedServer: true,
        );
      }
    } on Object catch (error, stack) {
      failure = _CapturedFailure(
        _normalizePostDispatchFailure(
          error,
          step,
          AttachmentTransportStage.response,
          statusCode: response.statusCode,
        ),
        stack,
      );
    }
    final cleanupFailure = await _cleanupActions(
      <Future<void> Function()>[cancellation.runForCleanup],
      step: step,
      requestMayHaveReachedServer: true,
    );
    if (failure != null) {
      failure.throwFailure();
    }
    if (cleanupFailure != null) {
      throw cleanupFailure;
    }
    return bytes.takeBytes();
  }

  Future<void> _verifyLease({
    required AttachmentSourceLease lease,
    required PreparedAttachmentSource source,
    required AttachmentRequestStep step,
    required _OperationAbortController abort,
    required _TransferActivity activity,
  }) async {
    StreamIterator<List<int>>? iterator;
    _CancellationRegistration? iteratorCancellation;
    _CapturedFailure? failure;
    final digest = _Sha256Digest();
    var byteLength = 0;
    try {
      try {
        iterator = StreamIterator<List<int>>(lease.openRead());
        iteratorCancellation = abort.register(iterator.cancel);
      } on Object {
        throw _transportFailure(
          AttachmentTransportError.sourceUnavailable,
          step,
          AttachmentTransportStage.sourceVerification,
        );
      }
      while (await _nextSourceChunk(
        iterator,
        step: step,
        stage: AttachmentTransportStage.sourceVerification,
        requestMayHaveReachedServer: false,
        abort: abort,
      )) {
        final chunk = iterator.current;
        _validateSourceChunk(
          chunk,
          step,
          stage: AttachmentTransportStage.sourceVerification,
          requestMayHaveReachedServer: false,
        );
        byteLength += chunk.length;
        if (byteLength > source.byteLength ||
            byteLength > attachmentMaximumSourceBytes) {
          throw _transportFailure(
            AttachmentTransportError.sourceChanged,
            step,
            AttachmentTransportStage.sourceVerification,
          );
        }
        digest.add(chunk);
        activity.markProgress(
          stage: AttachmentTransportStage.sourceVerification,
          requestMayHaveReachedServer: false,
        );
      }
      if (byteLength != source.byteLength ||
          digest.close() != source.sha256.value) {
        throw _transportFailure(
          AttachmentTransportError.sourceChanged,
          step,
          AttachmentTransportStage.sourceVerification,
        );
      }
    } on Object catch (error, stack) {
      failure = _CapturedFailure(
        _normalizePreDispatchFailure(
          error,
          step,
          AttachmentTransportStage.sourceVerification,
        ),
        stack,
      );
    }
    final cleanupFailure = await _cleanupActions(
      <Future<void> Function()>[
        if (iteratorCancellation != null)
          iteratorCancellation.runForCleanup
        else if (iterator != null)
          iterator.cancel,
      ],
      step: step,
      requestMayHaveReachedServer: false,
    );
    if (failure != null) {
      failure.throwFailure();
    }
    if (cleanupFailure != null) {
      throw cleanupFailure;
    }
  }

  Future<bool> _nextSourceChunk(
    StreamIterator<List<int>> iterator, {
    required AttachmentRequestStep step,
    required AttachmentTransportStage stage,
    required bool requestMayHaveReachedServer,
    required _OperationAbortController abort,
  }) async {
    try {
      return await _nextStreamChunk(
        iterator,
        abort: abort,
        fallback: () => _transportFailure(
          AttachmentTransportError.sourceUnavailable,
          step,
          stage,
          requestMayHaveReachedServer: requestMayHaveReachedServer,
        ),
      );
    } on AttachmentTransportException {
      rethrow;
    } on Object {
      throw _transportFailure(
        AttachmentTransportError.sourceUnavailable,
        step,
        stage,
        requestMayHaveReachedServer: requestMayHaveReachedServer,
      );
    }
  }

  Future<bool> _nextStreamChunk(
    StreamIterator<List<int>> iterator, {
    required _OperationAbortController abort,
    required AttachmentTransportException Function() fallback,
  }) async {
    abort.throwIfAborted();
    try {
      final hasNext = await iterator.moveNext();
      abort.throwIfAborted();
      return hasNext;
    } on AttachmentTransportException {
      rethrow;
    } on Object {
      abort.throwIfAborted();
      throw fallback();
    }
  }

  T _decodeResponse<T extends AttachmentResponse>({
    required AttachmentRequest request,
    required _AttachmentWirePayload payload,
    required T Function() decode,
  }) {
    try {
      return decode();
    } on TalkProtocolException catch (error) {
      throw _transportFailure(
        AttachmentTransportError.invalidResponse,
        request.step,
        AttachmentTransportStage.decoding,
        statusCode: payload.statusCode,
        protocolCode: error.code,
        requestMayHaveReachedServer: true,
      );
    } on AttachmentTransportException {
      rethrow;
    } on Object {
      throw _transportFailure(
        AttachmentTransportError.invalidResponse,
        request.step,
        AttachmentTransportStage.decoding,
        statusCode: payload.statusCode,
        requestMayHaveReachedServer: true,
      );
    }
  }

  Future<void> _cancelResponsePreserving(
    http.StreamedResponse response, {
    required AttachmentRequestStep step,
    required _CapturedFailure primary,
  }) async {
    await _cleanupActions(
      <Future<void> Function()>[
        () async {
          final subscription = response.stream.listen((_) {}, onError: (_) {});
          await subscription.cancel();
        },
      ],
      step: step,
      requestMayHaveReachedServer: true,
    );
    primary.throwFailure();
  }

  Future<void> _closeLeasePreserving(
    AttachmentSourceLease lease, {
    required _CapturedFailure? primary,
    required AttachmentRequestStep step,
    required bool requestMayHaveReachedServer,
  }) async {
    final cleanupFailure = await _cleanupActions(
      <Future<void> Function()>[lease.close],
      step: step,
      requestMayHaveReachedServer: requestMayHaveReachedServer,
    );
    if (primary != null) {
      primary.throwFailure();
    }
    if (cleanupFailure != null) {
      throw cleanupFailure;
    }
  }

  Future<AttachmentSourceLease> _acquireLease({
    required PreparedAttachmentSource source,
    required _OperationAbortController abort,
    required AttachmentRequestStep step,
  }) {
    final result = Completer<AttachmentSourceLease>.sync();
    late final _CancellationRegistration cancellation;
    cancellation = abort.register(() {
      if (!result.isCompleted) {
        result.completeError(abort.failure!, StackTrace.current);
      }
    });
    if (!result.isCompleted) {
      Future<AttachmentSourceLease>.sync(
        () => _sourceProvider.open(source.handle, cancellationSignal: abort),
      ).then<void>(
        (lease) {
          final rejection =
              abort.failure ??
              (_closed
                  ? _transportFailure(
                      AttachmentTransportError.closed,
                      step,
                      AttachmentTransportStage.sourceOpen,
                    )
                  : null);
          if (result.isCompleted || rejection != null) {
            if (!result.isCompleted) {
              result.completeError(rejection!, StackTrace.current);
            }
            _discardLateLease(lease, step: step);
            return;
          }
          result.complete(lease);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) {
            result.completeError(error, stack);
          }
        },
      );
    }
    return result.future.whenComplete(cancellation.detach);
  }

  void _discardLateLease(
    AttachmentSourceLease lease, {
    required AttachmentRequestStep step,
  }) {
    unawaited(
      _cleanupActions(
        <Future<void> Function()>[lease.close],
        step: step,
        requestMayHaveReachedServer: false,
      ).then<void>((_) {}),
    );
  }

  Future<void> _finishOperation(_OperationAbortController abort) async {
    _activeOperations.remove(abort);
    await abort.dispose();
  }

  Future<AttachmentTransportException?> _cleanupActions(
    Iterable<Future<void> Function()> actions, {
    required AttachmentRequestStep step,
    required bool requestMayHaveReachedServer,
  }) async {
    final budget = _CleanupBudget(cleanupTimeout);
    var failed = false;
    for (final action in actions) {
      if (!await budget.run(action)) {
        failed = true;
      }
    }
    return failed
        ? _transportFailure(
            AttachmentTransportError.cleanupFailed,
            step,
            AttachmentTransportStage.cleanup,
            requestMayHaveReachedServer: requestMayHaveReachedServer,
          )
        : null;
  }

  void _ensureOpen(AttachmentRequestStep step) {
    if (_closed) {
      throw _transportFailure(
        AttachmentTransportError.closed,
        step,
        AttachmentTransportStage.authorization,
      );
    }
  }

  void _validateAuthorization(
    AttachmentRequest request,
    AttachmentTransportAuthorization authorization,
  ) {
    _validateAuthorizationFields(authorization, request.step);
    if (authorization.accountId != request.accountId ||
        authorization.server != request.server) {
      throw _transportFailure(
        AttachmentTransportError.authorityMismatch,
        request.step,
        AttachmentTransportStage.authorization,
      );
    }
  }

  void _validateAuthorizationFields(
    AttachmentTransportAuthorization authorization,
    AttachmentRequestStep step,
  ) {
    if (authorization.loginName.isEmpty ||
        authorization.appPassword.isEmpty ||
        authorization.loginName.contains('\r') ||
        authorization.loginName.contains('\n') ||
        authorization.appPassword.contains('\r') ||
        authorization.appPassword.contains('\n')) {
      throw _transportFailure(
        AttachmentTransportError.invalidCredentials,
        step,
        AttachmentTransportStage.authorization,
      );
    }
  }

  void _validateVerifiedSource({
    required AttachmentRequest request,
    required AttachmentTransportAuthorization authorization,
    required AttachmentSourceBody body,
    required AttachmentVerifiedSource? verifiedSource,
  }) {
    if (verifiedSource == null ||
        !identical(verifiedSource._transportOwner, _sourceOwner) ||
        verifiedSource._closed ||
        verifiedSource._accountId != authorization.accountId ||
        verifiedSource._server != authorization.server) {
      throw _transportFailure(
        AttachmentTransportError.authorityMismatch,
        request.step,
        AttachmentTransportStage.authorization,
      );
    }
    if (verifiedSource._source.handle != body.handle ||
        verifiedSource._source.sha256 != body.expectedSha256 ||
        body.offset + body.length > verifiedSource._source.byteLength) {
      throw _transportFailure(
        AttachmentTransportError.sourceChanged,
        request.step,
        AttachmentTransportStage.sourceVerification,
      );
    }
  }
}
