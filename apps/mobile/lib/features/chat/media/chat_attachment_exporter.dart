import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/app_database.dart';
import '../../../data/chat_media_repository.dart';
import 'chat_attachment_mobile_saver.dart';
import 'chat_attachment_opener.dart';

enum ChatAttachmentSaveResult {
  saved,
  cancelled,
  reauthenticationRequired,
  tooLarge,
  invalid,
  downloadFailed,
  permissionDenied,
  storageFailed,
}

enum ChatAttachmentShareResult {
  shared,
  offered,
  cancelled,
  reauthenticationRequired,
  tooLarge,
  invalid,
  downloadFailed,
  permissionDenied,
  shareFailed,
}

enum ChatAttachmentSystemResult {
  completed,
  offered,
  cancelled,
  permissionDenied,
  storageFailed,
  tooLarge,
  invalid,
  unavailable,
}

abstract interface class ChatAttachmentExportAction {
  Future<ChatAttachmentSaveResult> save({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  });

  Future<ChatAttachmentShareResult> share({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  });
}

abstract interface class ChatAttachmentSystem {
  Future<ChatAttachmentSystemResult> save({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  });

  /// Hands an already downloaded file to the platform's save dialog.
  ///
  /// Used for chat attachments, which can be hundreds of megabytes: holding
  /// one in memory only to write it out again is what made a 117 MB build
  /// refuse to save at all.
  Future<ChatAttachmentSystemResult> saveFile({
    required File source,
    required String fileName,
    required String contentType,
    bool Function()? canExport,
  });

  Future<ChatAttachmentSystemResult> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  });
}

typedef ChatAttachmentSaveLocationPicker =
    Future<FileSaveLocation?> Function({String? suggestedName});
typedef ChatAttachmentShareFile =
    Future<ShareResult> Function(ShareParams params);

Future<FileSaveLocation?> _pickAttachmentSaveLocation({
  String? suggestedName,
}) => getSaveLocation(suggestedName: suggestedName);

final class PlatformChatAttachmentSystem implements ChatAttachmentSystem {
  PlatformChatAttachmentSystem({
    bool? mobilePlatform,
    ChatAttachmentMobileSaver? mobileSaver,
    Future<Directory> Function()? temporaryDirectory,
    ChatAttachmentSaveLocationPicker? saveLocationPicker,
    ChatAttachmentShareFile? shareFile,
  }) : _mobilePlatform =
           mobilePlatform ??
           (!kIsWeb &&
               (defaultTargetPlatform == TargetPlatform.android ||
                   defaultTargetPlatform == TargetPlatform.iOS)),
       _mobileSaver = mobileSaver ?? MethodChannelChatAttachmentMobileSaver(),
       _temporaryDirectory = temporaryDirectory ?? getApplicationCacheDirectory,
       _saveLocationPicker = saveLocationPicker ?? _pickAttachmentSaveLocation,
       _shareFile = shareFile ?? SharePlus.instance.share;

  static const maximumBytes = 64 * 1024 * 1024;

  final bool _mobilePlatform;
  final ChatAttachmentMobileSaver _mobileSaver;
  final Future<Directory> Function() _temporaryDirectory;
  final ChatAttachmentSaveLocationPicker _saveLocationPicker;
  final ChatAttachmentShareFile _shareFile;

