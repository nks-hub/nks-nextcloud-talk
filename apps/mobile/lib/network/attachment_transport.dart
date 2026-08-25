import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

enum AttachmentTransportError {
  cancelled,
  connectTimeout,
  idleTimeout,
  network,
  closed,
  invalidCredentials,
  authorityMismatch,
  invalidOrigin,
  redirectRejected,
  responseTooLarge,
  invalidResponse,
  sourceUnavailable,
  sourceChanged,
  cleanupFailed,
}

enum AttachmentTransportStage {
  authorization,
  sourceOpen,
  sourceVerification,
  connect,
  upload,
  response,
  decoding,
  cleanup,
}

final class AttachmentTransportException implements Exception {
  const AttachmentTransportException(
    this.code, {
    required this.step,
    required this.stage,
    this.statusCode,
    this.protocolCode,
    this.requestMayHaveReachedServer = false,
  });

  final AttachmentTransportError code;
  final AttachmentRequestStep step;
  final AttachmentTransportStage stage;
  final int? statusCode;
  final TalkProtocolErrorCode? protocolCode;
  final bool requestMayHaveReachedServer;

  @override
  String toString() =>
      'AttachmentTransportException(code: ${code.name}, step: ${step.name}, '
      'stage: ${stage.name}, statusCode: $statusCode, protocolCode: '
      '${protocolCode?.name}, requestMayHaveReachedServer: '
      '$requestMayHaveReachedServer)';
}

final class AttachmentTransportAuthorization {
  const AttachmentTransportAuthorization({
    required this.accountId,
    required this.server,
    required this.loginName,
    required this.appPassword,
  });

  final AccountId accountId;
  final ServerBase server;
  final String loginName;
  final String appPassword;

  @override
  String toString() => 'AttachmentTransportAuthorization(<redacted>)';
}

/// A detachable registration for one cancellation callback.
///
/// [detach] is idempotent. Detaching before cancellation prevents the callback
/// from being invoked later.
abstract interface class AttachmentCancellationRegistration {
  void detach();
}

/// A single-transition cancellation signal with detachable callbacks.
abstract interface class AttachmentCancellationSignal {
  bool get isCancelled;

  /// Registers [action] for cancellation.
  ///
  /// The action is started at most once. If this signal is already cancelled,
  /// it is started exactly once before [register] returns and the returned
  /// registration is already detached.
  AttachmentCancellationRegistration register(FutureOr<void> Function() action);
}

final class AttachmentCancellationController {
  final _AttachmentCancellationState _state = _AttachmentCancellationState();

  AttachmentCancellationSignal get signal => _state;

  bool get isCancelled => _state.isCancelled;

  void cancel() => _state.cancel();
}

/// An immutable view of an app-owned attachment source.
///
/// [openRead] must return a new stream on every call and the bytes must remain
/// unchanged until [close] completes. A non-zero [offset] must be implemented
/// as an efficient seek, without reading and discarding the preceding bytes.
/// When [length] is supplied, the stream emits at most that many bytes.
/// The transport verifies the lease once, then reuses the same snapshot for
/// every normal or chunk PUT in that upload.
abstract interface class AttachmentSourceLease {
  Stream<List<int>> openRead({int offset = 0, int? length});

  Future<void> close();
}

abstract interface class AttachmentSourceProvider {
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  });
}

final class AttachmentVerifiedSource {
  AttachmentVerifiedSource._({
    required this._transportOwner,
    required AttachmentTransportAuthorization authorization,
    required this._source,
    required this._lease,
  }) : _accountId = authorization.accountId,
       _server = authorization.server;

  final Object _transportOwner;
  final AccountId _accountId;
  final ServerBase _server;
  final PreparedAttachmentSource _source;
  final AttachmentSourceLease _lease;
  bool _closed = false;
  bool _wasDispatched = false;

  int get byteLength => _source.byteLength;

  bool get isClosed => _closed;

  @override
  String toString() =>
      'AttachmentVerifiedSource(closed: $_closed, source: <redacted>, '
      'account: <redacted>, server: <redacted>)';
}

