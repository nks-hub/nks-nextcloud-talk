import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';

const int durableAttachmentDefaultMaximumBytes = 512 * 1024 * 1024;

enum DurableAttachmentSourceError {
  cancelled,
  sourceTooLarge,
  emptySource,
  invalidHandle,
  sourceUnavailable,
  sourceChanged,
  invalidWriteSession,
}

final class DurableAttachmentSourceException implements Exception {
  const DurableAttachmentSourceException(this.code);

  final DurableAttachmentSourceError code;

  @override
  String toString() => 'DurableAttachmentSourceException(${code.name})';
}

/// A path-bearing write capability that can only be finalized by its store.
///
/// The path is intentionally exposed only for native plugins that require a
/// filesystem destination. Persisted application state must keep [handle]
/// values from the resulting [PreparedAttachmentSource], never this path.
final class DurableAttachmentWriteSession {
  DurableAttachmentWriteSession._({
    required this._store,
    required this.filePath,
    required this._sourceId,
  });

  final DurableAttachmentSourceStore _store;
  final String _sourceId;
  final String filePath;
  bool _completed = false;

  bool get isCompleted => _completed;

  bool matchesReturnedPath(String path) => _store._pathsEqual(filePath, path);

  Future<PreparedAttachmentSource> commit({
    required String mimeType,
    required String displayName,
  }) => _store._commitExternalWrite(
    this,
    mimeType: mimeType,
    displayName: displayName,
  );

  Future<void> abort() => _store._abortExternalWrite(this);

  Future<void> removeLateWrite() => _store._removeLateExternalWrite(this);
}

/// Private, restart-resolvable storage for attachment bytes.
///
/// Handles contain only a random identifier. Files are immutable after the
/// staging rename, and active leases delay deletion until every reader closes.
final class DurableAttachmentSourceStore implements AttachmentSourceProvider {
  DurableAttachmentSourceStore({
    required Directory root,
    this.maximumSourceBytes = durableAttachmentDefaultMaximumBytes,
  }) : _configuredRoot = root {
    if (maximumSourceBytes < 1 ||
        maximumSourceBytes > attachmentMaximumSourceBytes) {
      throw ArgumentError.value(
        maximumSourceBytes,
        'maximumSourceBytes',
        'must be within the attachment protocol bounds',
      );
    }
  }

  static const String _handlePrefix = 'nctalk-media-v1:';
  static final RegExp _sourceIdPattern = RegExp(r'^[0-9a-f]{32}$');
  static final RegExp _extensionPattern = RegExp(r'^\.[a-z0-9]{1,12}$');
  static const int _readChunkBytes = 64 * 1024;

  final Directory _configuredRoot;
  final int maximumSourceBytes;
  final Random _random = Random.secure();
  final Map<String, _SourceLeaseState> _leaseStates =
      <String, _SourceLeaseState>{};

  Future<void>? _initialization;
  late String _rootPath;
  late String _sourcesPath;
  late String _stagingPath;

  static Future<DurableAttachmentSourceStore> openApplicationSupport({
    int maximumSourceBytes = durableAttachmentDefaultMaximumBytes,
  }) async {
    final support = await getApplicationSupportDirectory();
    final store = DurableAttachmentSourceStore(
      root: Directory(p.join(support.path, 'attachment-sources-v1')),
      maximumSourceBytes: maximumSourceBytes,
    );
    await store.initialize();
    await store.cleanupTemporaryFiles();
    return store;
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await _configuredRoot.create(recursive: true);
    _rootPath = p.normalize(
      p.absolute(await _configuredRoot.resolveSymbolicLinks()),
    );
    final sources = Directory(p.join(_rootPath, 'sources'));
    final staging = Directory(p.join(_rootPath, 'staging'));
    await sources.create(recursive: true);
    await staging.create(recursive: true);
    _sourcesPath = p.normalize(
      p.absolute(await sources.resolveSymbolicLinks()),
    );
    _stagingPath = p.normalize(
      p.absolute(await staging.resolveSymbolicLinks()),
    );
    _requireContainedDirectory(_sourcesPath);
    _requireContainedDirectory(_stagingPath);
  }

