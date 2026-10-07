import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';

bool get imageClipboardSupported =>
    kIsWeb || defaultTargetPlatform != TargetPlatform.linux;

Future<bool> copyImageBytes(Uint8List bytes) async {
  if (!imageClipboardSupported) return false;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        // Bound decoded memory before allocating a bitmap from a remote file.
        if (descriptor.width * descriptor.height > 32 * 1024 * 1024) {
          return false;
        }
        final codec = await descriptor.instantiateCodec();
        try {
          final frame = await codec.getNextFrame();
          try {
            final png = await frame.image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (png == null) return false;
            await Pasteboard.writeImage(
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
            );
            return true;
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  } on Object {
    // Native clipboard access and image decoding can both reject the input.
    return false;
  }
}
