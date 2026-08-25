import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:mime/mime.dart';
import 'package:share_plus/share_plus.dart';

enum ChatImageSaveResult { saved, permissionDenied, outOfSpace, failed }

/// Hands a picture the viewer already holds to the platform: the device
/// gallery, or the system share sheet.
///
/// This is the seam widget tests replace, because neither destination is
/// reachable without a platform channel.
abstract interface class ChatImageExporter {
  Future<ChatImageSaveResult> saveToGallery({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  });

  /// Returns false only when the sheet could not be offered at all. A sheet
  /// the user dismisses is not a failure and needs no message.
  Future<bool> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  });
}

final class PlatformChatImageExporter implements ChatImageExporter {
  const PlatformChatImageExporter();

  @override
  Future<ChatImageSaveResult> saveToGallery({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    try {
      // Gal asks for gallery access itself and reports a refusal as
      // accessDenied, which the viewer turns into a spoken-out message.
      await Gal.putImageBytes(bytes, name: fileName);
      return ChatImageSaveResult.saved;
    } on GalException catch (error) {
      return switch (error.type) {
        GalExceptionType.accessDenied => ChatImageSaveResult.permissionDenied,
        GalExceptionType.notEnoughSpace => ChatImageSaveResult.outOfSpace,
        _ => ChatImageSaveResult.failed,
      };
    } on Object {
      return ChatImageSaveResult.failed;
    }
  }

  @override
  Future<bool> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: contentType)],
          // XFile.fromData ignores its own name on most platforms.
          fileNameOverrides: [
            chatImageFileName(fileName: fileName, contentType: contentType),
          ],
        ),
      );
      return result.status != ShareResultStatus.unavailable;
    } on Object {
      return false;
    }
  }
}

/// Reduces a remote file name to something a gallery and a share sheet accept.
///
/// The name arrives from a chat peer, so it is never treated as a path: every
/// separator and every other unexpected character collapses to an underscore.
String chatImageBaseName(String imageName) {
  var name = imageName;
  for (final separator in const <String>['/', r'\']) {
    final last = name.lastIndexOf(separator);
    if (last >= 0) {
      name = name.substring(last + 1);
    }
  }
  final extension = name.lastIndexOf('.');
  if (extension > 0) {
    name = name.substring(0, extension);
  }
  name = name
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
      .replaceAll(RegExp(r'^[._-]+'), '');
  if (name.isEmpty) {
    return 'image';
  }
  return name.length <= 64 ? name : name.substring(0, 64);
}

/// Adds the extension that matches [contentType] to a [chatImageBaseName].
String chatImageFileName({
  required String fileName,
  required String contentType,
}) => '$fileName.${extensionFromMime(contentType) ?? 'img'}';
