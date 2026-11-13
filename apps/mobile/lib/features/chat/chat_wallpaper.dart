import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'chat_background_theme.dart';

enum ChatWallpaperKind { diagonal, vertical, dots, grid }

/// A background the client draws itself. [light] and [dark] are the stops of a
/// gradient or, for the patterns, the base colour followed by the ink colour.
/// Both sets are chosen so the theme's text and borders stay readable; every
/// colour still goes through [safeChatBackground] before it is painted. The
/// faint divider colour is left out of that check, which would otherwise
/// reduce every preset to a near-white or near-black tint.
final class ChatWallpaperPreset {
  const ChatWallpaperPreset({
    required this.id,
    required this.kind,
    required this.light,
    required this.dark,
  });

  final String id;
  final ChatWallpaperKind kind;
  final List<Color> light;
  final List<Color> dark;

  List<Color> colorsFor(ColorScheme scheme) => [
    for (final color in scheme.brightness == Brightness.dark ? dark : light)
      safeChatBackground(color, scheme, dividers: false),
  ];
}

/// Every preset this client can draw. The server decides which IDs may be
/// chosen; an ID missing here is shown as the theme.
const List<ChatWallpaperPreset> chatWallpaperPresets = [
  ChatWallpaperPreset(
    id: 'aurora',
    kind: ChatWallpaperKind.diagonal,
    light: [Color(0xFFC8F5E4), Color(0xFFCFE0FA), Color(0xFFE0D0F7)],
    dark: [Color(0xFF0A2E33), Color(0xFF121C45), Color(0xFF2A1445)],
  ),
  ChatWallpaperPreset(
    id: 'sunset',
    kind: ChatWallpaperKind.vertical,
    light: [Color(0xFFFFE2C2), Color(0xFFFFCFD6), Color(0xFFE6D0F2)],
    dark: [Color(0xFF1E1240), Color(0xFF3A1636), Color(0xFF4A1A1A)],
  ),
  ChatWallpaperPreset(
    id: 'forest',
    kind: ChatWallpaperKind.diagonal,
    light: [Color(0xFFD3EFCF), Color(0xFFBFE3C3)],
    dark: [Color(0xFF0A2418), Color(0xFF0F3320)],
  ),
  ChatWallpaperPreset(
    id: 'ocean',
    kind: ChatWallpaperKind.vertical,
    light: [Color(0xFFCBE8FA), Color(0xFFB9DDF5)],
    dark: [Color(0xFF08243F), Color(0xFF0A2F4A)],
  ),
  ChatWallpaperPreset(
    id: 'dots',
    kind: ChatWallpaperKind.dots,
    light: [Color(0xFFF4F6F8), Color(0xFFD5DBE1)],
    dark: [Color(0xFF101820), Color(0xFF1F2D3A)],
  ),
  ChatWallpaperPreset(
    id: 'grid',
    kind: ChatWallpaperKind.grid,
    light: [Color(0xFFF4F6F8), Color(0xFFD0D7DE)],
    dark: [Color(0xFF10181F), Color(0xFF1D2B38)],
  ),
];

/// The preset this client draws for [id], or `null` for `null` and for an ID it
/// does not know.
ChatWallpaperPreset? chatWallpaperPresetById(String? id) {
  for (final preset in chatWallpaperPresets) {
    if (preset.id == id) {
      return preset;
    }
  }
  return null;
}

/// The presets to offer: those the server lists that this client can draw, in
/// the server's order.
List<ChatWallpaperPreset> offeredChatWallpaperPresets(
  Iterable<String> serverIds,
) => [for (final id in serverIds) ?chatWallpaperPresetById(id)];

/// Paints [preset] to fill its parent, in the colours of the current theme.
final class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({super.key, required this.preset});

  final ChatWallpaperPreset preset;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WallpaperPainter(
        preset.kind,
        preset.colorsFor(Theme.of(context).colorScheme),
      ),
      child: const SizedBox.expand(),
    );
  }
}

