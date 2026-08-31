import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/features/chat/chat_background_theme.dart';

void main() {
  test('parses only opaque six-digit colours', () {
    expect(parseChatBackgroundColor('#12abEF'), const Color(0xFF12ABEF));
    expect(parseChatBackgroundColor('#1234'), isNull);
    expect(parseChatBackgroundColor('#12345678'), isNull);
    expect(parseChatBackgroundColor('red'), isNull);
  });

  test('arbitrary backgrounds keep text and outlines in the contrast gate', () {
    final schemes = <ColorScheme>[
      for (final seed in <Color?>[
        null,
        const Color(0xFFB00020),
        const Color(0xFF00A651),
        const Color(0xFF6A1B9A),
      ]) ...[
        AppTheme.light(seedColor: seed).colorScheme,
        AppTheme.dark(seedColor: seed).colorScheme,
      ],
    ];
    for (final scheme in schemes) {
      for (final requested in <Color>[
        Colors.black,
        Colors.white,
        const Color(0xFFFF00FF),
        const Color(0xFF00FF00),
        const Color(0xFF00679E),
      ]) {
        final background = safeChatBackground(requested, scheme);
        expect(
          chatBackgroundContrast(background, scheme.onSurface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          chatBackgroundContrast(background, scheme.onSurfaceVariant),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          chatBackgroundContrast(background, scheme.outline),
          greaterThanOrEqualTo(3),
        );
        expect(
          chatBackgroundContrast(background, scheme.outlineVariant),
          greaterThanOrEqualTo(3),
        );
      }
    }
  });
}
