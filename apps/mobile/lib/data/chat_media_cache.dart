import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'chat_media_repository.dart';

/// Keeps recently shown chat previews in memory.
///
/// The preview providers are auto-disposed, so scrolling a picture out of view
/// and back used to refetch it over the network every time. Entries are
/// account scoped and bounded by both count and total bytes.
///
/// [ChatMediaDiskCache] sits behind this one and carries previews across a
/// restart.
final class ChatMediaCache {
  ChatMediaCache({
    this.maximumEntries = 48,
    this.maximumBytes = 32 * 1024 * 1024,
  });

  final int maximumEntries;
  final int maximumBytes;
  final Map<String, ChatMediaImage> _entries = <String, ChatMediaImage>{};
  final Map<String, Future<void>> _pending = {};
  int _bytes = 0;

  int get length => _entries.length;

  int get byteLength => _bytes;

  /// Orders a preview's complete cache fill and retry eviction across providers.
  Future<T> withEntry<T>(String key, Future<T> Function() operation) {
    final previous = _pending[key] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    // An unsuccessful load must not prevent the next retry from taking its turn.
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending[key] = settled;
    return result.whenComplete(() {
      if (identical(_pending[key], settled)) _pending.remove(key);
    });
  }

  static String keyOf({required String accountId, required Uri uri}) =>
      '$accountId\u0000$uri';

  ChatMediaImage? read(String key) {
    final hit = _entries.remove(key);
    if (hit == null) {
      return null;
    }
    // Reinserting marks the entry as most recently used.
    _entries[key] = hit;
    return hit;
  }

  void write(String key, ChatMediaImage image) {
    final size = image.body.lengthInBytes;
    if (size > maximumBytes) {
      return;
    }
    final replaced = _entries.remove(key);
    if (replaced != null) {
      _bytes -= replaced.body.lengthInBytes;
    }
    _entries[key] = image;
    _bytes += size;
    while (_entries.length > maximumEntries || _bytes > maximumBytes) {
      final oldest = _entries.keys.first;
      final evicted = _entries.remove(oldest)!;
      _bytes -= evicted.body.lengthInBytes;
    }
  }

  /// Drops the in-memory previews for one account.
  void evictAccount(String accountId) {
    final prefix = '$accountId\u0000';
    final doomed = _entries.keys
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final key in doomed) {
      _bytes -= _entries.remove(key)!.body.lengthInBytes;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  void evict(String key) {
    final removed = _entries.remove(key);
    if (removed != null) _bytes -= removed.body.lengthInBytes;
  }
}

/// File name a downloaded voice message is cached under.
///
/// Shared between the provider that writes the file and account removal, so
/// exactly one rule decides both what is written and what is deleted.
String chatVoiceCacheKey({required String accountId, required int messageId}) {
  return '${_voiceAccountPrefix(accountId)}$messageId';
}

final RegExp _voiceUnsafeCharacter = RegExp(r'[^A-Za-z0-9._-]');
const int _voiceMetadataConcurrency = 8;
const int _voiceDeletionConcurrency = 4;

String _voiceAccountPrefix(String accountId) =>
    '$accountId-'.replaceAll(_voiceUnsafeCharacter, '_');

/// Deletes every cached voice file belonging to one account.
///
/// Unlike previews, voice files are plain audio under a predictable name, so
/// removal matches on the account prefix rather than a digest.
// ponytail: prefix match. Account ids are UUIDv4, so the sanitised prefix of
// one can never be the prefix of another; revisit only if ids stop being
// UUIDs.
Future<void> evictAccountVoiceFiles({
  required Directory directory,
  required String accountId,
  Future<void> Function(File file)? deleteFile,
}) async {
  final prefix = _voiceAccountPrefix(accountId);
  if (!directory.existsSync()) {
    return;
  }
  final pending = <File>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is File && p.basename(entity.path).startsWith(prefix)) {
      pending.add(entity);
    }
  }
  final remove = deleteFile ?? _deleteVoiceFile;
  var nextFile = 0;

  Future<void> deleteNext() async {
    while (nextFile < pending.length) {
      final file = pending[nextFile++];
      try {
        await remove(file);
      } on FileSystemException {
        // Already gone, or the platform is holding it open; either way there
        // is nothing else this step can do about that one file.
      }
    }
  }

  final workerCount = pending.length < _voiceDeletionConcurrency
      ? pending.length
      : _voiceDeletionConcurrency;
  await Future.wait(List.generate(workerCount, (_) => deleteNext()));
}