  Future<PreparedAttachmentSource> copyFromStream({
    required Stream<List<int>> stream,
    required String mimeType,
    required String displayName,
    int? expectedByteLength,
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (expectedByteLength != null &&
        (expectedByteLength < 1 || expectedByteLength > maximumSourceBytes)) {
      throw DurableAttachmentSourceException(
        expectedByteLength < 1
            ? DurableAttachmentSourceError.emptySource
            : DurableAttachmentSourceError.sourceTooLarge,
      );
    }
    _throwIfCancelled(cancellationSignal);
    final session = await beginExternalWrite(fileExtension: '.copy');
    final output = await File(session.filePath).open(mode: FileMode.writeOnly);
    final iterator = StreamIterator<List<int>>(stream);
    final digestOutput = _DigestOutput();
    final digestInput = sha256.startChunkedConversion(digestOutput);
    final cancellationTrigger = Completer<void>.sync();
    final registration = cancellationSignal?.register(() {
      if (!cancellationTrigger.isCompleted) {
        cancellationTrigger.complete();
      }
    });
    var outputClosed = false;
    var byteLength = 0;
    try {
      _throwIfCancelled(cancellationSignal);
      while (await _moveNextOrCancellation(
        iterator,
        cancellationSignal == null ? null : cancellationTrigger.future,
      )) {
        _throwIfCancelled(cancellationSignal);
        final chunk = iterator.current;
        if (chunk.isEmpty) {
          continue;
        }
        byteLength += chunk.length;
        if (byteLength > maximumSourceBytes) {
          throw const DurableAttachmentSourceException(
            DurableAttachmentSourceError.sourceTooLarge,
          );
        }
        digestInput.add(chunk);
        await output.writeFrom(chunk);
      }
      _throwIfCancelled(cancellationSignal);
      if (byteLength == 0) {
        throw const DurableAttachmentSourceException(
          DurableAttachmentSourceError.emptySource,
        );
      }
      if (expectedByteLength != null && expectedByteLength != byteLength) {
        throw const DurableAttachmentSourceException(
          DurableAttachmentSourceError.sourceChanged,
        );
      }
      digestInput.close();
      await output.flush();
      await output.close();
      outputClosed = true;
      return await _commitWrite(
        session,
        byteLength: byteLength,
        digest: digestOutput.value,
        mimeType: mimeType,
        displayName: displayName,
      );
    } finally {
      registration?.detach();
      await iterator.cancel();
      if (!outputClosed) {
        await output.close();
      }
      if (!session._completed) {
        await session.abort();
      }
    }
  }

  Future<DurableAttachmentWriteSession> beginExternalWrite({
    required String fileExtension,
  }) async {
    await initialize();
    final extension = fileExtension.toLowerCase();
    if (!_extensionPattern.hasMatch(extension)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidWriteSession,
      );
    }
    for (var attempt = 0; attempt < 32; attempt++) {
      final sourceId = _newSourceId();
      final stagingPath = _checkedChild(_stagingPath, '$sourceId$extension');
      final sourcePath = _sourcePath(sourceId);
      if (!await File(stagingPath).exists() &&
          !await File(sourcePath).exists()) {
        return DurableAttachmentWriteSession._(
          store: this,
          filePath: stagingPath,
          sourceId: sourceId,
        );
      }
    }
    throw const DurableAttachmentSourceException(
      DurableAttachmentSourceError.invalidWriteSession,
    );
  }

  Future<AttachmentSourceObservation> observe(
    AttachmentSourceHandle handle,
  ) async {
    final lease = await open(handle);
    final digestOutput = _DigestOutput();
    final digestInput = sha256.startChunkedConversion(digestOutput);
    var byteLength = 0;
    try {
      await for (final chunk in lease.openRead()) {
        byteLength += chunk.length;
        digestInput.add(chunk);
      }
      digestInput.close();
    } finally {
      await lease.close();
    }
    return AttachmentSourceObservation(
      handle: handle,
      byteLength: byteLength,
      sha256: AttachmentSha256.parse(digestOutput.value.toString()),
    );
  }

