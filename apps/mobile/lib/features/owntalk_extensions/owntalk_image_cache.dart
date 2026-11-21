import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'owntalk_extensions_service.dart';

/// Background photos on disk, one file per account and SHA-256.
///
/// The name of a file is the hash of its content, so an entry never goes stale
/// and is never fetched twice. Only the newest few per account are kept, since
/// a conversation that changes its photo leaves the old file behind.
final class OwnTalkImageCache {
  OwnTalkImageCache._(
    this._directory, {
    Future<DateTime> Function(File file)? lastModified,
    Future<void> Function(File file)? deleteFile,
  }) : _lastModified = lastModified ?? _readLastModified,
       _deleteFile = deleteFile ?? _deleteFileDirect;

  static const int _maximumFilesPerAccount = 24;
  static const int _fileOperationConcurrency = 4;

  static Future<OwnTalkImageCache> openApplicationSupport() async {
    final support = await getApplicationSupportDirectory();
    return OwnTalkImageCache._(
      Directory('${support.path}${Platform.pathSeparator}owntalk-images'),
    );
  }

  static OwnTalkImageCache forTesting(
    Directory directory, {
    Future<DateTime> Function(File file)? lastModified,
    Future<void> Function(File file)? deleteFile,
  }) => OwnTalkImageCache._(
    directory,
    lastModified: lastModified,
    deleteFile: deleteFile,
  );

  final Directory _directory;
  final Future<DateTime> Function(File file) _lastModified;
  final Future<void> Function(File file) _deleteFile;
  final Map<String, Future<void>> _tails = {};

  static Future<DateTime> _readLastModified(File file) => file.lastModified();

  static Future<void> _deleteFileDirect(File file) => file.delete();

  Future<Uint8List?> read(String accountId, String sha256) {
    final file = _file(accountId, sha256);
    return _serialize(accountId, () async {
      try {
        return await file.exists() ? await file.readAsBytes() : null;
      } on FileSystemException {
        return null;
      }
    });
  }

  Future<void> write(String accountId, String sha256, Uint8List bytes) {
    final target = _file(accountId, sha256);
    return _serialize(accountId, () async {
      await _directory.create(recursive: true);
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      await _prune(accountId, keep: target.path);
    });
  }

  /// Drops every cached photo of an account.
  Future<void> removeAccount(String accountId) {
    final prefix = _prefix(accountId);
    return _serialize(accountId, () async {
      await _deleteFiles(await _accountFiles(prefix));
    });
  }

  Future<void> _prune(String accountId, {required String keep}) async {
    final files = await _accountFiles(_prefix(accountId));
    if (files.length <= _maximumFilesPerAccount) {
      return;
    }
    final candidates = [
      for (final file in files)
        if (file.path != keep) file,
    ];
    final dated = <({File file, DateTime modified})>[];
    var nextFile = 0;
    Future<void> readAges() async {
      while (nextFile < candidates.length) {
        final file = candidates[nextFile++];
        dated.add((file: file, modified: await _lastModified(file)));
      }
    }

    final workerCount = candidates.length < _fileOperationConcurrency
        ? candidates.length
        : _fileOperationConcurrency;
    await Future.wait(List.generate(workerCount, (_) => readAges()));
    dated.sort((a, b) => a.modified.compareTo(b.modified));
    await _deleteFiles(
      dated
          .take(files.length - _maximumFilesPerAccount)
          .map((entry) => entry.file),
    );
  }