final class HttpAttachmentTransport {
  factory HttpAttachmentTransport({
    required http.Client client,
    required AttachmentSourceProvider sourceProvider,
    Duration connectTimeout = const Duration(seconds: 20),
    Duration idleTimeout = const Duration(seconds: 30),
    Duration cleanupTimeout = const Duration(seconds: 2),
  }) {
    for (final entry in <(String, Duration)>[
      ('connectTimeout', connectTimeout),
      ('idleTimeout', idleTimeout),
      ('cleanupTimeout', cleanupTimeout),
    ]) {
      if (entry.$2 <= Duration.zero) {
        throw ArgumentError.value(entry.$2, entry.$1, 'must be positive');
      }
    }
    return HttpAttachmentTransport._(
      client,
      sourceProvider,
      connectTimeout,
      idleTimeout,
      cleanupTimeout,
    );
  }

  HttpAttachmentTransport._(
    this._client,
    this._sourceProvider,
    this.connectTimeout,
    this.idleTimeout,
    this.cleanupTimeout,
  );

  final http.Client _client;
  final AttachmentSourceProvider _sourceProvider;
  final Object _sourceOwner = Object();
  final Set<AttachmentVerifiedSource> _verifiedSources =
      <AttachmentVerifiedSource>{};
  final Set<_OperationAbortController> _activeOperations =
      <_OperationAbortController>{};
  final Duration connectTimeout;
  final Duration idleTimeout;
  final Duration cleanupTimeout;
  bool _closed = false;

