import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../network/attachment_transport.dart';
import 'durable_attachment_source_store.dart';
import 'image_attachment_picker.dart';

typedef DesktopSecurityAccess = Future<bool> Function(Uint8List bookmark);

final class DesktopAttachmentSourcePreparer {
  DesktopAttachmentSourcePreparer({
    required this.picker,
    DesktopSecurityAccess? startSecurityAccess,
    DesktopSecurityAccess? stopSecurityAccess,
  }) : _startSecurityAccess =
           startSecurityAccess ?? _startPlatformSecurityAccess,
       _stopSecurityAccess = stopSecurityAccess ?? _stopPlatformSecurityAccess;

  final DurableImageAttachmentPicker picker;
  final DesktopSecurityAccess _startSecurityAccess;
  final DesktopSecurityAccess _stopSecurityAccess;

  Future<PreparedAttachmentSource> prepare(
    DropItem item, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (item is DropItemDirectory) {
      throw const ImageAttachmentPickerException(
        ImageAttachmentPickerError.unsupportedType,
      );
    }
    final bookmark = item.extraAppleBookmark;
    var securityAccessStarted = false;
    try {
      if (bookmark != null && bookmark.isNotEmpty) {
        securityAccessStarted = await _startSecurityAccess(bookmark);
        if (!securityAccessStarted) {
          throw const ImageAttachmentPickerException(
            ImageAttachmentPickerError.invalidSelection,
          );
        }
      }
      final byteLength = await item.length();
      return picker.copyFileSelection(
        ImageSelection(
          displayName: item.name,
          declaredMimeType: item.mimeType,
          byteLength: byteLength,
          openRead: ({int? start, int? end}) => item.openRead(start, end),
        ),
        cancellationSignal: cancellationSignal,
      );
    } on ImageAttachmentPickerException {
      rethrow;
    } on DurableAttachmentSourceException {
      rethrow;
    } on FileSystemException {
      throw const ImageAttachmentPickerException(
        ImageAttachmentPickerError.invalidSelection,
      );
    } on PlatformException {
      throw const ImageAttachmentPickerException(
        ImageAttachmentPickerError.invalidSelection,
      );
    } finally {
      if (securityAccessStarted) {
        try {
          await _stopSecurityAccess(bookmark!);
        } on PlatformException {
          // The durable copy is already app-owned; release failure cannot
          // invalidate or safely discard it.
        }
      }
    }
  }

  static Future<bool> _startPlatformSecurityAccess(Uint8List bookmark) =>
      DesktopDrop.instance.startAccessingSecurityScopedResource(
        bookmark: bookmark,
      );

  static Future<bool> _stopPlatformSecurityAccess(Uint8List bookmark) =>
      DesktopDrop.instance.stopAccessingSecurityScopedResource(
        bookmark: bookmark,
      );
}
