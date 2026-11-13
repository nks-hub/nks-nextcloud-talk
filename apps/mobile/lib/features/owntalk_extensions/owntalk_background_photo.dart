import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' as platform_picker;

/// A photo ready to upload.
typedef OwnTalkBackgroundPhoto = ({Uint8List bytes, String contentType});

enum OwnTalkPhotoError {
  /// Not a JPEG, PNG or WebP file.
  unsupportedType,

  /// The bytes carry such a header but cannot be decoded.
  unreadable,

  /// Still over the server's byte limit after scaling down.
  tooLarge,
}

final class OwnTalkPhotoException implements Exception {
  const OwnTalkPhotoException(this.error);

  final OwnTalkPhotoError error;

  @override
  String toString() => 'OwnTalkPhotoException(${error.name})';
}

/// Lets the user choose a photo and returns it ready for the server, or `null`
/// when they cancelled. Replaced in tests.
typedef OwnTalkPhotoPicker =
    Future<OwnTalkBackgroundPhoto?> Function({
      required int maxBytes,
      required int maxEdge,
    });

final ownTalkPhotoPickerProvider = Provider<OwnTalkPhotoPicker>(
  (ref) => pickOwnTalkBackgroundPhoto,
);

const XTypeGroup _photoTypes = XTypeGroup(
  label: 'Photos',
  extensions: <String>['jpeg', 'jpg', 'png', 'webp'],
  mimeTypes: <String>['image/jpeg', 'image/png', 'image/webp'],
  uniformTypeIdentifiers: <String>[
    'public.jpeg',
    'public.png',
    'org.webmproject.webp',
  ],
);

/// Same split as the attachment picker: the native photo library on iOS, the
/// system file dialog elsewhere.
Future<OwnTalkBackgroundPhoto?> pickOwnTalkBackgroundPhoto({
  required int maxBytes,
  required int maxEdge,
}) async {
  final XFile? file;
  try {
    file = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? await platform_picker.ImagePicker().pickImage(
            source: platform_picker.ImageSource.gallery,
            maxWidth: maxEdge.toDouble(),
            maxHeight: maxEdge.toDouble(),
            imageQuality: 88,
          )
        : await openFile(acceptedTypeGroups: const [_photoTypes]);
  } on MissingPluginException {
    throw const OwnTalkPhotoException(OwnTalkPhotoError.unreadable);
  }
  if (file == null) {
    return null;
  }
  return prepareOwnTalkBackgroundPhoto(
    await file.readAsBytes(),
    maxBytes: maxBytes,
    maxEdge: maxEdge,
  );
}

/// The server refuses more than this many pixels per side or in total, before
/// it decodes anything.
const int _serverMaximumEdge = 8192;
const int _serverMaximumPixels = 40 * 1000 * 1000;

/// Checks the type of [bytes] by content and, when the photo is too heavy or
/// much larger than the server's [maxEdge], scales it down. Scaling re-encodes
/// as PNG, the only still format `dart:ui` writes, so it steps the edge down
/// until the result fits [maxBytes].
Future<OwnTalkBackgroundPhoto> prepareOwnTalkBackgroundPhoto(
  Uint8List bytes, {
  required int maxBytes,
  required int maxEdge,
}) async {
  final contentType = _sniffContentType(bytes);
  if (contentType == null) {
    throw const OwnTalkPhotoException(OwnTalkPhotoError.unsupportedType);
  }
  final size = await _decodedSize(bytes);
  final longest = max(size.width, size.height);
  final fits =
      bytes.length <= maxBytes &&
      longest <= min(maxEdge * 2, _serverMaximumEdge) &&
      size.width * size.height <= _serverMaximumPixels;
  if (fits) {
    return (bytes: bytes, contentType: contentType);
  }
  for (final edge in _edgeSteps(maxEdge, longest)) {
    final scaled = await _scaledPng(bytes, size, edge);
    if (scaled.length <= maxBytes) {
      return (bytes: scaled, contentType: 'image/png');
    }
  }
  throw const OwnTalkPhotoException(OwnTalkPhotoError.tooLarge);
}

/// The server's [maxEdge] first (or the photo's own edge when that is
/// smaller), then ever smaller fractions of it.
List<int> _edgeSteps(int maxEdge, int longest) {
  final start = min(maxEdge, longest);
  return {
    for (final factor in const [1.0, 0.75, 0.55, 0.4, 0.28])
      max(1, (start * factor).round()),
  }.toList();
}

String? _sniffContentType(Uint8List bytes) {
  bool startsWith(List<int> prefix, [int offset = 0]) {
    if (bytes.length < offset + prefix.length) {
      return false;
    }
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[offset + index] != prefix[index]) {
        return false;
      }
    }
    return true;
  }

  if (startsWith(const [0xFF, 0xD8, 0xFF])) {
    return 'image/jpeg';
  }
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  // "RIFF" <size> "WEBP"
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}

Future<({int width, int height})> _decodedSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (width: descriptor.width, height: descriptor.height);
  } on Object {
    throw const OwnTalkPhotoException(OwnTalkPhotoError.unreadable);
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<Uint8List> _scaledPng(
  Uint8List bytes,
  ({int width, int height}) size,
  int edge,
) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    final landscape = size.width >= size.height;
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: landscape ? edge : null,
      targetHeight: landscape ? null : edge,
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const OwnTalkPhotoException(OwnTalkPhotoError.unreadable);
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on OwnTalkPhotoException {
    rethrow;
  } on Object {
    throw const OwnTalkPhotoException(OwnTalkPhotoError.unreadable);
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