  Future<String> resolveVerifiedPath(PreparedAttachmentSource source) async {
    final observation = await observe(source.handle);
    if (!observation.matches(source)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.sourceChanged,
      );
    }
    return (await _resolveSource(source.handle)).path;
  }

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    await initialize();
    _throwIfCancelled(cancellationSignal);
    final sourceId = _parseSourceId(handle);
    final state = _leaseStates.putIfAbsent(sourceId, _SourceLeaseState.new);
    if (state.deletion != null) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.sourceUnavailable,
      );
    }
    state.leaseCount++;
    try {
      final resolved = await _resolveSourceId(sourceId);
      _throwIfCancelled(cancellationSignal);
      return _RandomAccessAttachmentLease(
        file: File(resolved.path),
        byteLength: resolved.byteLength,
        onClose: () => _releaseLease(sourceId, state),
      );
    } catch (_) {
      _releaseLease(sourceId, state);
      rethrow;
    }
  }

  Future<void> discard(AttachmentSourceHandle handle) async {
    await initialize();
    final sourceId = _parseSourceId(handle);
    final state = _leaseStates.putIfAbsent(sourceId, _SourceLeaseState.new);
    final existing = state.deletion;
    if (existing != null) {
      return existing.future;
    }
    final deletion = Completer<void>();
    state.deletion = deletion;
    unawaited(_deleteWhenReleased(sourceId, state, deletion));
    return deletion.future;
  }

  Future<int> cleanupTemporaryFiles() async {
    await initialize();
    var removed = 0;
    await for (final entity in Directory(
      _stagingPath,
    ).list(followLinks: false)) {
      if (entity is File) {
        final normalized = p.normalize(p.absolute(entity.path));
        if (!p.isWithin(_stagingPath, normalized)) {
          continue;
        }
        await entity.delete();
        removed++;
      }
    }
    return removed;
  }

  Future<PreparedAttachmentSource> _commitExternalWrite(
    DurableAttachmentWriteSession session, {
    required String mimeType,
    required String displayName,
  }) async {
    _requireSession(session);
    final resolved = await _resolveStagingFile(session);
    if (resolved.byteLength < 1) {
      await session.abort();
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.emptySource,
      );
    }
    if (resolved.byteLength > maximumSourceBytes) {
      await session.abort();
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.sourceTooLarge,
      );
    }
    final digest = await sha256.bind(File(resolved.path).openRead()).first;
    return _commitWrite(
      session,
      byteLength: resolved.byteLength,
      digest: digest,
      mimeType: mimeType,
      displayName: displayName,
    );
  }

  Future<PreparedAttachmentSource> _commitWrite(
    DurableAttachmentWriteSession session, {
    required int byteLength,
    required Digest digest,
    required String mimeType,
    required String displayName,
  }) async {
    _requireSession(session);
    final handle = AttachmentSourceHandle.parse(
      '$_handlePrefix${session._sourceId}',
    );
    final source = PreparedAttachmentSource(
      handle: handle,
      ownership: AttachmentSourceOwnership.appOwnedCopy,
      byteLength: byteLength,
      sha256: AttachmentSha256.parse(digest.toString()),
      mimeType: mimeType,
      displayName: displayName,
    );
    final staging = await _resolveStagingFile(session);
    if (staging.byteLength != byteLength) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.sourceChanged,
      );
    }
    final destination = _sourcePath(session._sourceId);
    if (await File(destination).exists()) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidWriteSession,
      );
    }
    await File(staging.path).rename(destination);
    session._completed = true;
    return source;
  }

  Future<void> _abortExternalWrite(
    DurableAttachmentWriteSession session,
  ) async {
    _requireSession(session, allowCompleted: true);
    if (session._completed) {
      return;
    }
    final path = p.normalize(p.absolute(session.filePath));
    if (!p.isWithin(_stagingPath, path)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidWriteSession,
      );
    }
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    session._completed = true;
  }

  Future<void> _removeLateExternalWrite(
    DurableAttachmentWriteSession session,
  ) async {
    _requireSession(session, allowCompleted: true);
    final path = p.normalize(p.absolute(session.filePath));
    if (!p.isWithin(_stagingPath, path)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidWriteSession,
      );
    }
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
        session._completed = true;
        return;
      } on FileSystemException {
        if (attempt == 19) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<_ResolvedFile> _resolveStagingFile(
    DurableAttachmentWriteSession session,
  ) async {
    _requireSession(session);
    final lexicalPath = p.normalize(p.absolute(session.filePath));
    if (!p.isWithin(_stagingPath, lexicalPath)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidWriteSession,
      );
    }
    final type = await FileSystemEntity.type(lexicalPath, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.sourceUnavailable,
      );
    }
    final file = File(lexicalPath);
    final resolvedPath = p.normalize(
      p.absolute(await file.resolveSymbolicLinks()),
    );
    if (!p.isWithin(_stagingPath, resolvedPath)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidWriteSession,
      );
    }
    return _ResolvedFile(
      path: resolvedPath,
      byteLength: (await file.stat()).size,
    );
  }

  Future<_ResolvedFile> _resolveSource(AttachmentSourceHandle handle) =>
      _resolveSourceId(_parseSourceId(handle));

  Future<_ResolvedFile> _resolveSourceId(String sourceId) async {
    final lexicalPath = _sourcePath(sourceId);
    final type = await FileSystemEntity.type(lexicalPath, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.sourceUnavailable,
      );
    }
    final file = File(lexicalPath);
    final resolvedPath = p.normalize(
      p.absolute(await file.resolveSymbolicLinks()),
    );
    if (!p.isWithin(_sourcesPath, resolvedPath)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidHandle,
      );
    }
    return _ResolvedFile(
      path: resolvedPath,
      byteLength: (await file.stat()).size,
    );
  }

  Future<void> _deleteWhenReleased(
    String sourceId,
    _SourceLeaseState state,
    Completer<void> deletion,
  ) async {
    try {
      if (state.leaseCount > 0) {
        await (state.drained ??= Completer<void>()).future;
      }
      final path = _sourcePath(sourceId);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const DurableAttachmentSourceException(
          DurableAttachmentSourceError.invalidHandle,
        );
      }
      if (type == FileSystemEntityType.file) {
        await File(path).delete();
      }
      deletion.complete();
    } on Object catch (error, stackTrace) {
      deletion.completeError(error, stackTrace);
    } finally {
      if (identical(_leaseStates[sourceId], state)) {
        _leaseStates.remove(sourceId);
      }
    }
  }

  void _releaseLease(String sourceId, _SourceLeaseState state) {
    if (state.leaseCount < 1) {
      return;
    }
    state.leaseCount--;
    if (state.leaseCount == 0) {
      final drained = state.drained;
      if (drained != null && !drained.isCompleted) {
        drained.complete();
      }
      if (state.deletion == null && identical(_leaseStates[sourceId], state)) {
        _leaseStates.remove(sourceId);
      }
    }
  }

  void _requireSession(
    DurableAttachmentWriteSession session, {
    bool allowCompleted = false,
  }) {
    if (!identical(session._store, this) ||
        (!allowCompleted && session._completed)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidWriteSession,
      );
    }
  }

  String _parseSourceId(AttachmentSourceHandle handle) {
    final value = handle.value;
    if (!value.startsWith(_handlePrefix)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidHandle,
      );
    }
    final sourceId = value.substring(_handlePrefix.length);
    if (!_sourceIdPattern.hasMatch(sourceId)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidHandle,
      );
    }
    return sourceId;
  }

  String _sourcePath(String sourceId) =>
      _checkedChild(_sourcesPath, '$sourceId.source');

  String _checkedChild(String parent, String name) {
    final child = p.normalize(p.absolute(p.join(parent, name)));
    if (!p.isWithin(parent, child)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidHandle,
      );
    }
    return child;
  }

  void _requireContainedDirectory(String path) {
    if (!p.isWithin(_rootPath, path)) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.invalidHandle,
      );
    }
  }

  bool _pathsEqual(String left, String right) =>
      p.equals(p.normalize(p.absolute(left)), p.normalize(p.absolute(right)));

  String _newSourceId() {
    final buffer = StringBuffer();
    for (var index = 0; index < 16; index++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static void _throwIfCancelled(
    AttachmentCancellationSignal? cancellationSignal,
  ) {
    if (cancellationSignal?.isCancelled ?? false) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.cancelled,
      );
    }
  }

  static Future<bool> _moveNextOrCancellation(
    StreamIterator<List<int>> iterator,
    Future<void>? cancellation,
  ) {
    final next = iterator.moveNext();
    if (cancellation == null) {
      return next;
    }
    return Future.any<bool>(<Future<bool>>[
      next,
      cancellation.then((_) => false),
    ]);
  }
}