  Future<void> _deleteFiles(Iterable<File> files) async {
    final pending = files.toList(growable: false);
    Object? firstError;
    StackTrace? firstStackTrace;
    var nextFile = 0;

    Future<void> deleteNext() async {
      while (nextFile < pending.length) {
        final file = pending[nextFile++];
        try {
          await _deleteFile(file);
        } on Object catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }
    }

    final workerCount = pending.length < _fileOperationConcurrency
        ? pending.length
        : _fileOperationConcurrency;
    await Future.wait(List.generate(workerCount, (_) => deleteNext()));
    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  Future<List<File>> _accountFiles(String prefix) async {
    if (!await _directory.exists()) {
      return const [];
    }
    return [
      await for (final entry in _directory.list())
        if (entry is File && entry.uri.pathSegments.last.startsWith(prefix))
          entry,
    ];
  }

  Future<T> _serialize<T>(String accountId, Future<T> Function() operation) {
    final previous = _tails[accountId] ?? Future<void>.value();
    final completer = Completer<T>();
    late final Future<void> next;
    next = previous
        .then((_) async {
          try {
            completer.complete(await operation());
          } on Object catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .whenComplete(() {
          if (identical(_tails[accountId], next)) {
            _tails.remove(accountId);
          }
        });
    _tails[accountId] = next;
    return completer.future;
  }

  static String _prefix(String accountId) {
    AccountId.parse(accountId);
    return '${sha256.convert(utf8.encode(accountId))}-';
  }

  File _file(String accountId, String sha256) {
    if (!isOwnTalkImageHash(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', 'not a lower-case SHA-256');
    }
    return File(
      '${_directory.path}${Platform.pathSeparator}${_prefix(accountId)}$sha256.jpg',
    );
  }
}

/// Turns a hash from the settings document into image bytes: from the disk
/// cache when it holds them, otherwise from the server (and then cached).
final class OwnTalkImageLoader {
  OwnTalkImageLoader({required this.service, this.cache});

  final OwnTalkExtensionsService service;

  /// `null` when the disk cache could not be opened; photos then come straight
  /// from the server each time.
  final OwnTalkImageCache? cache;

  /// The bytes of the photo [sha256], or `null` when the server no longer has
  /// it or sent something that is not it. A failure that may pass, such as
  /// being offline or rate limited, throws [OwnTalkExtensionsException].
  Future<Uint8List?> load({
    required String accountId,
    required String roomToken,
    required String sha256,
  }) async {
    final cached = await _guard(() => cache?.read(accountId, sha256));
    if (cached != null) {
      return cached;
    }
    final result = await service.fetchImage(
      accountId: accountId,
      roomToken: roomToken,
      sha256: sha256,
    );
    switch (result) {
      case OwnTalkImageLoaded(:final bytes):
        // The file name is the hash of its content, so anything else is not
        // the photo the document named.
        if (_hashOf(bytes) != sha256) {
          return null;
        }
        await _guard(() => cache?.write(accountId, sha256, bytes));
        return bytes;
      case OwnTalkImageMissing():
        return null;
      case OwnTalkImageFetchFailure(:final kind, :final retryAfter):
        throw OwnTalkExtensionsException(switch (kind) {
          OwnTalkExtensionsFailureKind.reauthenticationRequired =>
            OwnTalkExtensionsError.reauthenticationRequired,
          OwnTalkExtensionsFailureKind.rateLimited =>
            OwnTalkExtensionsError.rateLimited,
          OwnTalkExtensionsFailureKind.unavailable =>
            OwnTalkExtensionsError.unavailable,
          _ => OwnTalkExtensionsError.invalidResponse,
        }, retryAfter: retryAfter);
    }
  }

  static String _hashOf(Uint8List bytes) => sha256.convert(bytes).toString();

  /// The cache is an optimisation; a broken disk must not lose the photo.
  Future<T?> _guard<T>(FutureOr<T?> Function() action) async {
    try {
      return await action();
    } on Object {
      return null;
    }
  }
}

final ownTalkImageCacheProvider = FutureProvider<OwnTalkImageCache>(
  (ref) => OwnTalkImageCache.openApplicationSupport(),
);

typedef OwnTalkImageKey = ({String accountId, String roomToken, String sha256});

/// How long a photo that could not be loaded waits before the next try.
const Duration ownTalkImageRetryPause = Duration(seconds: 30);

/// The bytes of one conversation's background photo, `null` while there is
/// none to show. A temporary failure is retried after a pause; the caller
/// keeps showing whatever it falls back to meanwhile.
final ownTalkRoomImageProvider = FutureProvider.autoDispose
    .family<Uint8List?, OwnTalkImageKey>((ref, key) async {
      OwnTalkImageCache? cache;
      try {
        cache = await ref.watch(ownTalkImageCacheProvider.future);
      } on Object {
        cache = null;
      }
      final loader = OwnTalkImageLoader(
        service: ref.watch(ownTalkExtensionsServiceProvider),
        cache: cache,
      );
      try {
        return await loader.load(
          accountId: key.accountId,
          roomToken: key.roomToken,
          sha256: key.sha256,
        );
      } on OwnTalkExtensionsException catch (error) {
        if (error.code != OwnTalkExtensionsError.reauthenticationRequired &&
            error.code != OwnTalkExtensionsError.accountMissing &&
            error.code != OwnTalkExtensionsError.credentialMissing) {
          final timer = Timer(
            error.retryAfter ?? ownTalkImageRetryPause,
            ref.invalidateSelf,
          );
          ref.onDispose(timer.cancel);
        }
        return null;
      }
    });