  @override
  Future<ChatAttachmentSystemResult> save({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) {
    if (bytes.length > maximumBytes) {
      return Future.value(ChatAttachmentSystemResult.tooLarge);
    }
    if (bytes.isEmpty) {
      return Future.value(ChatAttachmentSystemResult.invalid);
    }
    return _mobilePlatform
        ? _saveWithMobilePicker(
            bytes: bytes,
            fileName: fileName,
            contentType: contentType,
          )
        : _saveWithDesktopPicker(
            bytes: bytes,
            fileName: fileName,
            contentType: contentType,
          );
  }

  @override
  Future<ChatAttachmentSystemResult> saveFile({
    required File source,
    required String fileName,
    required String contentType,
    bool Function()? canExport,
  }) async {
    try {
      if (!await source.exists() || await source.length() == 0) {
        return ChatAttachmentSystemResult.invalid;
      }
      if (canExport?.call() == false) {
        return ChatAttachmentSystemResult.cancelled;
      }
      if (_mobilePlatform) {
        final result = await _mobileSaver.save(
          sourcePath: source.path,
          fileName: fileName,
          contentType: contentType,
        );
        return switch (result) {
          ChatAttachmentMobileSaveResult.saved =>
            ChatAttachmentSystemResult.completed,
          ChatAttachmentMobileSaveResult.cancelled =>
            ChatAttachmentSystemResult.cancelled,
        };
      }
      final destination = await _saveLocationPicker(suggestedName: fileName);
      if (destination == null) {
        return ChatAttachmentSystemResult.cancelled;
      }
      if (canExport?.call() == false) {
        return ChatAttachmentSystemResult.cancelled;
      }
      await source.copy(destination.path);
      return ChatAttachmentSystemResult.completed;
    } on ChatAttachmentMobileSaveException catch (error) {
      return switch (error.failure) {
        ChatAttachmentMobileSaveFailure.permissionDenied =>
          ChatAttachmentSystemResult.permissionDenied,
        ChatAttachmentMobileSaveFailure.storageFailed =>
          ChatAttachmentSystemResult.storageFailed,
        ChatAttachmentMobileSaveFailure.tooLarge =>
          ChatAttachmentSystemResult.tooLarge,
        ChatAttachmentMobileSaveFailure.invalidSource =>
          ChatAttachmentSystemResult.invalid,
        ChatAttachmentMobileSaveFailure.inProgress ||
        ChatAttachmentMobileSaveFailure.unavailable =>
          ChatAttachmentSystemResult.unavailable,
      };
    } on FileSystemException catch (error) {
      return chatAttachmentStorageErrorResult(error);
    } on PlatformException catch (error) {
      return chatAttachmentStorageErrorResult(error);
    } on MissingPluginException catch (error) {
      return chatAttachmentStorageErrorResult(error);
    }
  }

  Future<ChatAttachmentSystemResult> _saveWithDesktopPicker({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    try {
      final destination = await _saveLocationPicker(suggestedName: fileName);
      if (destination == null) {
        return ChatAttachmentSystemResult.cancelled;
      }
      await XFile.fromData(
        bytes,
        mimeType: contentType,
        name: fileName,
      ).saveTo(destination.path);
      return ChatAttachmentSystemResult.completed;
    } on FileSystemException catch (error) {
      return chatAttachmentStorageErrorResult(error);
    } on PlatformException catch (error) {
      return chatAttachmentStorageErrorResult(error);
    } on MissingPluginException catch (error) {
      return chatAttachmentStorageErrorResult(error);
    }
  }

  Future<ChatAttachmentSystemResult> _saveWithMobilePicker({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    Directory? operationDirectory;
    late ChatAttachmentSystemResult outcome;
    try {
      final root = await _temporaryDirectory();
      await root.create(recursive: true);
      operationDirectory = await root.createTemp('chat-attachment-save-');
      final source = File(
        '${operationDirectory.path}${Platform.pathSeparator}$fileName',
      );
      await source.writeAsBytes(bytes, flush: true);
      final result = await _mobileSaver.save(
        sourcePath: source.path,
        fileName: fileName,
        contentType: contentType,
      );
      outcome = switch (result) {
        ChatAttachmentMobileSaveResult.saved =>
          ChatAttachmentSystemResult.completed,
        ChatAttachmentMobileSaveResult.cancelled =>
          ChatAttachmentSystemResult.cancelled,
      };
    } on ChatAttachmentMobileSaveException catch (error) {
      outcome = switch (error.failure) {
        ChatAttachmentMobileSaveFailure.permissionDenied =>
          ChatAttachmentSystemResult.permissionDenied,
        ChatAttachmentMobileSaveFailure.storageFailed =>
          ChatAttachmentSystemResult.storageFailed,
        ChatAttachmentMobileSaveFailure.tooLarge =>
          ChatAttachmentSystemResult.tooLarge,
        ChatAttachmentMobileSaveFailure.invalidSource =>
          ChatAttachmentSystemResult.invalid,
        ChatAttachmentMobileSaveFailure.inProgress ||
        ChatAttachmentMobileSaveFailure.unavailable =>
          ChatAttachmentSystemResult.unavailable,
      };
    } on FileSystemException catch (error) {
      outcome = chatAttachmentStorageErrorResult(error);
    } on PlatformException catch (error) {
      outcome = chatAttachmentStorageErrorResult(error);
    } on MissingPluginException catch (error) {
      outcome = chatAttachmentStorageErrorResult(error);
    } on MissingPlatformDirectoryException {
      outcome = ChatAttachmentSystemResult.storageFailed;
    } finally {
      final directory = operationDirectory;
      if (directory != null) {
        try {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        } on FileSystemException {
          // The destination outcome is final; reporting it as failed would
          // invite a duplicate export while the private cache remains OS-owned.
        }
      }
    }
    return outcome;
  }

  @override
  Future<ChatAttachmentSystemResult> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    try {
      final result = await _shareFile(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: contentType, name: fileName)],
          fileNameOverrides: [fileName],
        ),
      );
      return switch (result.status) {
        ShareResultStatus.success => ChatAttachmentSystemResult.completed,
        ShareResultStatus.dismissed => ChatAttachmentSystemResult.cancelled,
        ShareResultStatus.unavailable => ChatAttachmentSystemResult.offered,
      };
    } on PlatformException catch (error) {
      final storageResult = chatAttachmentStorageErrorResult(error);
      return storageResult == ChatAttachmentSystemResult.permissionDenied
          ? storageResult
          : ChatAttachmentSystemResult.unavailable;
    } on MissingPluginException {
      return ChatAttachmentSystemResult.unavailable;
    } on UnimplementedError {
      return ChatAttachmentSystemResult.unavailable;
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
  ChatAttachmentExporter({
    required ChatMediaRepository repository,
    ChatAttachmentSystem? system,
    Future<Directory> Function()? temporaryDirectory,
  }) : this._(
         repository,
         system ?? PlatformChatAttachmentSystem(),
         temporaryDirectory ?? getApplicationCacheDirectory,
       );

  ChatAttachmentExporter._(
    this._repository,
    this._system,
    this._temporaryDirectory,
  );

  final ChatMediaRepository _repository;
  final ChatAttachmentSystem _system;
  final Future<Directory> Function() _temporaryDirectory;

  @override
  Future<ChatAttachmentSaveResult> save({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async {
    final name = chatAttachmentFileName(fileName);
    Directory? scratch;
    final ChatAttachmentSystemResult result;
    try {
      final root = await _temporaryDirectory();
      await root.create(recursive: true);
      scratch = await root.createTemp('chat-attachment-download-');
      final source = File('${scratch.path}${Platform.pathSeparator}$name');
      final String contentType;
      try {
        contentType = await _repository.downloadOriginalToFile(
          account: account,
          uri: uri,
          expectedContentType: expectedContentType,
          target: source,
          onProgress: onProgress,
        );
      } on ChatMediaRepositoryException catch (error) {
        return _saveDownloadFailure(_downloadFailureKind(error));
      } on FileSystemException {
        return ChatAttachmentSaveResult.storageFailed;
      } on Object {
        return _saveDownloadFailure(
          _AttachmentDownloadFailureKind.downloadFailed,
        );
      }
      if (!_repository.isAccountActive(account.id)) {
        return ChatAttachmentSaveResult.reauthenticationRequired;
      }
      result = await _system.saveFile(
        source: source,
        fileName: name,
        contentType: contentType,
        canExport: () => _repository.isAccountActive(account.id),
      );
    } on FileSystemException {
      return ChatAttachmentSaveResult.storageFailed;
    } on MissingPlatformDirectoryException {
      return ChatAttachmentSaveResult.storageFailed;
    } finally {
      await _discardScratch(scratch);
    }
    return switch (result) {
      ChatAttachmentSystemResult.completed => ChatAttachmentSaveResult.saved,
      ChatAttachmentSystemResult.cancelled =>
        ChatAttachmentSaveResult.cancelled,
      ChatAttachmentSystemResult.permissionDenied =>
        ChatAttachmentSaveResult.permissionDenied,
      ChatAttachmentSystemResult.tooLarge => ChatAttachmentSaveResult.tooLarge,
      ChatAttachmentSystemResult.invalid => ChatAttachmentSaveResult.invalid,
      ChatAttachmentSystemResult.offered ||
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
    ChatDownloadProgress? onProgress,
  }) async {
    final download = await _download(
      account: account,
      uri: uri,
      expectedContentType: expectedContentType,
      onProgress: onProgress,
    );
    if (download case _AttachmentDownloadFailure(:final failure)) {
      return _shareDownloadFailure(failure);
    }
    final attachment = (download as _AttachmentDownloadSuccess).file;
    if (!_repository.isAccountActive(account.id)) {
      return ChatAttachmentShareResult.reauthenticationRequired;
    }
    final result = await _system.share(
      bytes: attachment.body,
      fileName: chatAttachmentFileName(fileName),
      contentType: attachment.contentType,
    );
    return switch (result) {
      ChatAttachmentSystemResult.completed => ChatAttachmentShareResult.shared,
      ChatAttachmentSystemResult.offered => ChatAttachmentShareResult.offered,
      ChatAttachmentSystemResult.cancelled =>
        ChatAttachmentShareResult.cancelled,
      ChatAttachmentSystemResult.permissionDenied =>
        ChatAttachmentShareResult.permissionDenied,
      ChatAttachmentSystemResult.storageFailed ||
      ChatAttachmentSystemResult.tooLarge ||
      ChatAttachmentSystemResult.invalid ||
      ChatAttachmentSystemResult.unavailable =>
        ChatAttachmentShareResult.shareFailed,
    };
  }

  Future<void> _discardScratch(Directory? scratch) async {
    if (scratch == null) return;
    try {
      if (await scratch.exists()) await scratch.delete(recursive: true);
    } on FileSystemException {
      // The save already reported its outcome; a leftover in the private
      // cache is the OS's to reclaim.
    }
  }

  _AttachmentDownloadFailureKind _downloadFailureKind(
    ChatMediaRepositoryException error,
  ) => switch (error.code) {
    ChatMediaRepositoryError.credentialMissing =>
      _AttachmentDownloadFailureKind.reauthenticationRequired,
    ChatMediaRepositoryError.responseTooLarge =>
      _AttachmentDownloadFailureKind.tooLarge,
    ChatMediaRepositoryError.invalidUri ||
    ChatMediaRepositoryError.invalidResponse =>
      _AttachmentDownloadFailureKind.invalid,
    ChatMediaRepositoryError.unavailable =>
      _AttachmentDownloadFailureKind.downloadFailed,
  };

  Future<_AttachmentDownloadResult> _download({
    required StoredAccount account,
    required Uri uri,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async {
    try {
      final file = await _repository.loadOriginalFile(
        account: account,
        uri: uri,
        expectedContentType: expectedContentType,
        onProgress: onProgress,
      );
      return _AttachmentDownloadSuccess(file);
    } on ChatMediaRepositoryException catch (error) {
      return _AttachmentDownloadFailure(switch (error.code) {
        ChatMediaRepositoryError.credentialMissing =>
          _AttachmentDownloadFailureKind.reauthenticationRequired,
        ChatMediaRepositoryError.responseTooLarge =>
          _AttachmentDownloadFailureKind.tooLarge,
        ChatMediaRepositoryError.invalidUri ||
        ChatMediaRepositoryError.invalidResponse =>
          _AttachmentDownloadFailureKind.invalid,
        ChatMediaRepositoryError.unavailable =>
          _AttachmentDownloadFailureKind.downloadFailed,
      });
    } on Object {
      // Credential vault backends surface platform-specific failures here.
      return const _AttachmentDownloadFailure(
        _AttachmentDownloadFailureKind.downloadFailed,
      );
    }
  }
}

enum _AttachmentDownloadFailureKind {
  reauthenticationRequired,
  tooLarge,
  invalid,
  downloadFailed,
}

sealed class _AttachmentDownloadResult {
  const _AttachmentDownloadResult();
}

final class _AttachmentDownloadSuccess extends _AttachmentDownloadResult {
  const _AttachmentDownloadSuccess(this.file);

  final ChatMediaFile file;
}

final class _AttachmentDownloadFailure extends _AttachmentDownloadResult {
  const _AttachmentDownloadFailure(this.failure);

  final _AttachmentDownloadFailureKind failure;
}

ChatAttachmentSaveResult _saveDownloadFailure(
  _AttachmentDownloadFailureKind failure,
) => switch (failure) {
  _AttachmentDownloadFailureKind.reauthenticationRequired =>
    ChatAttachmentSaveResult.reauthenticationRequired,
  _AttachmentDownloadFailureKind.tooLarge => ChatAttachmentSaveResult.tooLarge,
  _AttachmentDownloadFailureKind.invalid => ChatAttachmentSaveResult.invalid,
  _AttachmentDownloadFailureKind.downloadFailed =>
    ChatAttachmentSaveResult.downloadFailed,
};

ChatAttachmentShareResult _shareDownloadFailure(
  _AttachmentDownloadFailureKind failure,
) => switch (failure) {
  _AttachmentDownloadFailureKind.reauthenticationRequired =>
    ChatAttachmentShareResult.reauthenticationRequired,
  _AttachmentDownloadFailureKind.tooLarge => ChatAttachmentShareResult.tooLarge,
  _AttachmentDownloadFailureKind.invalid => ChatAttachmentShareResult.invalid,
  _AttachmentDownloadFailureKind.downloadFailed =>
    ChatAttachmentShareResult.downloadFailed,
};

typedef ChatAttachmentExportActionFactory =
    ChatAttachmentExportAction Function(ChatMediaRepository repository);

final chatAttachmentExportActionFactoryProvider =
    Provider<ChatAttachmentExportActionFactory>((ref) {
      return (repository) => ChatAttachmentExporter(repository: repository);
    });