/// Keeps one account's voice cache under [maximumBytes], dropping the least
/// recently written files first.
///
/// Voice messages are pure cache: [ChatMediaRepository.loadVoiceFile] rewrites
/// the file on every play, so an evicted one costs a refetch and nothing else.
/// That rewrite is also why the file currently playing is always the newest,
/// and therefore the last one this would ever drop.
///
/// [ChatMediaDiskCache] cannot be reused here even though it prunes the same
/// way: it indexes digest-named files holding a content type, a newline and
/// then the body, while a voice file has to stay a plain audio file under a
/// predictable name that a platform player can open.
// ponytail: stats every file in the directory on each call. The bound holds a
// few hundred entries, so an on-disk index is only worth it if that grows.
Future<void> pruneAccountVoiceFiles({
  required Directory directory,
  required String accountId,
  int maximumBytes = 64 * 1024 * 1024,
  Future<FileStat> Function(File file)? statFile,
  Future<void> Function(File file)? deleteFile,
}) async {
  if (!directory.existsSync()) {
    return;
  }
  final prefix = _voiceAccountPrefix(accountId);
  final candidates = <File>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is File &&
        p.basename(entity.path).startsWith(prefix) &&
        !ChatMediaRepository.isVoiceDownloadInProgress(entity)) {
      candidates.add(entity);
    }
  }
  final owned = <({File file, int bytes, DateTime modified})>[];
  var total = 0;
  var nextCandidate = 0;
  final readStat = statFile ?? _readVoiceFileStat;

  Future<void> readNextStat() async {
    while (nextCandidate < candidates.length) {
      final file = candidates[nextCandidate++];
      final stat = await readStat(file);
      owned.add((file: file, bytes: stat.size, modified: stat.modified));
      total += stat.size;
    }
  }

  final statWorkerCount = candidates.length < _voiceMetadataConcurrency
      ? candidates.length
      : _voiceMetadataConcurrency;
  await Future.wait(List.generate(statWorkerCount, (_) => readNextStat()));
  if (total <= maximumBytes) {
    return;
  }
  owned.sort((a, b) => a.modified.compareTo(b.modified));
  final remove = deleteFile ?? _deleteVoiceFile;
  var nextOwned = 0;
  var plannedBytes = 0;

  Future<void> deleteNext() async {
    while (nextOwned < owned.length && total - plannedBytes > maximumBytes) {
      final entry = owned[nextOwned++];
      plannedBytes += entry.bytes;
      var deleted = false;
      try {
        await remove(entry.file);
        deleted = true;
      } on FileSystemException {
        // Already gone, or the platform is holding it open; a later worker
        // continues with the next-oldest candidate when the bound needs it.
      }
      plannedBytes -= entry.bytes;
      if (deleted) {
        total -= entry.bytes;
      }
    }
  }

  final deleteWorkerCount = owned.length < _voiceDeletionConcurrency
      ? owned.length
      : _voiceDeletionConcurrency;
  await Future.wait(List.generate(deleteWorkerCount, (_) => deleteNext()));
}

Future<FileStat> _readVoiceFileStat(File file) => file.stat();

Future<void> _deleteVoiceFile(File file) => file.delete();

final class _ChatMediaDiskEntry {
  _ChatMediaDiskEntry({
    required this.bytes,
    required this.touchedAt,
    Object? contentVersion,
  }) : contentVersion = contentVersion ?? Object();

  final int bytes;
  final DateTime touchedAt;

  // A read can refresh the stamp without replacing the bytes.
  final Object contentVersion;
}

/// Persists chat previews under the private app cache directory so a cold
/// start does not refetch every picture over the network.
///
/// Entries live in a per-account subdirectory and every path component is a
/// SHA-256 digest: the cached bytes are conversation content, so neither the
/// room token nor the remote file name may be readable from the file system.
/// The store is bounded by [maximumBytes] and drops the least recently read
/// entries first. A file holds the content type, a newline, then the body.
final class ChatMediaDiskCache {
  ChatMediaDiskCache({
    required this.rootDirectory,
    this.maximumBytes = 64 * 1024 * 1024,
    Future<FileStat> Function(File file)? statFile,
    Future<void> Function(File file)? deleteFile,
    Future<void> Function(File file, DateTime touchedAt)? touchFile,
  }) : _statFile = statFile ?? _readStat,
       _deleteFile = deleteFile ?? _deleteDirect,
       _touchFile = touchFile ?? _touchDirect;

  /// Longest accepted content type header, which bounds how much of a corrupt
  /// file is scanned before it is discarded.
  static const int _maximumHeaderBytes = 64;
  static const int _scanConcurrency = 8;
  static const int _deleteConcurrency = 4;
  static final RegExp _partialFileSuffix = RegExp(r'\.part-\d+$');

  /// Resolved once, on first use, because it needs a platform channel.
  final Future<Directory> Function() rootDirectory;
  final int maximumBytes;
  final Future<FileStat> Function(File file) _statFile;
  final Future<void> Function(File file) _deleteFile;
  final Future<void> Function(File file, DateTime touchedAt) _touchFile;
  final Map<String, _ChatMediaDiskEntry> _index = {};
  final Set<String> _touching = {};
  final Map<String, Future<void>> _pendingMutations = {};
  final Map<String, Set<Future<void>>> _pendingWrites = {};