final class _ResolvedFile {
  const _ResolvedFile({required this.path, required this.byteLength});

  final String path;
  final int byteLength;
}

final class _SourceLeaseState {
  int leaseCount = 0;
  Completer<void>? drained;
  Completer<void>? deletion;
}

final class _RandomAccessAttachmentLease implements AttachmentSourceLease {
  _RandomAccessAttachmentLease({
    required this._file,
    required this._byteLength,
    required this._onClose,
  });

  final File _file;
  final int _byteLength;
  final void Function() _onClose;
  bool _closed = false;
  int _activeReaders = 0;
  Completer<void>? _readersDrained;
  Future<void>? _closeFuture;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) async* {
    if (_closed) {
      throw StateError('Attachment source lease is closed.');
    }
    if (offset < 0 || offset > _byteLength) {
      throw RangeError.range(offset, 0, _byteLength, 'offset');
    }
    if (length != null && length < 0) {
      throw RangeError.value(length, 'length');
    }
    _activeReaders++;
    _readersDrained ??= Completer<void>();
    RandomAccessFile? reader;
    try {
      reader = await _file.open(mode: FileMode.read);
      await reader.setPosition(offset);
      var remaining = length == null
          ? _byteLength - offset
          : min(length, _byteLength - offset);
      while (remaining > 0) {
        final chunk = await reader.read(
          min(DurableAttachmentSourceStore._readChunkBytes, remaining),
        );
        if (chunk.isEmpty) {
          break;
        }
        remaining -= chunk.length;
        yield chunk;
      }
    } finally {
      await reader?.close();
      _activeReaders--;
      if (_activeReaders == 0) {
        final drained = _readersDrained;
        if (drained != null && !drained.isCompleted) {
          drained.complete();
        }
      }
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    if (_activeReaders > 0) {
      await _readersDrained!.future;
    }
    _onClose();
  }
}

final class _DigestOutput implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final digest = _value;
    if (digest == null) {
      throw StateError('SHA-256 conversion did not complete.');
    }
    return digest;
  }

  @override
  void add(Digest data) {
    if (_value != null) {
      throw StateError('SHA-256 conversion emitted more than one digest.');
    }
    _value = data;
  }

  @override
  void close() {}
}