  Future<AttachmentVerifiedSource> verifySource({
    required PreparedAttachmentSource source,
    required AttachmentTransportAuthorization authorization,
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    _ensureOpen(AttachmentRequestStep.normalPut);
    _validateAuthorizationFields(
      authorization,
      AttachmentRequestStep.normalPut,
    );
    final abort = _OperationAbortController(
      cancellationSignal,
      stage: AttachmentTransportStage.sourceOpen,
      requestMayHaveReachedServer: false,
      step: AttachmentRequestStep.normalPut,
    );
    _activeOperations.add(abort);
    final activity =
        _TransferActivity(
          abort: abort,
          connectTimeout: connectTimeout,
          idleTimeout: idleTimeout,
        )..startIdle(
          stage: AttachmentTransportStage.sourceOpen,
          requestMayHaveReachedServer: false,
        );

    AttachmentSourceLease? lease;
    _CapturedFailure? failure;
    try {
      try {
        lease = await _acquireLease(
          source: source,
          abort: abort,
          step: AttachmentRequestStep.normalPut,
        );
        abort.throwIfAborted();
      } on AttachmentTransportException {
        rethrow;
      } on Object {
        throw _transportFailure(
          AttachmentTransportError.sourceUnavailable,
          AttachmentRequestStep.normalPut,
          AttachmentTransportStage.sourceOpen,
        );
      }
      activity.markProgress(
        stage: AttachmentTransportStage.sourceVerification,
        requestMayHaveReachedServer: false,
      );
      await _verifyLease(
        lease: lease,
        source: source,
        step: AttachmentRequestStep.normalPut,
        abort: abort,
        activity: activity,
      );
      abort.throwIfAborted();
      if (_closed) {
        throw _transportFailure(
          AttachmentTransportError.closed,
          AttachmentRequestStep.normalPut,
          AttachmentTransportStage.sourceVerification,
        );
      }
      final verified = AttachmentVerifiedSource._(
        transportOwner: _sourceOwner,
        authorization: authorization,
        source: source,
        lease: lease,
      );
      _verifiedSources.add(verified);
      return verified;
    } on Object catch (error, stack) {
      failure = _CapturedFailure(
        _normalizePreDispatchFailure(
          error,
          AttachmentRequestStep.normalPut,
          AttachmentTransportStage.sourceVerification,
        ),
        stack,
      );
      if (lease != null) {
        await _closeLeasePreserving(
          lease,
          primary: failure,
          step: AttachmentRequestStep.normalPut,
          requestMayHaveReachedServer: false,
        );
      }
      failure.throwFailure();
    } finally {
      activity.stop();
      await _finishOperation(abort);
    }
  }

  Future<void> releaseSource(AttachmentVerifiedSource source) async {
    if (!identical(source._transportOwner, _sourceOwner)) {
      throw _transportFailure(
        AttachmentTransportError.sourceUnavailable,
        AttachmentRequestStep.normalPut,
        AttachmentTransportStage.cleanup,
      );
    }
    if (source._closed) {
      return;
    }
    source._closed = true;
    _verifiedSources.remove(source);
    final cleanupFailure = await _cleanupActions(
      <Future<void> Function()>[source._lease.close],
      step: AttachmentRequestStep.normalPut,
      requestMayHaveReachedServer: source._wasDispatched,
    );
    if (cleanupFailure != null) {
      throw cleanupFailure;
    }
  }

  Future<AttachmentProbeResponse> probe({
    required AttachmentProbeRequest request,
    required AttachmentTransportAuthorization authorization,
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    final payload = await _send(
      request: request,
      authorization: authorization,
      cancellationSignal: cancellationSignal,
      verifiedSource: null,
    );
    return _decodeResponse(
      request: request,
      payload: payload,
      decode: () => decodeAttachmentProbeResponse(
        request: request,
        statusCode: payload.statusCode,
        body: payload.body,
      ),
    );
  }

  Future<AttachmentFinalizeResponse> finalize({
    required AttachmentFinalizeRequest request,
    required AttachmentTransportAuthorization authorization,
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    final payload = await _send(
      request: request,
      authorization: authorization,
      cancellationSignal: cancellationSignal,
      verifiedSource: null,
    );
    return _decodeResponse(
      request: request,
      payload: payload,
      decode: () => decodeAttachmentFinalizeResponse(
        request: request,
        statusCode: payload.statusCode,
        body: payload.body,
      ),
    );
  }

  Future<AttachmentDavResponse> sendDav({
    required AttachmentDavRequest request,
    required AttachmentTransportAuthorization authorization,
    AttachmentCancellationSignal? cancellationSignal,
    AttachmentVerifiedSource? verifiedSource,
    int? fileSize,
  }) async {
    final payload = await _send(
      request: request,
      authorization: authorization,
      cancellationSignal: cancellationSignal,
      verifiedSource: verifiedSource,
    );
    return _decodeResponse(
      request: request,
      payload: payload,
      decode: () => decodeAttachmentDavResponse(
        request: request,
        statusCode: payload.statusCode,
        body: payload.body,
        fileSize: fileSize,
      ),
    );
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final operation in _activeOperations.toList(growable: false)) {
      operation.abort(AttachmentTransportError.closed, protocolCode: null);
    }
    AttachmentTransportException? firstFailure;
    for (final source in _verifiedSources.toList(growable: false)) {
      try {
        await releaseSource(source);
      } on AttachmentTransportException catch (error) {
        firstFailure ??= error;
      }
    }
    try {
      _client.close();
    } on Object {
      firstFailure ??= _transportFailure(
        AttachmentTransportError.cleanupFailed,
        AttachmentRequestStep.normalPut,
        AttachmentTransportStage.cleanup,
      );
    }
    if (firstFailure != null) {
      throw firstFailure;
    }
  }

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

AttachmentTransportException _normalizePreDispatchFailure(
  Object error,
  AttachmentRequestStep step,
  AttachmentTransportStage stage,
) => error is AttachmentTransportException
    ? error
    : _transportFailure(
        AttachmentTransportError.sourceUnavailable,
        step,
        stage,
      );

AttachmentTransportException _normalizePostDispatchFailure(
  Object error,
  AttachmentRequestStep step,
  AttachmentTransportStage stage, {
  int? statusCode,
}) => error is AttachmentTransportException
    ? error
    : _transportFailure(
        AttachmentTransportError.network,
        step,
        stage,
        statusCode: statusCode,
        requestMayHaveReachedServer: true,
      );

AttachmentTransportException _transportFailure(
  AttachmentTransportError code,
  AttachmentRequestStep step,
  AttachmentTransportStage stage, {
  int? statusCode,
  TalkProtocolErrorCode? protocolCode,
  bool requestMayHaveReachedServer = false,
}) => AttachmentTransportException(
  code,
  step: step,
  stage: stage,
  statusCode: statusCode,
  protocolCode: protocolCode,
  requestMayHaveReachedServer: requestMayHaveReachedServer,
);

void _validateOrigin(AttachmentRequest request) {
  final uri = request.uri;
  if (!request.server.hasSameOrigin(uri) ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw _transportFailure(
      AttachmentTransportError.invalidOrigin,
      request.step,
      AttachmentTransportStage.authorization,
    );
  }
  if (request is! AttachmentDavRequest ||
      request.step != AttachmentRequestStep.chunkMove) {
    return;
  }
  final rawDestination = request.headers['Destination'];
  final destination = rawDestination == null
      ? null
      : Uri.tryParse(rawDestination);
  if (destination == null ||
      !request.server.hasSameOrigin(destination) ||
      destination.userInfo.isNotEmpty ||
      destination.query.isNotEmpty ||
      destination.fragment.isNotEmpty) {
    throw _transportFailure(
      AttachmentTransportError.invalidOrigin,
      request.step,
      AttachmentTransportStage.authorization,
    );
  }
}

void _validateSourceChunk(
  List<int> chunk,
  AttachmentRequestStep step, {
  required AttachmentTransportStage stage,
  required bool requestMayHaveReachedServer,
}) {
  if (chunk.any((value) => value < 0 || value > 255)) {
    throw _transportFailure(
      AttachmentTransportError.sourceChanged,
      step,
      stage,
      requestMayHaveReachedServer: requestMayHaveReachedServer,
    );
  }
}

String _methodName(AttachmentHttpMethod method) => switch (method) {
  AttachmentHttpMethod.post => 'POST',
  AttachmentHttpMethod.put => 'PUT',
  AttachmentHttpMethod.mkcol => 'MKCOL',
  AttachmentHttpMethod.propfind => 'PROPFIND',
  AttachmentHttpMethod.move => 'MOVE',
  AttachmentHttpMethod.delete => 'DELETE',
};

String _basicAuthorization(AttachmentTransportAuthorization authorization) =>
    'Basic ${base64Encode(utf8.encode('${authorization.loginName}:'
    '${authorization.appPassword}'))}';