  Directory? _root;
  Future<Directory>? _opening;
  int _bytes = 0;
  int _temporaryFileNonce = 0;

  int get byteLength => _bytes;

  int get length => _index.length;

  static Future<FileStat> _readStat(File file) => file.stat();

  static Future<void> _deleteDirect(File file) => file.delete();

  static Future<void> _touchDirect(File file, DateTime touchedAt) async {
    await file.setLastModified(touchedAt);
  }

  Future<void> evict({required String accountId, required Uri uri}) async {
    final Directory root;
    try {
      root = await _open();
    } on FileSystemException {
      return;
    }
    await _delete(_pathFor(root, accountId: accountId, uri: uri));
  }

  Future<ChatMediaImage?> read({
    required String accountId,
    required Uri uri,
  }) async {
    final Directory root;
    try {
      root = await _open();
    } on FileSystemException {
      return null;
    }
    final path = _pathFor(root, accountId: accountId, uri: uri);
    final entry = _index[path];
    if (entry == null) {
      return null;
    }
    final file = File(path);
    final Uint8List stored;
    try {
      stored = await file.readAsBytes();
    } on FileSystemException {
      if (identical(_index[path]?.contentVersion, entry.contentVersion)) {
        _drop(path);
      }
      return null;
    }
    if (!identical(_index[path]?.contentVersion, entry.contentVersion)) {
      return null;
    }
    final separator = stored.indexOf(0x0a);
    if (separator <= 0 ||
        separator > _maximumHeaderBytes ||
        separator + 1 >= stored.length) {
      await _delete(
        path,
        shouldDelete: () =>
            identical(_index[path]?.contentVersion, entry.contentVersion),
      );
      return null;
    }
    _index[path] = _ChatMediaDiskEntry(
      bytes: entry.bytes,
      touchedAt: DateTime.now(),
      contentVersion: entry.contentVersion,
    );
    _scheduleTouch(path, file);
    return ChatMediaImage.takeOwnership(
      body: Uint8List.sublistView(stored, separator + 1),
      contentType: ascii.decode(
        Uint8List.sublistView(stored, 0, separator),
        allowInvalid: true,
      ),
    );
  }

  void _scheduleTouch(String path, File file) {
    if (_touching.add(path)) {
      unawaited(_persistTouch(path, file));
    }
  }

  Future<void> _persistTouch(String path, File file) async {
    try {
      var entry = _index[path];
      while (entry != null) {
        try {
          await _touchFile(file, entry.touchedAt);
        } catch (_) {
          // Losing a stamp only changes the eviction order after a restart.
        }
        final latest = _index[path];
        if (identical(latest, entry)) break;
        entry = latest;
      }
    } finally {
      _touching.remove(path);
    }
  }

  Future<void> write({
    required String accountId,
    required Uri uri,
    required ChatMediaImage image,
  }) async {
    if (image.contentType.contains('\n') ||
        image.contentType.length >= _maximumHeaderBytes ||
        image.body.isEmpty) {
      return;
    }
    final header = ascii.encode(image.contentType);
    final total = header.length + 1 + image.body.lengthInBytes;
    if (total > maximumBytes) {
      return;
    }
    // Register before the first await so suspension cannot miss this write.
    final settled = Completer<void>();
    final pending = _pendingWrites.putIfAbsent(
      accountId,
      () => <Future<void>>{},
    );
    pending.add(settled.future);
    final bool stored;
    try {
      stored = await _store(
        accountId: accountId,
        uri: uri,
        body: image.body,
        header: header,
        total: total,
      );
    } finally {
      pending.remove(settled.future);
      if (pending.isEmpty) _pendingWrites.remove(accountId);
      settled.complete();
    }

    if (stored) await _prune();
  }

  Future<bool> _store({
    required String accountId,
    required Uri uri,
    required Uint8List body,
    required List<int> header,
    required int total,
  }) async {
    final Directory root;
    try {
      root = await _open();
    } on FileSystemException {
      return false;
    }
    final file = File(_pathFor(root, accountId: accountId, uri: uri));
    final temporary = File('${file.path}.part-${_temporaryFileNonce++}');
    RandomAccessFile? output;
    try {
      await file.parent.create(recursive: true);
      output = await temporary.open(mode: FileMode.write);
      await output.writeFrom(header);
      await output.writeByte(0x0a);
      await output.writeFrom(body);
      await output.flush();
      await output.close();
      output = null;
      final path = file.path;
      await _mutatePath(path, () async {
        final replacesEntry =
            _index.containsKey(path) || _touching.contains(path);
        await temporary.rename(path);
        _drop(path);
        _index[path] = _ChatMediaDiskEntry(
          bytes: total,
          touchedAt: DateTime.now(),
        );
        _bytes += total;
        if (replacesEntry) {
          // An older touch can land after the OS has moved the new file.
          _scheduleTouch(path, file);
        }
      });
    } on FileSystemException {
      return false;
    } finally {
      try {
        await output?.close();
      } on FileSystemException {
        // The partial entry is removed below once the platform releases it.
      }
      try {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      } on FileSystemException {
        // A later scan removes any incomplete file left by a stopped process.
      }
    }
    return true;
  }

