import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/media/proportional_image.dart';

/// Smallest valid PNG the decoder accepts; the bytes never have to decode for
/// these assertions, only the provider configuration matters.
final Uint8List _pngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
]);

void main() {
  testWidgets('the decode box keeps the picture proportions', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: proportionalMemoryImage(bytes: _pngBytes, maxEdge: 2048),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;

    // ResizeImagePolicy.exact — the default, and what `Image.memory` uses when
    // it is given both cacheWidth and cacheHeight — resizes to exactly the box
    // and squashes every non-square picture into a square. BoxFit cannot undo
    // that, because by then the bitmap itself is already distorted.
    expect(provider.policy, ResizeImagePolicy.fit);
    expect(provider.width, 2048);
    expect(provider.height, 2048);
    expect(
      provider.allowUpscaling,
      isFalse,
      reason: 'a small picture must not be blown up to the cap',
    );
  });

  testWidgets('the image itself is still fitted, never cropped', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: proportionalMemoryImage(bytes: _pngBytes, maxEdge: 480),
      ),
    );

    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
  });
}
