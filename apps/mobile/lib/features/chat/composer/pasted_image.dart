import 'dart:typed_data';
import 'dart:ui' as ui;

/// An image that arrived as bytes rather than as a file: a screenshot pasted
/// with Ctrl/Cmd+V, or content a mobile keyboard inserted.
typedef PastedImage = ({Uint8List bytes, String mimeType, String displayName});

/// Turns clipboard bytes into something the attachment path accepts.
///
/// PNG, JPEG, GIF and WebP go through untouched with their own extension.
/// Anything else the platform hands over — Windows delivers the clipboard
/// bitmap as BMP — is re-encoded as PNG, because a raw bitmap is several
/// times the size and not every viewer opens it. Returns null when the bytes
/// are not an image the engine can decode.
Future<PastedImage?> normalizePastedImage(
  Uint8List raw, {
  DateTime Function()? now,
}) async {
  if (raw.isEmpty) {
    return null;
  }
  final stamp = _stamp((now ?? DateTime.now)());
  final known = _knownFormat(raw);
  if (known != null) {
    return (
      bytes: raw,
      mimeType: known.$1,
      displayName: 'screenshot-$stamp.${known.$2}',
    );
  }
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(raw);
  } on Object {
    return null;
  }
  try {
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (png == null) {
      return null;
    }
    return (
      bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      mimeType: 'image/png',
      displayName: 'screenshot-$stamp.png',
    );
  } on Object {
    return null;
  } finally {
    codec.dispose();
  }
}

(String, String)? _knownFormat(Uint8List bytes) {
  bool startsWith(List<int> magic) {
    if (bytes.length < magic.length) {
      return false;
    }
    for (var index = 0; index < magic.length; index++) {
      if (bytes[index] != magic[index]) {
        return false;
      }
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return ('image/png', 'png');
  }
  if (startsWith(const [0xFF, 0xD8, 0xFF])) {
    return ('image/jpeg', 'jpg');
  }
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) {
    return ('image/gif', 'gif');
  }
  if (bytes.length >= 12 &&
      startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return ('image/webp', 'webp');
  }
  return null;
}

String _stamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}${two(time.month)}${two(time.day)}-'
      '${two(time.hour)}${two(time.minute)}${two(time.second)}';
}
