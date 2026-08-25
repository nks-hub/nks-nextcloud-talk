import 'dart:async';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:mime/mime.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:path/path.dart' as p;
import 'package:talk_protocol/talk_protocol.dart';

enum ImageAttachmentPickerError { unsupportedType, invalidSelection }

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
  Future<ImageSelection?> selectImage();
}

final class FileSelectorImageSelectionBackend implements ImageSelectionBackend {
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

  const FileSelectorImageSelectionBackend();

  @override
  Future<ImageSelection?> selectImage() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[_imageTypes],
    );
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
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    final selection = await backend.selectImage();
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
    final displayName = _safeDisplayName(selection.displayName);
    final header = await _readPrefix(
      selection.openRead(
        start: 0,
        end: min(selection.byteLength, defaultMagicNumbersMaxLength),
      ),
      defaultMagicNumbersMaxLength,
    );
    final detected = lookupMimeType(displayName, headerBytes: header);
    final mimeType = detected ?? selection.declaredMimeType;
    if (mimeType == null || !mimeType.startsWith('image/')) {
      throw const ImageAttachmentPickerException(
        ImageAttachmentPickerError.unsupportedType,
      );
    }
    return store.copyFromStream(
      stream: selection.openRead(),
      expectedByteLength: selection.byteLength,
      mimeType: mimeType,
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

String _safeDisplayName(String value) {
  var name = p
      .basename(value)
      .trim()
      .replaceAll(RegExp(r'[\\/\x00-\x1f\x7f]'), '_');
  if (name.isEmpty || name == '.' || name == '..') {
    name = 'image';
  }
  if (name.length <= 255) {
    return name;
  }
  final extension = p.extension(name);
  final extensionLength = min(extension.length, 32);
  final suffix = extension.substring(extension.length - extensionLength);
  return '${name.substring(0, 255 - suffix.length)}$suffix';
}
