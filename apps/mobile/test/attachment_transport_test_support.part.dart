part of 'attachment_transport_test.dart';

const String _loginName = 'fixture-user';
const String _appPassword = 'fixture-app-password';
final String _authorizationHeader =
    'Basic ${base64Encode(utf8.encode('$_loginName:$_appPassword'))}';
const String _sourceHandle = 'app-owned-synthetic-source';
const String _normalSha256 =
    '7fa36b95d5c98859ed72b4787f3c28b29eaa103970786755c9711cbb19be631c';
const String _chunkSha256 =
    '9f9f5111f7b27a781f1f1ddde5ebc2dd2b796bfc7365c9c28b548e564176929f';
final List<int> _normalBytes = utf8.encode('hello attachment');
final List<int> _chunkBytes = utf8.encode('0123456789abcdef');
final ServerBase _server = ServerBase.parse(
  'https://cloud.example.invalid/nextcloud',
);
final AccountId _account = AccountId.parse('account-a');
final ConversationToken _room = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidAttachmentModel,
);
final DavUserId _davUser = DavUserId.parse('fixture-user');
final DavRelativePath _remotePath = DavRelativePath.parse(
  'Talk/Synthetic room/Draft/temp.bin',
);
final AttachmentTransportAuthorization _authorization =
    AttachmentTransportAuthorization(
      accountId: _account,
      server: _server,
      loginName: _loginName,
      appPassword: _appPassword,
    );

HttpAttachmentTransport _transport(http.Client client) =>
    HttpAttachmentTransport(
      client: client,
      sourceProvider: _MemorySourceProvider(const <String, List<int>>{}),
    );

AttachmentRequestContext _context(int requestNumber) =>
    AttachmentRequestContext(
      accountId: _account,
      requestId: AttachmentRequestId.parse('attachment-request-$requestNumber'),
      jobId: AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
      server: _server,
      roomToken: _room,
      capabilityGeneration: 7,
      contractRevision: attachmentReplayContractRevision,
    );

PreparedAttachmentSource _source(
  List<int> bytes, {
  required String sha256,
  String handle = _sourceHandle,
}) => PreparedAttachmentSource(
  handle: AttachmentSourceHandle.parse(handle),
  ownership: AttachmentSourceOwnership.appOwnedCopy,
  byteLength: bytes.length,
  sha256: AttachmentSha256.parse(sha256),
  mimeType: 'application/octet-stream',
  displayName: 'attachment.bin',
);

AttachmentFinalizeRequest _finalizeRequest(
  int requestNumber, {
  _FinalizeMetadataScope metadataScope = _FinalizeMetadataScope.none,
}) => AttachmentFinalizeRequest(
  context: _context(requestNumber),
  remoteTemporaryPath: _remotePath,
  source: _source(_normalBytes, sha256: _normalSha256),
  referenceId: ChatReferenceId.parse('11111111-1111-4111-8111-111111111111'),
  metadata: AttachmentMetadata(
    kind: AttachmentMessageKind.file,
    caption: metadataScope == _FinalizeMetadataScope.none
        ? null
        : 'Synthetic caption',
    replyTo: metadataScope == _FinalizeMetadataScope.reply ? 42 : null,
    threadId: metadataScope == _FinalizeMetadataScope.namedThread ? 42 : null,
    threadTitle: metadataScope == _FinalizeMetadataScope.namedThread
        ? 'Synthetic thread'
        : null,
    silent: metadataScope != _FinalizeMetadataScope.none,
  ),
);

enum _FinalizeMetadataScope { none, reply, namedThread }

DavUploadSessionId _uploadSession() =>
    DavUploadSessionId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');

Uint8List _probeSuccessBody() => _ocsBody(
  status: 'ok',
  statusCode: 200,
  data: <String, Object?>{
    'folder': 'Talk/Synthetic room/Draft',
    'renames': <Object?>[
      <String, Object?>{'photo.jpg': 'photo (1).jpg'},
    ],
  },
);

