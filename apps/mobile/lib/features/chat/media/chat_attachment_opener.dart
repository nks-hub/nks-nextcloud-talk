import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
    int maximumCacheBytes = 256 * 1024 * 1024,
    int maximumCacheEntries = 16,
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
    return ChatAttachmentOpener._(
      repository,
      cacheDirectory ?? getApplicationCacheDirectory,
      launcher,
      maximumCacheBytes,
      maximumCacheEntries,
    );
  }

  ChatAttachmentOpener._(
    this._repository,
    this._cacheDirectory,
    this._launcher,
    this._maximumCacheBytes,
    this._maximumCacheEntries,
  );

  static final Set<String> _activeDownloadPaths = <String>{};

  final ChatMediaRepository _repository;
  final Future<Directory> Function() _cacheDirectory;
  final ChatAttachmentFileLauncher _launcher;
  final int _maximumCacheBytes;
  final int _maximumCacheEntries;

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
    final String contentType;
    try {
      final root = await _cacheDirectory();
      final directory = chatAttachmentCacheAccountDirectory(
        rootDirectory: root,
        accountId: account.id,
      );
      await directory.create(recursive: true);
      downloadDirectory = await directory.createTemp('download-');
      _activeDownloadPaths.add(downloadDirectory.path);
      await _pruneChatAttachmentOpenCache(
        accountDirectory: directory,
        maximumBytes: _maximumCacheBytes,
        maximumEntries: _maximumCacheEntries,
        protectedPaths: _activeDownloadPaths,
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
      await File(
        '${downloadDirectory.path}${Platform.pathSeparator}'
        '$_completedAttachmentMarkerName',
      ).writeAsString('', flush: true);
      opened = await _launcher.open(
        path: localFile.path,
        contentType: contentType,
      );
      if (opened) {
        await _pruneChatAttachmentOpenCache(
          accountDirectory: downloadDirectory.parent,
          maximumBytes: _maximumCacheBytes,
          maximumEntries: _maximumCacheEntries,
          protectedPaths: _activeDownloadPaths,
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
      _activeDownloadPaths.remove(downloadDirectory.path);
    }
  }
}

const String _completedAttachmentMarkerName = '.open-complete';

Future<void> _pruneChatAttachmentOpenCache({
  required Directory accountDirectory,
  required int maximumBytes,
  required int maximumEntries,
  required Set<String> protectedPaths,
}) async {
  final entries = <({Directory directory, int bytes, DateTime completedAt})>[];
  try {
    await for (final entity in accountDirectory.list(followLinks: false)) {
      if (entity is! Directory ||
          !_fileSystemName(entity.path).startsWith('download-')) {
        continue;
      }
      final entry = await _readCompletedAttachmentEntry(entity);
      if (entry != null) {
        entries.add(entry);
      }
    }
  } on FileSystemException {
    return;
  }

  var totalBytes = entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
  var retainedEntries = entries.length;
  if (totalBytes <= maximumBytes && retainedEntries <= maximumEntries) {
    return;
  }
  entries.sort((a, b) => a.completedAt.compareTo(b.completedAt));
  for (final entry in entries) {
    if (totalBytes <= maximumBytes && retainedEntries <= maximumEntries) {
      break;
    }
    if (protectedPaths.contains(entry.directory.path)) {
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
}

Future<({Directory directory, int bytes, DateTime completedAt})?>
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
    return (
      directory: directory,
      bytes: bytes,
      completedAt: markerStat.modified,
    );
  } on FileSystemException {
    return null;
  }
}

String _fileSystemName(String path) {
  final separator = path.lastIndexOf(Platform.pathSeparator);
  return separator < 0 ? path : path.substring(separator + 1);
}

Directory chatAttachmentCacheAccountDirectory({
  required Directory rootDirectory,
  required String accountId,
}) {
  final accountKey = sha256.convert(utf8.encode(accountId)).toString();
  return Directory(
    '${rootDirectory.path}${Platform.pathSeparator}chat-attachments'
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
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // Nothing was opened for this account, or the OS already cleared cache.
  }
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
