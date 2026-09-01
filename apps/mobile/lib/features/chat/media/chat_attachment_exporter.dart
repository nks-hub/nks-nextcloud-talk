import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/app_database.dart';
import '../../../data/chat_media_repository.dart';
import 'chat_attachment_opener.dart';

enum ChatAttachmentSaveResult {
  saved,
  cancelled,
  downloadFailed,
  permissionDenied,
  storageFailed,
}

enum ChatAttachmentShareResult {
  shared,
  cancelled,
  downloadFailed,
  permissionDenied,
  shareFailed,
}

enum ChatAttachmentSystemResult {
  completed,
  cancelled,
  permissionDenied,
  storageFailed,
  unavailable,
}

abstract interface class ChatAttachmentExportAction {
  Future<ChatAttachmentSaveResult> save({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
  });

  Future<ChatAttachmentShareResult> share({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
  });
}

abstract interface class ChatAttachmentSystem {
  Future<ChatAttachmentSystemResult> save({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  });

  Future<ChatAttachmentSystemResult> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  });
}

final class PlatformChatAttachmentSystem implements ChatAttachmentSystem {
  const PlatformChatAttachmentSystem();

  @override
  Future<ChatAttachmentSystemResult> save({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return _offerSystemSheet(
        bytes: bytes,
        fileName: fileName,
        contentType: contentType,
      );
    }
    try {
      final destination = await getSaveLocation(suggestedName: fileName);
      if (destination == null) {
        return ChatAttachmentSystemResult.cancelled;
      }
      await XFile.fromData(
        bytes,
        mimeType: contentType,
        name: fileName,
      ).saveTo(destination.path);
      return ChatAttachmentSystemResult.completed;
    } on Object catch (error) {
      return chatAttachmentStorageErrorResult(error);
    }
  }

  @override
  Future<ChatAttachmentSystemResult> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) {
    return _offerSystemSheet(
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
    );
  }

  Future<ChatAttachmentSystemResult> _offerSystemSheet({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: contentType, name: fileName)],
          fileNameOverrides: [fileName],
        ),
      );
      return switch (result.status) {
        ShareResultStatus.success => ChatAttachmentSystemResult.completed,
        ShareResultStatus.dismissed => ChatAttachmentSystemResult.cancelled,
        ShareResultStatus.unavailable => ChatAttachmentSystemResult.unavailable,
      };
    } on Object catch (error) {
      final storageResult = chatAttachmentStorageErrorResult(error);
      return storageResult == ChatAttachmentSystemResult.permissionDenied
          ? storageResult
          : ChatAttachmentSystemResult.unavailable;
    }
  }
}

ChatAttachmentSystemResult chatAttachmentStorageErrorResult(Object error) {
  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    if (code.contains('permission') ||
        code.contains('access_denied') ||
        code.contains('read_only')) {
      return ChatAttachmentSystemResult.permissionDenied;
    }
  }
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    if (code == 1 || code == 5 || code == 13) {
      return ChatAttachmentSystemResult.permissionDenied;
    }
  }
  return ChatAttachmentSystemResult.storageFailed;
}

final class ChatAttachmentExporter implements ChatAttachmentExportAction {
  const ChatAttachmentExporter({
    required ChatMediaRepository repository,
    ChatAttachmentSystem system = const PlatformChatAttachmentSystem(),
  }) : this._(repository, system);

  const ChatAttachmentExporter._(this._repository, this._system);

  final ChatMediaRepository _repository;
  final ChatAttachmentSystem _system;

  @override
  Future<ChatAttachmentSaveResult> save({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
  }) async {
    final attachment = await _download(
      account: account,
      uri: uri,
      expectedContentType: expectedContentType,
    );
    if (attachment == null) {
      return ChatAttachmentSaveResult.downloadFailed;
    }
    final result = await _system.save(
      bytes: attachment.body,
      fileName: chatAttachmentFileName(fileName),
      contentType: attachment.contentType,
    );
    return switch (result) {
      ChatAttachmentSystemResult.completed => ChatAttachmentSaveResult.saved,
      ChatAttachmentSystemResult.cancelled =>
        ChatAttachmentSaveResult.cancelled,
      ChatAttachmentSystemResult.permissionDenied =>
        ChatAttachmentSaveResult.permissionDenied,
      ChatAttachmentSystemResult.storageFailed ||
      ChatAttachmentSystemResult.unavailable =>
        ChatAttachmentSaveResult.storageFailed,
    };
  }

  @override
  Future<ChatAttachmentShareResult> share({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
  }) async {
    final attachment = await _download(
      account: account,
      uri: uri,
      expectedContentType: expectedContentType,
    );
    if (attachment == null) {
      return ChatAttachmentShareResult.downloadFailed;
    }
    final result = await _system.share(
      bytes: attachment.body,
      fileName: chatAttachmentFileName(fileName),
      contentType: attachment.contentType,
    );
    return switch (result) {
      ChatAttachmentSystemResult.completed => ChatAttachmentShareResult.shared,
      ChatAttachmentSystemResult.cancelled =>
        ChatAttachmentShareResult.cancelled,
      ChatAttachmentSystemResult.permissionDenied =>
        ChatAttachmentShareResult.permissionDenied,
      ChatAttachmentSystemResult.storageFailed ||
      ChatAttachmentSystemResult.unavailable =>
        ChatAttachmentShareResult.shareFailed,
    };
  }

  Future<ChatMediaFile?> _download({
    required StoredAccount account,
    required Uri uri,
    required String expectedContentType,
  }) async {
    try {
      return await _repository.loadOriginalFile(
        account: account,
        uri: uri,
        expectedContentType: expectedContentType,
      );
    } on Object {
      return null;
    }
  }
}

typedef ChatAttachmentExportActionFactory =
    ChatAttachmentExportAction Function(ChatMediaRepository repository);

final chatAttachmentExportActionFactoryProvider =
    Provider<ChatAttachmentExportActionFactory>((ref) {
      return (repository) => ChatAttachmentExporter(repository: repository);
    });