Uint8List _finalizeSuccessBody() => _ocsBody(
  status: 'ok',
  statusCode: 200,
  data: <String, Object?>{
    'renames': <Object?>[
      <String, Object?>{'attachment.bin': 'attachment (1).bin'},
    ],
  },
);

Uint8List _ocsFailureBody(int statusCode) => _ocsBody(
  status: 'failure',
  statusCode: statusCode,
  data: <String, Object?>{},
);

Uint8List _ocsBody({
  required String status,
  required int statusCode,
  required Object? data,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': status,
          'statuscode': statusCode,
          'message': 'Synthetic response',
        },
        'data': data,
      },
    }),
  ),
);

String _emptyDavManifest(Uri sessionUri) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">'
    '<d:response><d:href>${sessionUri.path}/</d:href>'
    '<d:propstat><d:prop><d:resourcetype><d:collection/>'
    '</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
    '</d:propstat></d:response></d:multistatus>';

Matcher _transportError(
  AttachmentTransportError code, {
  AttachmentTransportStage? stage,
  bool? requestMayHaveReachedServer,
}) {
  var matcher = isA<AttachmentTransportException>().having(
    (error) => error.code,
    'code',
    code,
  );
  if (stage != null) {
    matcher = matcher.having((error) => error.stage, 'stage', stage);
  }
  if (requestMayHaveReachedServer != null) {
    matcher = matcher.having(
      (error) => error.requestMayHaveReachedServer,
      'requestMayHaveReachedServer',
      requestMayHaveReachedServer,
    );
  }
  return matcher;
}

final class _MemorySourceProvider implements AttachmentSourceProvider {
  _MemorySourceProvider(
    Map<String, List<int>> sources, {
    this.stallClose = false,
  }) : _sources = Map<String, Uint8List>.unmodifiable(
         sources.map((key, value) => MapEntry(key, Uint8List.fromList(value))),
       );

  final Map<String, Uint8List> _sources;
  final bool stallClose;
  int openCount = 0;
  _MemorySourceLease? lastLease;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    openCount++;
    final bytes = _sources[handle.value];
    if (bytes == null) {
      throw StateError('Synthetic source missing.');
    }
    return lastLease = _MemorySourceLease(bytes, stallClose: stallClose);
  }
}

final class _MemorySourceLease implements AttachmentSourceLease {
  _MemorySourceLease(this._bytes, {required this.stallClose});

  final Uint8List _bytes;
  final bool stallClose;
  int readCount = 0;
  int physicalBytesRead = 0;
  int closeCount = 0;
  final List<(int, int?)> requestedRanges = <(int, int?)>[];
  final Completer<void> closed = Completer<void>();

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) {
    readCount++;
    requestedRanges.add((offset, length));
    final end = length == null || offset + length > _bytes.length
        ? _bytes.length
        : offset + length;
    physicalBytesRead += end - offset;
    final chunks = <List<int>>[];
    for (var chunkOffset = offset; chunkOffset < end; chunkOffset += 3) {
      final chunkEnd = chunkOffset + 3 < end ? chunkOffset + 3 : end;
      chunks.add(_bytes.sublist(chunkOffset, chunkEnd));
    }
    return Stream<List<int>>.fromIterable(chunks);
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (!closed.isCompleted) {
      closed.complete();
    }
    if (stallClose) {
      await Completer<void>().future;
    }
  }
}

final class _BackpressureSourceProvider implements AttachmentSourceProvider {
  _BackpressureSourceProvider({required this.handle, required List<int> bytes})
    : _bytes = Uint8List.fromList(bytes);

  final String handle;
  final Uint8List _bytes;
  int uploadChunksPulled = 0;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle sourceHandle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (sourceHandle.value != handle) {
      throw StateError('Synthetic source missing.');
    }
    return _BackpressureSourceLease(
      _bytes,
      onUploadChunk: () => uploadChunksPulled++,
    );
  }
}

final class _BackpressureSourceLease implements AttachmentSourceLease {
  _BackpressureSourceLease(this._bytes, {required this.onUploadChunk});

