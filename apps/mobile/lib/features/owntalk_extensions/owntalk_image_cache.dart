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
  OwnTalkImageCache._(this._directory);

  static const int _maximumFilesPerAccount = 24;

  static Future<OwnTalkImageCache> openApplicationSupport() async {
    final support = await getApplicationSupportDirectory();
    return OwnTalkImageCache._(
      Directory('${support.path}${Platform.pathSeparator}owntalk-images'),
    );
  }

  static OwnTalkImageCache forTesting(Directory directory) =>
      OwnTalkImageCache._(directory);

  final Directory _directory;
  Future<void> _tail = Future<void>.value();

  Future<Uint8List?> read(String accountId, String sha256) {
    final file = _file(accountId, sha256);
    return _serialize(() async {
      try {
        return await file.exists() ? await file.readAsBytes() : null;
      } on FileSystemException {
        return null;
      }
    });
  }

  Future<void> write(String accountId, String sha256, Uint8List bytes) {
    final target = _file(accountId, sha256);
    return _serialize(() async {
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
    return _serialize(() async {
      for (final file in await _accountFiles(prefix)) {
        await file.delete();
      }
    });
  }

  Future<void> _prune(String accountId, {required String keep}) async {
    final files = await _accountFiles(_prefix(accountId));
    if (files.length <= _maximumFilesPerAccount) {
      return;
    }
    final dated = [
      for (final file in files)
        if (file.path != keep) (file: file, modified: file.lastModifiedSync()),
    ]..sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in dated.take(files.length - _maximumFilesPerAccount)) {
      await entry.file.delete();
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

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
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
