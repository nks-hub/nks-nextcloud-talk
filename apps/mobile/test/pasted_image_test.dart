import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/pasted_image.dart';

// A 2x2 24-bit BMP, the shape Windows hands over for a clipboard bitmap.
final Uint8List _bmp = Uint8List.fromList(<int>[
  0x42,
  0x4D,
  0x46,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x36,
  0x00,
  0x00,
  0x00,
  0x28,
  0x00,
  0x00,
  0x00,
  0x02,
  0x00,
  0x00,
  0x00,
  0x02,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x18,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x00,
  0x13,
  0x0B,
  0x00,
  0x00,
  0x13,
  0x0B,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0xFF,
  0xFF,
  0xFF,
  0xFF,
  0x00,
  0x00,
  0xFF,
  0x00,
  0x00,
  0x00,
  0xFF,
  0x00,
  0x00,
  0x00,
]);

void main() {
  final at = DateTime(2026, 9, 3, 18, 42, 7);

  test('known formats pass through with a matching name', () async {
    final png = Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      1,
      2,
      3,
    ]);
    final image = await normalizePastedImage(png, now: () => at);
    expect(image?.mimeType, 'image/png');
    expect(image?.displayName, 'screenshot-20260903-184207.png');
    expect(image?.bytes, same(png));

    final jpeg = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0, 0]);
    expect((await normalizePastedImage(jpeg))?.mimeType, 'image/jpeg');
  });

  testWidgets('a clipboard bitmap is re-encoded as PNG', (tester) async {
    final image = await tester.runAsync(
      () => normalizePastedImage(_bmp, now: () => at),
    );
    expect(image, isNotNull);
    expect(image!.mimeType, 'image/png');
    expect(image.displayName, 'screenshot-20260903-184207.png');
    expect(image.bytes.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
  });

  testWidgets('bytes that are not an image are refused', (tester) async {
    final image = await tester.runAsync(
      () => normalizePastedImage(Uint8List.fromList('not an image'.codeUnits)),
    );
    expect(image, isNull);
    expect(await normalizePastedImage(Uint8List(0)), isNull);
  });
}