  final Uint8List _bytes;
  final void Function() onUploadChunk;
  int _readCount = 0;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) {
    _readCount++;
    final end = length == null || offset + length > _bytes.length
        ? _bytes.length
        : offset + length;
    final range = _bytes.sublist(offset, end);
    if (_readCount == 1) {
      return Stream<List<int>>.value(range);
    }
    return _uploadStream(range);
  }

  Stream<List<int>> _uploadStream(List<int> range) async* {
    for (final byte in range) {
      onUploadChunk();
      yield <int>[byte];
    }
  }

  @override
  Future<void> close() async {}
}

final class _DelayedSourceProvider implements AttachmentSourceProvider {
  final Completer<void> openStarted = Completer<void>();
  final Completer<AttachmentSourceLease> _opened =
      Completer<AttachmentSourceLease>();
  _MemorySourceLease? lease;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) {
    openStarted.complete();
    return _opened.future;
  }

  void completeWith(List<int> bytes) {
    final openedLease = _MemorySourceLease(
      Uint8List.fromList(bytes),
      stallClose: false,
    );
    lease = openedLease;
    _opened.complete(openedLease);
  }
}

final class _CancelFailingSourceProvider implements AttachmentSourceProvider {
  _CancelFailingSourceProvider(List<int> bytes)
    : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  _CancelFailingSourceLease? lease;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async => lease = _CancelFailingSourceLease(_bytes);
}

final class _CancelFailingSourceLease implements AttachmentSourceLease {
  _CancelFailingSourceLease(this._bytes);

  final Uint8List _bytes;
  int _readCount = 0;
  int uploadCancelCount = 0;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) {
    _readCount++;
    final end = length == null || offset + length > _bytes.length
        ? _bytes.length
        : offset + length;
    final range = _bytes.sublist(offset, end);
    if (_readCount == 1) {
      return Stream<List<int>>.value(range);
    }
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () => controller.add(range),
      onCancel: () {
        uploadCancelCount++;
        return Future<void>.error(StateError('Synthetic cancel failure.'));
      },
    );
    return controller.stream;
  }

  @override
  Future<void> close() async {}
}

final class _InspectableCancellationSignal
    implements AttachmentCancellationSignal {
  _InspectableCancellationSignal(this._delegate);

  final AttachmentCancellationSignal _delegate;
  int _activeRegistrationCount = 0;
  int registrationCount = 0;
  int maximumActiveRegistrationCount = 0;
  int callbackInvocationCount = 0;

  int get activeRegistrationCount => _activeRegistrationCount;

  @override
  bool get isCancelled => _delegate.isCancelled;

  @override
  AttachmentCancellationRegistration register(
    FutureOr<void> Function() action,
  ) {
    registrationCount++;
    _activeRegistrationCount++;
    if (_activeRegistrationCount > maximumActiveRegistrationCount) {
      maximumActiveRegistrationCount = _activeRegistrationCount;
    }
    final registration = _delegate.register(() {
      callbackInvocationCount++;
      return action();
    });
    return _InspectableCancellationRegistration(
      registration,
      onDetach: () => _activeRegistrationCount--,
    );
  }
}

final class _InspectableCancellationRegistration
    implements AttachmentCancellationRegistration {
  _InspectableCancellationRegistration(
    this._delegate, {
    required this.onDetach,
  });

  final AttachmentCancellationRegistration _delegate;
  final void Function() onDetach;
  bool _detached = false;

  @override
  void detach() {
    if (_detached) {
      return;
    }
    _detached = true;
    _delegate.detach();
    onDetach();
  }
}

final class _SilentPreCancelledSignal implements AttachmentCancellationSignal {
  final AttachmentCancellationController _delegate =
      AttachmentCancellationController();

  @override
  bool get isCancelled => true;

  @override
  AttachmentCancellationRegistration register(
    FutureOr<void> Function() action,
  ) => _delegate.signal.register(() {});
}
