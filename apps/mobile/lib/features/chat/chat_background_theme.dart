import 'package:flutter/material.dart';

final RegExp _chatBackgroundColorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

Color? parseChatBackgroundColor(String? value) {
  if (value == null || !_chatBackgroundColorPattern.hasMatch(value)) {
    return null;
  }
  final rgb = int.tryParse(value.substring(1), radix: 16);
  return rgb == null ? null : Color(0xFF000000 | rgb);
}

Color safeChatBackground(Color requested, ColorScheme scheme) {
  for (var step = 20; step >= 0; step--) {
    final alpha = step / 20;
    final candidate = Color.alphaBlend(
      requested.withValues(alpha: alpha),
      scheme.surface,
    );
    if (_contrast(candidate, scheme.onSurface) >= 4.5 &&
        _contrast(candidate, scheme.onSurfaceVariant) >= 4.5 &&
        _contrast(candidate, scheme.outline) >= 3 &&
        _contrast(candidate, scheme.outlineVariant) >= 3) {
      return candidate;
    }
  }
  return scheme.surface;
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