final class _WallpaperPainter extends CustomPainter {
  const _WallpaperPainter(this.kind, this.colors);

  final ChatWallpaperKind kind;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    switch (kind) {
      case ChatWallpaperKind.diagonal:
      case ChatWallpaperKind.vertical:
        final diagonal = kind == ChatWallpaperKind.diagonal;
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: diagonal ? Alignment.topLeft : Alignment.topCenter,
              end: diagonal ? Alignment.bottomRight : Alignment.bottomCenter,
              colors: colors,
            ).createShader(rect),
        );
      case ChatWallpaperKind.dots:
        canvas.drawRect(rect, Paint()..color = colors[0]);
        final ink = Paint()..color = colors[1];
        const spacing = 22.0;
        for (var y = spacing / 2; y < size.height; y += spacing) {
          // Every other row is shifted by half a step.
          final shift = ((y / spacing).floor().isOdd) ? spacing / 2 : 0.0;
          for (var x = spacing / 2 + shift; x < size.width; x += spacing) {
            canvas.drawCircle(Offset(x, y), 1.8, ink);
          }
        }
      case ChatWallpaperKind.grid:
        canvas.drawRect(rect, Paint()..color = colors[0]);
        final ink = Paint()
          ..color = colors[1]
          ..strokeWidth = 1;
        const spacing = 28.0;
        for (var x = 0.0; x < size.width; x += spacing) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), ink);
        }
        for (var y = 0.0; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), ink);
        }
    }
  }

  @override
  bool shouldRepaint(_WallpaperPainter oldDelegate) =>
      oldDelegate.kind != kind || !_sameColors(oldDelegate.colors, colors);

  bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) {
        return false;
      }
    }
    return true;
  }
}

/// Tells the chat below whether a preset or a photo is drawn behind it. Text
/// that sits straight on the background then gets a [ChatBackgroundChip].
final class ChatWallpaperScope extends InheritedWidget {
  const ChatWallpaperScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool isActive(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ChatWallpaperScope>()
          ?.active ??
      false;

  @override
  bool updateShouldNotify(ChatWallpaperScope oldWidget) =>
      active != oldWidget.active;
}

/// A small translucent surface behind text that is drawn without a bubble.
/// Without a wallpaper behind it, it is just [child].
final class ChatBackgroundChip extends StatelessWidget {
  const ChatBackgroundChip({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    this.radius = 12,
    this.centered = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// Centre the chip in the width it is given, as a block of centred text
  /// would be.
  final bool centered;

  /// The chip colour for this position in the tree, `null` without a
  /// wallpaper.
  static Color? colorOf(BuildContext context) {
    if (!ChatWallpaperScope.isActive(context)) {
      return null;
    }
    final scheme = Theme.of(context).colorScheme;
    return scheme.surface.withValues(alpha: wallpaperChipAlpha(scheme));
  }

  @override
  Widget build(BuildContext context) {
    final color = colorOf(context);
    if (color == null) {
      return child;
    }
    final chip = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(padding: padding, child: child),
    );
    return centered ? Center(child: chip) : chip;
  }
}

/// A photo wallpaper: [bytes] scaled to cover its parent under a light veil
/// of the theme's surface. Bubbles have their own background; text drawn
/// straight on the photo sits on a [ChatBackgroundChip]. The veil only appears
/// once the photo is on screen, so a failed decode leaves what lies beneath
/// untouched.
final class ChatWallpaperPhoto extends StatelessWidget {
  const ChatWallpaperPhoto({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      frameBuilder: (context, child, frame, synchronous) {
        if (frame == null) {
          return const SizedBox.shrink();
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            ColoredBox(
              key: const Key('chat-wallpaper-scrim'),
              color: scheme.surface.withValues(alpha: photoScrimAlpha(scheme)),
            ),
          ],
        );
      },
    );
  }
}
