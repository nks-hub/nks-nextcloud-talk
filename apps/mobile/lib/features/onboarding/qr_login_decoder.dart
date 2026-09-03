import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// Reads a QR code out of one planar 8-bit luminance frame.
///
/// Camera frames arrive as YUV, whose first plane is exactly the luminance
/// ZXing wants, so nothing has to be converted: the plane is wrapped and read
/// in place. Returns null whenever the frame holds no readable QR code, which
/// is the normal case for almost every frame.
String? decodeQrFromLuminance({
  required Uint8List luma,
  required int width,
  required int height,
  required int bytesPerRow,
}) {
  if (width <= 0 || height <= 0 || bytesPerRow < width) {
    return null;
  }
  if (luma.length < bytesPerRow * (height - 1) + width) {
    return null;
  }
  try {
    final bitmap = BinaryBitmap(
      HybridBinarizer(_PlanarLuminanceSource(luma, width, height, bytesPerRow)),
    );
    return QRCodeReader().decode(bitmap).text;
  } on Object {
    // Every "there is no QR code in this frame" answer arrives as an
    // exception: NotFoundException, FormatReaderException or ChecksumException
    // depending on how far the detector got. None of them is actionable.
    return null;
  }
}

/// A [LuminanceSource] over a camera plane whose rows may be padded.
final class _PlanarLuminanceSource extends LuminanceSource {
  _PlanarLuminanceSource(this._luma, int width, int height, this._bytesPerRow)
    : super(width, height);

  final Uint8List _luma;
  final int _bytesPerRow;

  @override
  Int8List getRow(int y, Int8List? row) {
    final output = row == null || row.length < width ? Int8List(width) : row;
    final start = y * _bytesPerRow;
    for (var x = 0; x < width; x++) {
      output[x] = _luma[start + x];
    }
    return output;
  }

  @override
  Int8List getMatrix() {
    if (_bytesPerRow == width) {
      // Unpadded rows are already row-major luminance; reinterpreting the same
      // bytes as signed is what ZXing's `& 0xFF` readers expect.
      return _luma.buffer.asInt8List(_luma.offsetInBytes, width * height);
    }
    final matrix = Int8List(width * height);
    for (var y = 0; y < height; y++) {
      final source = y * _bytesPerRow;
      final destination = y * width;
      for (var x = 0; x < width; x++) {
        matrix[destination + x] = _luma[source + x];
      }
    }
    return matrix;
  }
}