final class _Sha256Digest {
  static const int _mask = 0xffffffff;
  static const List<int> _roundConstants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  final List<int> _state = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final Uint8List _block = Uint8List(64);
  int _blockLength = 0;
  int _messageLength = 0;
  bool _closed = false;

  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('Digest is already closed.');
    }
    for (final byte in bytes) {
      _block[_blockLength++] = byte;
      _messageLength++;
      if (_blockLength == 64) {
        _compress();
        _blockLength = 0;
      }
    }
  }

  String close() {
    if (_closed) {
      throw StateError('Digest is already closed.');
    }
    _closed = true;
    final bitLength = _messageLength * 8;
    _block[_blockLength++] = 0x80;
    if (_blockLength > 56) {
      while (_blockLength < 64) {
        _block[_blockLength++] = 0;
      }
      _compress();
      _blockLength = 0;
    }
    while (_blockLength < 56) {
      _block[_blockLength++] = 0;
    }
    for (var shift = 56; shift >= 0; shift -= 8) {
      _block[_blockLength++] = (bitLength >> shift) & 0xff;
    }
    _compress();
    return _state
        .map((value) => value.toRadixString(16).padLeft(8, '0'))
        .join();
  }

  void _compress() {
    final words = Uint32List(64);
    for (var index = 0; index < 16; index++) {
      final offset = index * 4;
      words[index] =
          (_block[offset] << 24) |
          (_block[offset + 1] << 16) |
          (_block[offset + 2] << 8) |
          _block[offset + 3];
    }
    for (var index = 16; index < 64; index++) {
      final left = words[index - 15];
      final right = words[index - 2];
      final sigma0 =
          _rotateRight(left, 7) ^ _rotateRight(left, 18) ^ (left >>> 3);
      final sigma1 =
          _rotateRight(right, 17) ^ _rotateRight(right, 19) ^ (right >>> 10);
      words[index] =
          (words[index - 16] + sigma0 + words[index - 7] + sigma1) & _mask;
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];
    for (var index = 0; index < 64; index++) {
      final sum1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temporary1 =
          (h + sum1 + choose + _roundConstants[index] + words[index]) & _mask;
      final sum0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temporary2 = (sum0 + majority) & _mask;
      h = g;
      g = f;
      f = e;
      e = (d + temporary1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (temporary1 + temporary2) & _mask;
    }

    _state[0] = (_state[0] + a) & _mask;
    _state[1] = (_state[1] + b) & _mask;
    _state[2] = (_state[2] + c) & _mask;
    _state[3] = (_state[3] + d) & _mask;
    _state[4] = (_state[4] + e) & _mask;
    _state[5] = (_state[5] + f) & _mask;
    _state[6] = (_state[6] + g) & _mask;
    _state[7] = (_state[7] + h) & _mask;
  }

  int _rotateRight(int value, int count) =>
      ((value >>> count) | (value << (32 - count))) & _mask;
}
