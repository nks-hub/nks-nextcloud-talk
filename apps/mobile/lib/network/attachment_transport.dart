import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

part 'attachment_transport_http.part.dart';
part 'attachment_transport_lifecycle.part.dart';
part 'attachment_transport_validation.part.dart';

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

final class HttpAttachmentTransport with _HttpAttachmentTransportInternals {
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

  @override
  final http.Client _client;
  @override
  final AttachmentSourceProvider _sourceProvider;
  @override
  final Object _sourceOwner = Object();
  final Set<AttachmentVerifiedSource> _verifiedSources =
      <AttachmentVerifiedSource>{};
  @override
  final Set<_OperationAbortController> _activeOperations =
      <_OperationAbortController>{};
  @override
  final Duration connectTimeout;
  @override
  final Duration idleTimeout;
  @override
  final Duration cleanupTimeout;
  @override
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
}
