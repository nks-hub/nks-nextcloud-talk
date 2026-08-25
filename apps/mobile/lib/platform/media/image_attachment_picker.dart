import 'dart:async';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:image_picker/image_picker.dart' as camera;
import 'package:mime/mime.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:path/path.dart' as p;
import 'package:talk_protocol/talk_protocol.dart';

/// Where the bytes of an attachment come from. All three end up in the same
/// durable copy and follow the identical upload path; only the selection UI
/// and the accepted MIME types differ.
enum AttachmentPickerSource { gallery, camera, file }

enum ImageAttachmentPickerError {
  unsupportedType,
  invalidSelection,
  cameraPermissionDenied,
  cameraUnavailable,
}

final class ImageAttachmentPickerException implements Exception {
  const ImageAttachmentPickerException(this.code);

  final ImageAttachmentPickerError code;

  @override
  String toString() => 'ImageAttachmentPickerException(${code.name})';
}

typedef OpenSelectedImage = Stream<List<int>> Function({int? start, int? end});

final class ImageSelection {
  const ImageSelection({
    required this.displayName,
    required this.declaredMimeType,
    required this.byteLength,
    required this.openRead,
  });

  final String displayName;
  final String? declaredMimeType;
  final int byteLength;
  final OpenSelectedImage openRead;
}

abstract interface class ImageSelectionBackend {
  Future<ImageSelection?> selectImage(AttachmentPickerSource source);
}

/// Gallery and generic file selection run through `file_selector`; the camera
/// goes through `image_picker`, which is the only one of the two that wraps
/// `ACTION_IMAGE_CAPTURE` / `UIImagePickerController`.
final class PlatformAttachmentSelectionBackend implements ImageSelectionBackend {
  static const XTypeGroup _imageTypes = XTypeGroup(
    label: 'Images',
    extensions: <String>[
      'avif',
      'bmp',
      'gif',
      'heic',
      'heif',
      'jpeg',
      'jpg',
      'png',
      'webp',
    ],
    mimeTypes: <String>[
      'image/avif',
      'image/bmp',
      'image/gif',
      'image/heic',
      'image/heif',
      'image/jpeg',
      'image/png',
      'image/webp',
    ],
    uniformTypeIdentifiers: <String>['public.image'],
    webWildCards: <String>['image/*'],
  );

  const PlatformAttachmentSelectionBackend();

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) async {
    final file = switch (source) {
      AttachmentPickerSource.gallery => await openFile(
        acceptedTypeGroups: const <XTypeGroup>[_imageTypes],
      ),
      AttachmentPickerSource.file => await openFile(),
      AttachmentPickerSource.camera => await _capture(),
    };
    if (file == null) {
      return null;
    }
    return ImageSelection(
      displayName: file.name,
      declaredMimeType: file.mimeType,
      byteLength: await file.length(),
      openRead: ({int? start, int? end}) => file.openRead(start, end),
    );
  }

  Future<XFile?> _capture() async {
    try {
      return await camera.ImagePicker().pickImage(
        source: camera.ImageSource.camera,
      );
    } on PlatformException catch (error) {
      throw ImageAttachmentPickerException(
        error.code == 'camera_access_denied'
            ? ImageAttachmentPickerError.cameraPermissionDenied
            : ImageAttachmentPickerError.cameraUnavailable,
      );
    } on MissingPluginException {
      throw const ImageAttachmentPickerException(
        ImageAttachmentPickerError.cameraUnavailable,
      );
    }
  }
}

final class DurableImageAttachmentPicker {
  DurableImageAttachmentPicker({
    required this.backend,
    required this.store,
    required this.maximumImageBytes,
  }) {
    if (maximumImageBytes < 1 || maximumImageBytes > store.maximumSourceBytes) {
      throw ArgumentError.value(
        maximumImageBytes,
        'maximumImageBytes',
        'must be within the durable store limit',
      );
    }
  }

  final ImageSelectionBackend backend;
  final DurableAttachmentSourceStore store;
  final int maximumImageBytes;

  Future<PreparedAttachmentSource?> pick({
    AttachmentPickerSource source = AttachmentPickerSource.gallery,
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    final selection = await backend.selectImage(source);
    if (selection == null) {
      return null;
    }
    if (selection.byteLength < 1) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.emptySource,
      );
    }
    if (selection.byteLength > maximumImageBytes) {
      throw const DurableAttachmentSourceException(
        DurableAttachmentSourceError.sourceTooLarge,
      );
    }
    final imageOnly = source != AttachmentPickerSource.file;
    final displayName = _safeDisplayName(
      selection.displayName,
      fallback: imageOnly ? 'image' : 'attachment',
    );
    final header = await _readPrefix(
      selection.openRead(
        start: 0,
        end: min(selection.byteLength, defaultMagicNumbersMaxLength),
      ),
      defaultMagicNumbersMaxLength,
    );
    final detected = lookupMimeType(displayName, headerBytes: header);
    final mimeType = _normalizeMimeType(detected ?? selection.declaredMimeType);
    if (imageOnly && (mimeType == null || !mimeType.startsWith('image/'))) {
      throw const ImageAttachmentPickerException(
        ImageAttachmentPickerError.unsupportedType,
      );
    }
    return store.copyFromStream(
      stream: selection.openRead(),
      expectedByteLength: selection.byteLength,
      // An unrecognised file still has to reach the server with a MIME type
      // that describes it honestly, so it falls back to the generic one
      // instead of borrowing whatever the platform guessed.
      mimeType: mimeType ?? 'application/octet-stream',
      displayName: displayName,
      cancellationSignal: cancellationSignal,
    );
  }
}

Future<List<int>> _readPrefix(Stream<List<int>> stream, int maximum) async {
  final bytes = <int>[];
  final iterator = StreamIterator<List<int>>(stream);
  try {
    while (bytes.length < maximum && await iterator.moveNext()) {
      final chunk = iterator.current;
      final remaining = maximum - bytes.length;
      bytes.addAll(chunk.length <= remaining ? chunk : chunk.take(remaining));
    }
  } finally {
    await iterator.cancel();
  }
  return bytes;
}

final RegExp _mimeTypePattern = RegExp(
  r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$',
);

/// Drops parameters such as `; charset=utf-8` and rejects anything the
/// protocol layer would refuse, so a hostile or malformed platform MIME type
/// can never reach [PreparedAttachmentSource].
String? _normalizeMimeType(String? value) {
  if (value == null) {
    return null;
  }
  final essence = value.split(';').first.trim().toLowerCase();
  if (essence.length > 255 || !_mimeTypePattern.hasMatch(essence)) {
    return null;
  }
  return essence;
}

String _safeDisplayName(String value, {required String fallback}) {
  var name = p
      .basename(value)
      .trim()
      .replaceAll(RegExp(r'[\\/\x00-\x1f\x7f]'), '_');
  if (name.isEmpty || name == '.' || name == '..') {
    name = fallback;
  }
  if (name.length <= 255) {
    return name;
  }
  final extension = p.extension(name);
  final extensionLength = min(extension.length, 32);
  final suffix = extension.substring(extension.length - extensionLength);
  return '${name.substring(0, 255 - suffix.length)}$suffix';
}
