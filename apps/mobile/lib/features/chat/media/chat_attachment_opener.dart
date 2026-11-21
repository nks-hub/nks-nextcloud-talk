import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/app_database.dart';
import '../../../data/chat_media_repository.dart';

enum ChatAttachmentOpenResult {
  opened,
  reauthenticationRequired,
  tooLarge,
  invalid,
  downloadFailed,
  storageFailed,
  openFailed,
}

abstract interface class ChatAttachmentOpenAction {
  Future<ChatAttachmentOpenResult> open({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  });
}

abstract interface class ChatAttachmentFileLauncher {
  Future<bool> open({required String path, required String contentType});
}

typedef ChatAttachmentLeaseCancellation = void Function();
typedef ChatAttachmentLeaseScheduler =
    ChatAttachmentLeaseCancellation Function(
      Duration duration,
      Future<void> Function() onExpired,
    );

abstract interface class ChatAttachmentCacheMaintenance {
  Future<void> run();

  void dispose();
}

typedef ChatAttachmentCacheMaintenanceFactory =
    ChatAttachmentCacheMaintenance Function();

final class PlatformChatAttachmentFileLauncher
    implements ChatAttachmentFileLauncher {
  const PlatformChatAttachmentFileLauncher();

  @override
  Future<bool> open({required String path, required String contentType}) async {
    try {
      final result = await OpenFilex.open(path, type: contentType);
      return result.type == ResultType.done;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

final class ChatAttachmentOpener implements ChatAttachmentOpenAction {
  factory ChatAttachmentOpener({
    required ChatMediaRepository repository,
    Future<Directory> Function()? cacheDirectory,
    ChatAttachmentFileLauncher launcher =
        const PlatformChatAttachmentFileLauncher(),
    int maximumCacheBytes = _defaultAttachmentCacheBytes,
    int maximumCacheEntries = _defaultAttachmentCacheEntries,
    Duration postLaunchLease = _defaultPostLaunchLease,
    Duration incompleteGracePeriod = _defaultIncompleteGracePeriod,
    ChatAttachmentLeaseScheduler leaseScheduler = _scheduleChatAttachmentLease,
    DateTime Function() now = DateTime.now,
  }) {
    if (maximumCacheBytes < 1) {
      throw ArgumentError.value(
        maximumCacheBytes,
        'maximumCacheBytes',
        'must be positive',
      );
    }
    if (maximumCacheEntries < 1) {
      throw ArgumentError.value(
        maximumCacheEntries,
        'maximumCacheEntries',
        'must be positive',
      );
    }
    if (postLaunchLease <= Duration.zero) {
      throw ArgumentError.value(
        postLaunchLease,
        'postLaunchLease',
        'must be positive',
      );
    }
    if (incompleteGracePeriod <= Duration.zero) {
      throw ArgumentError.value(
        incompleteGracePeriod,
        'incompleteGracePeriod',
        'must be positive',
      );
    }
    return ChatAttachmentOpener._(
      repository,
      cacheDirectory ?? getApplicationCacheDirectory,
      launcher,
      maximumCacheBytes,
      maximumCacheEntries,
      postLaunchLease,
      incompleteGracePeriod,
      leaseScheduler,
      now,
    );
  }

  ChatAttachmentOpener._(
    this._repository,
    this._cacheDirectory,
    this._launcher,
    this._maximumCacheBytes,
    this._maximumCacheEntries,
    this._postLaunchLease,
    this._incompleteGracePeriod,
    this._leaseScheduler,
    this._now,
  );

  static final Map<String, _ChatAttachmentCacheCoordinator> _cacheCoordinators =
      <String, _ChatAttachmentCacheCoordinator>{};

  final ChatMediaRepository _repository;
  final Future<Directory> Function() _cacheDirectory;
  final ChatAttachmentFileLauncher _launcher;
  final int _maximumCacheBytes;
  final int _maximumCacheEntries;
  final Duration _postLaunchLease;
  final Duration _incompleteGracePeriod;
  final ChatAttachmentLeaseScheduler _leaseScheduler;
  final DateTime Function() _now;

  @override
  Future<ChatAttachmentOpenResult> open({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async {
    final File localFile;
    final Directory downloadDirectory;
    final Directory accountDirectory;
    final _ChatAttachmentCacheCoordinator cacheCoordinator;
    final String contentType;
    try {
      final root = await _cacheDirectory();
      accountDirectory = chatAttachmentCacheAccountDirectory(
        rootDirectory: root,
        accountId: account.id,
      );
      await accountDirectory.create(recursive: true);
      downloadDirectory = await accountDirectory.createTemp('download-');
      cacheCoordinator = _chatAttachmentCacheCoordinator(accountDirectory);
      cacheCoordinator.protect(downloadDirectory.path);
      await cacheCoordinator.prune(
        accountDirectory: accountDirectory,
        maximumBytes: _maximumCacheBytes,
        maximumEntries: _maximumCacheEntries,
        incompleteGracePeriod: _incompleteGracePeriod,
        now: _now,
      );
      localFile = File(
        '${downloadDirectory.path}${Platform.pathSeparator}'
        '${chatAttachmentFileName(fileName)}',
      );
    } on FileSystemException {
      return ChatAttachmentOpenResult.storageFailed;
    } on PlatformException {
      return ChatAttachmentOpenResult.storageFailed;
    } on MissingPluginException {
      return ChatAttachmentOpenResult.storageFailed;
    }

    var opened = false;
    var leaseScheduled = false;
    try {
      contentType = await _repository.downloadOriginalToFile(
        account: account,
        uri: uri,
        expectedContentType: expectedContentType,
        target: localFile,
        onProgress: onProgress,
      );
      if (!_repository.isAccountActive(account.id)) {
        return ChatAttachmentOpenResult.reauthenticationRequired;
      }
      await _writeCompletedAttachmentMarker(
        downloadDirectory,
        _now().add(_postLaunchLease),
      );
      opened = await _launcher.open(
        path: localFile.path,
        contentType: contentType,
      );
      if (opened) {
        final leaseUntil = _now().add(_postLaunchLease);
        await _writeCompletedAttachmentMarker(downloadDirectory, leaseUntil);
        leaseScheduled = cacheCoordinator.retainForLease(
          path: downloadDirectory.path,
          leaseUntil: leaseUntil,
          scheduler: _leaseScheduler,
          accountDirectory: accountDirectory,
          maximumBytes: _maximumCacheBytes,
          maximumEntries: _maximumCacheEntries,
          incompleteGracePeriod: _incompleteGracePeriod,
          now: _now,
        );
        await cacheCoordinator.prune(
          accountDirectory: accountDirectory,
          maximumBytes: _maximumCacheBytes,
          maximumEntries: _maximumCacheEntries,
          incompleteGracePeriod: _incompleteGracePeriod,
          now: _now,
        );
      }
      return opened
          ? ChatAttachmentOpenResult.opened
          : ChatAttachmentOpenResult.openFailed;
    } on ChatMediaRepositoryException catch (error) {
      return switch (error.code) {
        ChatMediaRepositoryError.credentialMissing =>
          ChatAttachmentOpenResult.reauthenticationRequired,
        ChatMediaRepositoryError.responseTooLarge =>
          ChatAttachmentOpenResult.tooLarge,
        ChatMediaRepositoryError.invalidUri ||
        ChatMediaRepositoryError.invalidResponse =>
          ChatAttachmentOpenResult.invalid,
        ChatMediaRepositoryError.unavailable =>
          ChatAttachmentOpenResult.downloadFailed,
      };
    } on FileSystemException {
      return ChatAttachmentOpenResult.storageFailed;
    } on Object {
      // Credential vault backends can fail outside the repository error enum.
      return ChatAttachmentOpenResult.downloadFailed;
    } finally {
      if (!opened) {
        try {
          await downloadDirectory.delete(recursive: true);
        } on FileSystemException {
          // Account removal may have already cleared this directory.
        }
      }
      if (!leaseScheduled) {
        cacheCoordinator.unprotect(downloadDirectory.path);
        cacheCoordinator.releaseIfIdle();
      }
    }
  }
}

const int _defaultAttachmentCacheBytes = 256 * 1024 * 1024;
const int _defaultAttachmentCacheEntries = 16;
const Duration _defaultPostLaunchLease = Duration(minutes: 15);
// A 2 GiB transfer can legitimately take many hours on a poor mobile link.
// Forty-eight hours reclaims crash leftovers without guessing that a slow,
// currently unmarked transfer is dead; opener-owned live paths are protected
// independently and are never removed by this age rule.
const Duration _defaultIncompleteGracePeriod = Duration(hours: 48);
const String _completedAttachmentMarkerName = '.open-complete';

Future<void> _writeCompletedAttachmentMarker(
  Directory directory,
  DateTime leaseUntil,
) {
  final leaseMillis = leaseUntil.toUtc().millisecondsSinceEpoch;
  return File(
    '${directory.path}${Platform.pathSeparator}$_completedAttachmentMarkerName',
  ).writeAsString(
    'leaseUntil=$leaseMillis\n',
    mode: FileMode.append,
    flush: true,
  );
}

_ChatAttachmentCacheCoordinator _chatAttachmentCacheCoordinator(
  Directory accountDirectory,
) {
  return ChatAttachmentOpener._cacheCoordinators.putIfAbsent(
    accountDirectory.path,
    () => _ChatAttachmentCacheCoordinator(accountDirectory.path),
  );
}

void _releaseChatAttachmentCacheCoordinator(
  String path,
  _ChatAttachmentCacheCoordinator coordinator,
) {
  if (coordinator.isIdle &&
      identical(ChatAttachmentOpener._cacheCoordinators[path], coordinator)) {
    ChatAttachmentOpener._cacheCoordinators.remove(path);
  }
}

final class _ChatAttachmentCacheCoordinator {
  _ChatAttachmentCacheCoordinator(this._directoryPath);

  final String _directoryPath;
  final Set<String> _protectedPaths = <String>{};
  final Map<String, ChatAttachmentLeaseCancellation> _leaseCancellations =
      <String, ChatAttachmentLeaseCancellation>{};
  Future<void> _pruneTail = Future<void>.value();
  var _activePrunes = 0;

  bool get isIdle =>
      _protectedPaths.isEmpty &&
      _leaseCancellations.isEmpty &&
      _activePrunes == 0;

  void protect(String path) => _protectedPaths.add(path);

  void unprotect(String path) => _protectedPaths.remove(path);

  void releaseIfIdle() {
    _releaseChatAttachmentCacheCoordinator(_directoryPath, this);
  }

  bool retainForLease({
    required String path,
    required DateTime leaseUntil,
    required ChatAttachmentLeaseScheduler scheduler,
    required Directory accountDirectory,
    required int maximumBytes,
    required int maximumEntries,
    required Duration incompleteGracePeriod,
    required DateTime Function() now,
  }) {
    Future<void> expire() async {
      _leaseCancellations.remove(path);
      final remaining = leaseUntil.difference(now());
      if (remaining > Duration.zero) {
        try {
          _leaseCancellations[path] = scheduler(remaining, expire);
          return;
        } on Object {
          // Fall through and release a lease that cannot be rescheduled.
        }
      }
      unprotect(path);
      await prune(
        accountDirectory: accountDirectory,
        maximumBytes: maximumBytes,
        maximumEntries: maximumEntries,
        incompleteGracePeriod: incompleteGracePeriod,
        now: now,
      );
    }

    try {
      _leaseCancellations[path] = scheduler(
        leaseUntil.difference(now()),
        expire,
      );
      return true;
    } on Object {
      unprotect(path);
      return false;
    }
  }

  Future<DateTime?> prune({
    required Directory accountDirectory,
    required int maximumBytes,
    required int maximumEntries,
    required Duration incompleteGracePeriod,
    required DateTime Function() now,
  }) {
    _activePrunes++;
    final result = _pruneTail.then<DateTime?>((_) async {
      try {
        return await _pruneChatAttachmentOpenCache(
          accountDirectory: accountDirectory,
          maximumBytes: maximumBytes,
          maximumEntries: maximumEntries,
          protectedPaths: _protectedPaths,
          incompleteGracePeriod: incompleteGracePeriod,
          now: now,
        );
      } on Object {
        // Cache cleanup must not prevent opening an attachment.
        return null;
      }
    });
    final finalized = result.whenComplete(() {
      _activePrunes--;
      releaseIfIdle();
    });
    _pruneTail = finalized.then<void>((_) {});
    return finalized;
  }

  Future<void> accountEvicted() async {
    for (final entry in _leaseCancellations.entries) {
      entry.value();
      unprotect(entry.key);
    }
    _leaseCancellations.clear();
    await _pruneTail;
    releaseIfIdle();
  }
}

ChatAttachmentLeaseCancellation _scheduleChatAttachmentLease(
  Duration duration,
  Future<void> Function() onExpired,
) {
  final timer = Timer(duration, () {
    unawaited(_runChatAttachmentLeaseExpiry(onExpired));
  });
  return timer.cancel;
}

Future<void> _runChatAttachmentLeaseExpiry(
  Future<void> Function() onExpired,
) async {
  try {
    await onExpired();
  } on Object {
    // The OS may have cleared the cache or account removal may have won.
  }
}

final class ChatAttachmentCacheHousekeeper
    implements ChatAttachmentCacheMaintenance {
  factory ChatAttachmentCacheHousekeeper({
    Future<Directory> Function()? cacheDirectory,
    int maximumCacheBytes = _defaultAttachmentCacheBytes,
    int maximumCacheEntries = _defaultAttachmentCacheEntries,
    Duration incompleteGracePeriod = _defaultIncompleteGracePeriod,
    ChatAttachmentLeaseScheduler scheduler = _scheduleChatAttachmentLease,
    DateTime Function() now = DateTime.now,
  }) {
    return ChatAttachmentCacheHousekeeper._(
      cacheDirectory: cacheDirectory ?? getApplicationCacheDirectory,
      maximumCacheBytes: maximumCacheBytes,
      maximumCacheEntries: maximumCacheEntries,
      incompleteGracePeriod: incompleteGracePeriod,
      scheduler: scheduler,
      now: now,
    );
  }

  ChatAttachmentCacheHousekeeper._({
    required this._cacheDirectory,
    required this.maximumCacheBytes,
    required this.maximumCacheEntries,
    required this.incompleteGracePeriod,
    required this._scheduler,
    required this._now,
  });

  final Future<Directory> Function() _cacheDirectory;
  final int maximumCacheBytes;
  final int maximumCacheEntries;
  final Duration incompleteGracePeriod;
  final ChatAttachmentLeaseScheduler _scheduler;
  final DateTime Function() _now;

  Future<void> _runTail = Future<void>.value();
  var _generation = 0;
  var _disposed = false;
  ChatAttachmentLeaseCancellation? _cancelScheduled;

  @override
  Future<void> run() {
    if (_disposed) {
      return Future<void>.value();
    }
    _cancelScheduled?.call();
    _cancelScheduled = null;
    final generation = ++_generation;
    final result = _runTail.then((_) async {
      try {
        await _runOnce(generation);
      } on Object {
        // Cache maintenance is best effort and must not affect app startup.
      }
    });
    _runTail = result;
    return result;
  }

  Future<void> _runOnce(int generation) async {
    final root = chatAttachmentCacheRootDirectory(await _cacheDirectory());
    if (!await root.exists()) {
      return;
    }
    final accountDirectories = <Directory>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory) {
        accountDirectories.add(entity);
      }
    }
    DateTime? nextLease;
    for (final directory in accountDirectories) {
      final lease = await _chatAttachmentCacheCoordinator(directory).prune(
        accountDirectory: directory,
        maximumBytes: maximumCacheBytes,
        maximumEntries: maximumCacheEntries,
        incompleteGracePeriod: incompleteGracePeriod,
        now: _now,
      );
      if (lease != null && (nextLease == null || lease.isBefore(nextLease))) {
        nextLease = lease;
      }
    }
    if (_disposed || generation != _generation || nextLease == null) {
      return;
    }
    final delay = nextLease.difference(_now());
    try {
      _cancelScheduled = _scheduler(
        delay > Duration.zero ? delay : const Duration(milliseconds: 1),
        () async {
          _cancelScheduled = null;
          if (!_disposed && generation == _generation) {
            await run();
          }
        },
      );
    } on Object {
      // Resume housekeeping is still available if a timer cannot be created.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancelScheduled?.call();
    _cancelScheduled = null;
  }
}

Future<DateTime?> _pruneChatAttachmentOpenCache({
  required Directory accountDirectory,
  required int maximumBytes,
  required int maximumEntries,
  required Set<String> protectedPaths,
  required Duration incompleteGracePeriod,
  required DateTime Function() now,
}) async {
  final currentTime = now();
  final entries =
      <
        ({
          Directory directory,
          int bytes,
          DateTime completedAt,
          DateTime leaseUntil,
        })
      >[];
  try {
    await for (final entity in accountDirectory.list(followLinks: false)) {
      if (entity is! Directory ||
          !_fileSystemName(entity.path).startsWith('download-')) {
        continue;
      }
      final marker = File(
        '${entity.path}${Platform.pathSeparator}'
        '$_completedAttachmentMarkerName',
      );
      if (!await marker.exists()) {
        final incomplete = await _readIncompleteAttachmentEntry(entity);
        if (incomplete != null &&
            !protectedPaths.contains(entity.path) &&
            !incomplete.modified
                .add(incompleteGracePeriod)
                .isAfter(currentTime)) {
          try {
            await entity.delete(recursive: true);
          } on FileSystemException {
            // A live writer or account removal won the race.
          }
        }
        continue;
      }
      final entry = await _readCompletedAttachmentEntry(entity);
      if (entry != null) {
        entries.add(entry);
      }
    }
  } on FileSystemException {
    return null;
  }

  var totalBytes = entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
  var retainedEntries = entries.length;
  entries.sort((a, b) => a.completedAt.compareTo(b.completedAt));
  for (final entry in entries) {
    if (totalBytes <= maximumBytes && retainedEntries <= maximumEntries) {
      break;
    }
    if (protectedPaths.contains(entry.directory.path) ||
        entry.leaseUntil.isAfter(currentTime)) {
      continue;
    }
    try {
      await entry.directory.delete(recursive: true);
      totalBytes -= entry.bytes;
      retainedEntries--;
    } on FileSystemException {
      // Another opener or account removal may already own this path.
    }
  }
  DateTime? nextLease;
  for (final entry in entries) {
    if (entry.leaseUntil.isAfter(currentTime) &&
        (nextLease == null || entry.leaseUntil.isBefore(nextLease))) {
      nextLease = entry.leaseUntil;
    }
  }
  return nextLease;
}

Future<({DateTime modified})?> _readIncompleteAttachmentEntry(
  Directory directory,
) async {
  try {
    var modified = (await directory.stat()).modified;
    var hasFile = false;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        return null;
      }
      final fileModified = (await entity.stat()).modified;
      if (!hasFile || fileModified.isAfter(modified)) {
        modified = fileModified;
      }
      hasFile = true;
    }
    return (modified: modified);
  } on FileSystemException {
    return null;
  }
}

Future<
  ({Directory directory, int bytes, DateTime completedAt, DateTime leaseUntil})?
>
_readCompletedAttachmentEntry(Directory directory) async {
  final marker = File(
    '${directory.path}${Platform.pathSeparator}$_completedAttachmentMarkerName',
  );
  try {
    if (!await marker.exists()) {
      return null;
    }
    var bytes = 0;
    var hasAttachment = false;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        return null;
      }
      if (entity.path == marker.path) {
        continue;
      }
      bytes += await entity.length();
      hasAttachment = true;
    }
    if (!hasAttachment) {
      return null;
    }
    final markerStat = await marker.stat();
    final storedLease = _storedAttachmentLease(await marker.readAsString());
    final leaseUntil = storedLease == null
        ? markerStat.modified.add(_defaultPostLaunchLease)
        : DateTime.fromMillisecondsSinceEpoch(storedLease, isUtc: true);
    return (
      directory: directory,
      bytes: bytes,
      completedAt: markerStat.modified,
      leaseUntil: leaseUntil,
    );
  } on FileSystemException {
    return null;
  }
}

