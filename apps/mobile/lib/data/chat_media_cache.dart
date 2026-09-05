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
  int _bytes = 0;

  int get length => _entries.length;

  int get byteLength => _bytes;

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

  /// Drops everything belonging to one account. Account removal is not
  /// implemented yet, so this has no caller; it exists because cached bytes
  /// must never outlive their account once removal lands. See
  /// [ChatMediaDiskCache.evictAccount] for where both have to be called.
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
}

/// File name a downloaded voice message is cached under.
///
/// Shared between the provider that writes the file and account removal, so
/// exactly one rule decides both what is written and what is deleted.
String chatVoiceCacheKey({required String accountId, required int messageId}) {
  return '${_voiceAccountPrefix(accountId)}$messageId';
}

final RegExp _voiceUnsafeCharacter = RegExp(r'[^A-Za-z0-9._-]');

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
}) async {
  final prefix = _voiceAccountPrefix(accountId);
  if (!directory.existsSync()) {
    return;
  }
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || !p.basename(entity.path).startsWith(prefix)) {
      continue;
    }
    try {
      await entity.delete();
    } on FileSystemException {
      // Already gone, or the platform is holding it open; either way there is
      // nothing else this step can do about that one file.
    }
  }
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
}) async {
  if (!directory.existsSync()) {
    return;
  }
  final prefix = _voiceAccountPrefix(accountId);
  final owned = <({File file, int bytes, DateTime modified})>[];
  var total = 0;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || !p.basename(entity.path).startsWith(prefix)) {
      continue;
    }
    final stat = await entity.stat();
    owned.add((file: entity, bytes: stat.size, modified: stat.modified));
    total += stat.size;
  }
  if (total <= maximumBytes) {
    return;
  }
  owned.sort((a, b) => a.modified.compareTo(b.modified));
  for (final entry in owned) {
    if (total <= maximumBytes) {
      return;
    }
    try {
      await entry.file.delete();
      total -= entry.bytes;
    } on FileSystemException {
      // Already gone, or the platform is holding it open; either way the next
      // call sees the real size again.
    }
  }
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
  });

  /// Longest accepted content type header, which bounds how much of a corrupt
  /// file is scanned before it is discarded.
  static const int _maximumHeaderBytes = 64;

  /// Resolved once, on first use, because it needs a platform channel.
  final Future<Directory> Function() rootDirectory;
  final int maximumBytes;
  final Map<String, ({int bytes, DateTime touchedAt})> _index = {};

  Directory? _root;
  Future<Directory>? _opening;
  int _bytes = 0;

  int get byteLength => _bytes;

  int get length => _index.length;

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
    final Uint8List stored;
    try {
      stored = await File(path).readAsBytes();
    } on FileSystemException {
      _drop(path);
      return null;
    }
    final separator = stored.indexOf(0x0a);
    if (separator <= 0 ||
        separator > _maximumHeaderBytes ||
        separator + 1 >= stored.length) {
      await _delete(path);
      return null;
    }
    final touchedAt = DateTime.now();
    _index[path] = (bytes: entry.bytes, touchedAt: touchedAt);
    try {
      await File(path).setLastModified(touchedAt);
    } on FileSystemException {
      // Losing the recency stamp only costs this entry an earlier eviction.
    }
    return ChatMediaImage(
      body: Uint8List.sublistView(stored, separator + 1),
      contentType: ascii.decode(
        Uint8List.sublistView(stored, 0, separator),
        allowInvalid: true,
      ),
    );
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
    final Directory root;
    try {
      root = await _open();
    } on FileSystemException {
      return;
    }
    final file = File(_pathFor(root, accountId: accountId, uri: uri));
    final payload = Uint8List(total)
      ..setRange(0, header.length, header)
      ..[header.length] = 0x0a
      ..setRange(header.length + 1, total, image.body);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(payload, flush: true);
    } on FileSystemException {
      return;
    }
    _drop(file.path);
    _index[file.path] = (bytes: total, touchedAt: DateTime.now());
    _bytes += total;
    await _prune();
  }

  /// Drops every cached byte belonging to one account.
  ///
  /// Account removal is not implemented yet — see the unchecked
  /// "Bezpečné odebrání účtu" item in the maintainer notes. Whatever lands there has
  /// to await this and call [ChatMediaCache.evictAccount] next to
  /// `CredentialVault.deleteAppPassword`, in the same `AccountRepository` step
  /// that deletes the account row, or conversation bytes outlive the account
  /// that was allowed to see them. The same call belongs on sign-out.
  Future<void> evictAccount(String accountId) async {
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
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final stat = await entity.stat();
      _index[entity.path] = (bytes: stat.size, touchedAt: stat.modified);
      _bytes += stat.size;
    }
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
    final ordered = _index.entries.toList()
      ..sort((a, b) => a.value.touchedAt.compareTo(b.value.touchedAt));
    for (final entry in ordered) {
      if (_bytes <= maximumBytes) {
        return;
      }
      await _delete(entry.key);
    }
  }

  Future<void> _delete(String path) async {
    _drop(path);
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone; the index stopped counting it either way.
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