  /// Drops an account's disk previews after its admitted writes settle.
  ///
  /// The caller must stop new writes for this account before purging it.
  Future<void> evictAccount(String accountId) async {
    final pending = _pendingWrites[accountId];
    if (pending != null) await Future.wait(pending.toList(growable: false));
    final Directory root;
    try {
      root = await _open();
    } on FileSystemException {
      return;
    }
    final directory = Directory(_directoryFor(root, accountId));
    for (final path in _index.keys.toList(growable: false)) {
      if (p.isWithin(directory.path, path)) {
        _drop(path);
      }
    }
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Nothing was cached for this account, or it is already gone.
    }
  }

  Future<Directory> _open() {
    final opened = _root;
    if (opened != null) {
      return Future<Directory>.value(opened);
    }
    return _opening ??= _scan();
  }

  Future<Directory> _scan() async {
    final root = await rootDirectory();
    await root.create(recursive: true);
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        if (_partialFileSuffix.hasMatch(p.basename(entity.path))) {
          try {
            await _deleteFile(entity);
          } on FileSystemException {
            // It remains an ignored cache miss and a later scan can retry.
          }
          continue;
        }
        files.add(entity);
      }
    }
    var nextFile = 0;
    Future<void> indexFiles() async {
      while (nextFile < files.length) {
        final file = files[nextFile++];
        final stat = await _statFile(file);
        if (stat.type != FileSystemEntityType.file) continue;
        _index[file.path] = _ChatMediaDiskEntry(
          bytes: stat.size,
          touchedAt: stat.modified,
        );
        _bytes += stat.size;
      }
    }

    final workerCount = files.length < _scanConcurrency
        ? files.length
        : _scanConcurrency;
    await Future.wait(List.generate(workerCount, (_) => indexFiles()));
    _root = root;
    // A shrunken bound, or bytes written by an older build, are enforced here
    // rather than left to sit until the next write.
    await _prune();
    return root;
  }

  Future<void> _prune() async {
    if (_bytes <= maximumBytes) {
      return;
    }
    // ponytail: full sort of the in-memory index, which holds a few hundred
    // previews at this bound. A heap is worth it only if the bound grows a lot.
    final candidates = _index.entries.toList()
      ..sort((a, b) => a.value.touchedAt.compareTo(b.value.touchedAt));
    var nextCandidate = 0;
    Future<void> deleteNext() async {
      while (_bytes > maximumBytes && nextCandidate < candidates.length) {
        final entry = candidates[nextCandidate++];
        await _delete(
          entry.key,
          shouldDelete: () =>
              _bytes > maximumBytes &&
              identical(_index[entry.key], entry.value),
        );
      }
    }

    final workerCount = candidates.length < _deleteConcurrency
        ? candidates.length
        : _deleteConcurrency;
    await Future.wait(List.generate(workerCount, (_) => deleteNext()));
  }

  Future<void> _delete(String path, {bool Function()? shouldDelete}) =>
      _mutatePath(path, () async {
        if (shouldDelete?.call() == false) return;
        _drop(path);
        try {
          await _deleteFile(File(path));
        } on FileSystemException {
          // Already gone; the index stopped counting it either way.
        }
      });

  // A dispatched delete can still unlink a later rename to the same path.
  Future<void> _mutatePath(
    String path,
    Future<void> Function() operation,
  ) async {
    final previous = _pendingMutations[path];
    final released = Completer<void>();
    _pendingMutations[path] = released.future;
    try {
      if (previous != null) await previous;
      await operation();
    } finally {
      if (identical(_pendingMutations[path], released.future)) {
        _pendingMutations.remove(path);
      }
      released.complete();
    }
  }

  void _drop(String path) {
    final removed = _index.remove(path);
    if (removed != null) {
      _bytes -= removed.bytes;
    }
  }

  String _directoryFor(Directory root, String accountId) =>
      p.join(root.path, _digest(accountId));

  String _pathFor(
    Directory root, {
    required String accountId,
    required Uri uri,
  }) => p.join(
    _directoryFor(root, accountId),
    _digest(ChatMediaCache.keyOf(accountId: accountId, uri: uri)),
  );

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}