int? _storedAttachmentLease(String marker) {
  int? stored;
  for (final match in RegExp(
    r'^leaseUntil=(-?\d{1,16})$',
    multiLine: true,
  ).allMatches(marker)) {
    final value = int.tryParse(match.group(1)!);
    if (value != null &&
        value.abs() <= 8640000000000000 &&
        (stored == null || value > stored)) {
      stored = value;
    }
  }
  final legacy = int.tryParse(marker.trim());
  if (legacy != null && legacy.abs() <= 8640000000000000) {
    return legacy;
  }
  return stored;
}

String _fileSystemName(String path) {
  final separator = path.lastIndexOf(Platform.pathSeparator);
  return separator < 0 ? path : path.substring(separator + 1);
}

Directory chatAttachmentCacheRootDirectory(Directory rootDirectory) {
  return Directory(
    '${rootDirectory.path}${Platform.pathSeparator}chat-attachments',
  );
}

Directory chatAttachmentCacheAccountDirectory({
  required Directory rootDirectory,
  required String accountId,
}) {
  final accountKey = sha256.convert(utf8.encode(accountId)).toString();
  return Directory(
    '${chatAttachmentCacheRootDirectory(rootDirectory).path}'
    '${Platform.pathSeparator}$accountKey',
  );
}

Future<void> evictChatAttachmentFiles({
  required Directory rootDirectory,
  required String accountId,
}) async {
  final directory = chatAttachmentCacheAccountDirectory(
    rootDirectory: rootDirectory,
    accountId: accountId,
  );
  final coordinator = ChatAttachmentOpener._cacheCoordinators[directory.path];
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // Nothing was opened for this account, or the OS already cleared cache.
  } finally {
    await coordinator?.accountEvicted();
  }
}

@visibleForTesting
bool debugHasChatAttachmentCacheCoordinator(Directory accountDirectory) {
  return ChatAttachmentOpener._cacheCoordinators.containsKey(
    accountDirectory.path,
  );
}

typedef ChatAttachmentOpenActionFactory =
    ChatAttachmentOpenAction Function(ChatMediaRepository repository);

final chatAttachmentOpenActionFactoryProvider =
    Provider<ChatAttachmentOpenActionFactory>((ref) {
      return (repository) => ChatAttachmentOpener(repository: repository);
    });

String chatAttachmentFileName(String remoteName) {
  var name = remoteName.trim();
  for (final separator in const <String>['/', r'\']) {
    final last = name.lastIndexOf(separator);
    if (last >= 0) {
      name = name.substring(last + 1);
    }
  }
  name = name
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
      .replaceAll(RegExp(r'^[._-]+'), '')
      .replaceAll(RegExp(r'\.+$'), '');
  if (name.isEmpty) {
    return 'attachment';
  }
  name = name.length <= 128 ? name : name.substring(name.length - 128);
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_${name.length < 128 ? name : name.substring(name.length - 127)}';
  }
  return name;
}
