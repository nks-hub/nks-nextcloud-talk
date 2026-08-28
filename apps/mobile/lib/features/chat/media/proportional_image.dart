import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Decodes [bytes] no larger than [maxEdge] on its longest side, keeping the
/// picture's proportions.
///
/// Handing `Image.memory` both `cacheWidth` and `cacheHeight` looks like a
/// bounding box but is not one: `ResizeImage` defaults to
/// [ResizeImagePolicy.exact] and resizes the bitmap to exactly those
/// dimensions, so every non-square picture decodes squashed into a square.
/// `BoxFit.contain` cannot undo that — it only fits an already distorted
/// bitmap into the widget, which is why the composer preview still looked
/// wrong after it was switched away from `BoxFit.cover`.
/// [ResizeImagePolicy.fit] treats the two numbers as the box they read like.
Widget proportionalMemoryImage({
  required Uint8List bytes,
  required int maxEdge,
  Key? key,
  BoxFit fit = BoxFit.contain,
  FilterQuality filterQuality = FilterQuality.medium,
  bool gaplessPlayback = false,
  ImageErrorWidgetBuilder? errorBuilder,
  ImageFrameBuilder? frameBuilder,
}) {
  return Image(
    key: key,
    image: ResizeImage(
      MemoryImage(bytes),
      width: maxEdge,
      height: maxEdge,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    ),
    fit: fit,
    filterQuality: filterQuality,
    gaplessPlayback: gaplessPlayback,
    errorBuilder: errorBuilder,
    frameBuilder: frameBuilder,
  );
}
