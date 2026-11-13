import 'package:flutter/material.dart';

final RegExp _chatBackgroundColorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

Color? parseChatBackgroundColor(String? value) {
  if (value == null || !_chatBackgroundColorPattern.hasMatch(value)) {
    return null;
  }
  final rgb = int.tryParse(value.substring(1), radix: 16);
  return rgb == null ? null : Color(0xFF000000 | rgb);
}

/// [requested] blended towards the theme surface until text and borders read
/// on it. [dividers] also requires the faint divider colour to show; a
/// decorative wallpaper that only sits behind the chat can do without that.
Color safeChatBackground(
  Color requested,
  ColorScheme scheme, {
  bool dividers = true,
}) {
  for (var step = 20; step >= 0; step--) {
    final alpha = step / 20;
    final candidate = Color.alphaBlend(
      requested.withValues(alpha: alpha),
      scheme.surface,
    );
    if (_contrast(candidate, scheme.onSurface) >= 4.5 &&
        _contrast(candidate, scheme.onSurfaceVariant) >= 4.5 &&
        _contrast(candidate, scheme.outline) >= 3 &&
        (!dividers || _contrast(candidate, scheme.outlineVariant) >= 3)) {
      return candidate;
    }
  }
  return scheme.surface;
}

/// Opacity of a surface-coloured veil over a photo wallpaper: the lowest one
/// for which the theme's text still reaches 4.5:1 on the worst possible photo,
/// a pure black or a pure white one.
double wallpaperScrimAlpha(ColorScheme scheme) {
  for (var step = 8; step < 20; step++) {
    final alpha = step / 20;
    final readsOnBoth = const [Color(0xFF000000), Color(0xFFFFFFFF)].every((
      photo,
    ) {
      final veiled = Color.alphaBlend(
        scheme.surface.withValues(alpha: alpha),
        photo,
      );
      return _contrast(veiled, scheme.onSurface) >= 4.5 &&
          _contrast(veiled, scheme.onSurfaceVariant) >= 4.5;
    });
    if (readsOnBoth) {
      return alpha;
    }
  }
  return 1;
}

double chatBackgroundContrast(Color first, Color second) =>
    _contrast(first, second);

double _contrast(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
