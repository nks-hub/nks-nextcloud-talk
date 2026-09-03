import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/onboarding/qr_login_decoder.dart';
import 'package:zxing2/qrcode.dart';

/// Renders a real QR code for [content] into a padded luminance plane, the way
/// a camera hands one over: white background, black modules, a quiet zone and
/// a row stride wider than the image.
({Uint8List luma, int width, int height, int bytesPerRow}) _render(
  String content, {
  int scale = 4,
  int quietZone = 16,
  int rowPadding = 7,
}) {
  final code = Encoder.encode(content, ErrorCorrectionLevel.m);
  final matrix = code.matrix!;
  final width = matrix.width * scale + quietZone * 2;
  final height = matrix.height * scale + quietZone * 2;
  final bytesPerRow = width + rowPadding;
  final luma = Uint8List(bytesPerRow * height)..fillRange(0, bytesPerRow * height, 0xFF);
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) == 0) {
        continue;
      }
      for (var dy = 0; dy < scale; dy++) {
        final row = (quietZone + y * scale + dy) * bytesPerRow;
        final start = row + quietZone + x * scale;
        luma.fillRange(start, start + scale, 0x00);
      }
    }
  }
  return (luma: luma, width: width, height: height, bytesPerRow: bytesPerRow);
}

void main() {
  test('reads a rendered login payload back out of a padded plane', () {
    const payload =
        'nc://login/user:testuser&server:https%3A//example.com&password:s3cr3t';
    final frame = _render(payload);
    expect(
      decodeQrFromLuminance(
        luma: frame.luma,
        width: frame.width,
        height: frame.height,
        bytesPerRow: frame.bytesPerRow,
      ),
      payload,
    );
  });

  test('reads the same payload from an unpadded plane', () {
    const payload = 'nc://login/server:https%3A//example.com';
    final frame = _render(payload, rowPadding: 0);
    expect(
      decodeQrFromLuminance(
        luma: frame.luma,
        width: frame.width,
        height: frame.height,
        bytesPerRow: frame.bytesPerRow,
      ),
      payload,
    );
  });

  test('returns null for a frame that holds no code', () {
    final luma = Uint8List(320 * 240)..fillRange(0, 320 * 240, 0xFF);
    expect(
      decodeQrFromLuminance(
        luma: luma,
        width: 320,
        height: 240,
        bytesPerRow: 320,
      ),
      isNull,
    );
  });

  test('returns null instead of reading past a short buffer', () {
    final frame = _render('nc://login/server:https%3A//example.com');
    expect(
      decodeQrFromLuminance(
        luma: Uint8List.sublistView(frame.luma, 0, frame.luma.length ~/ 2),
        width: frame.width,
        height: frame.height,
        bytesPerRow: frame.bytesPerRow,
      ),
      isNull,
    );
  });

  test('returns null for a stride narrower than the image', () {
    final frame = _render('nc://login/server:https%3A//example.com');
    expect(
      decodeQrFromLuminance(
        luma: frame.luma,
        width: frame.width,
        height: frame.height,
        bytesPerRow: frame.width - 1,
      ),
      isNull,
    );
  });
}
