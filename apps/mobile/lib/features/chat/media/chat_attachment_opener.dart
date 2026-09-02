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
  }) => ChatAttachmentOpener._(
    repository,
    cacheDirectory ?? getApplicationCacheDirectory,
    launcher,
  );

  ChatAttachmentOpener._(
    this._repository,
    this._cacheDirectory,
    this._launcher,
  );

  final ChatMediaRepository _repository;
  final Future<Directory> Function() _cacheDirectory;
  final ChatAttachmentFileLauncher _launcher;

  @override
  Future<ChatAttachmentOpenResult> open({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async {
    final ChatMediaFile attachment;
    try {
      attachment = await _repository.loadOriginalFile(
        account: account,
        uri: uri,
        expectedContentType: expectedContentType,
        onProgress: onProgress,
      );
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
    } on Object {
      // Credential vault backends can fail outside the repository error enum.
      return ChatAttachmentOpenResult.downloadFailed;
    }

    final File localFile;
    try {
      final root = await _cacheDirectory();
      final directory = chatAttachmentCacheAccountDirectory(
        rootDirectory: root,
        accountId: account.id,
      );
      await directory.create(recursive: true);
      localFile = File(
        '${directory.path}${Platform.pathSeparator}'
        '${chatAttachmentFileName(fileName)}',
      );
      await localFile.writeAsBytes(attachment.body, flush: true);
    } on FileSystemException {
      return ChatAttachmentOpenResult.storageFailed;
    } on PlatformException {
      return ChatAttachmentOpenResult.storageFailed;
    } on MissingPluginException {
      return ChatAttachmentOpenResult.storageFailed;
    }

    final opened = await _launcher.open(
      path: localFile.path,
      contentType: attachment.contentType,
    );
    return opened
        ? ChatAttachmentOpenResult.opened
        : ChatAttachmentOpenResult.openFailed;
  }
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
