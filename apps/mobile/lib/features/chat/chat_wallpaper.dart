import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'chat_background_theme.dart';

enum ChatWallpaperKind {
  diagonal,
  vertical,
  dots,
  grid,
  mesh,
  bokeh,
  waves,
  dunes,
  topo,
  stars,
  confetti,
}

/// A background the client draws itself. [light] and [dark] are the stops of a
/// gradient or, for the patterns, the base colour followed by the ink colours:
/// `mesh` is a base and its glows, `topo` a base and its line colour, and the
/// other patterns two gradient stops followed by their shape colours.
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
  ChatWallpaperPreset(
    id: 'lavender',
    kind: ChatWallpaperKind.diagonal,
    light: [Color(0xFFE9E0FA), Color(0xFFF6DDF0), Color(0xFFDCE6FB)],
    dark: [Color(0xFF1C1433), Color(0xFF2A1238), Color(0xFF141B3A)],
  ),
  ChatWallpaperPreset(
    id: 'peach',
    kind: ChatWallpaperKind.vertical,
    light: [Color(0xFFFFE6D5), Color(0xFFFFD9DF), Color(0xFFFFEFD9)],
    dark: [Color(0xFF2E1712), Color(0xFF33121F), Color(0xFF2B1F10)],
  ),
  ChatWallpaperPreset(
    id: 'mint',
    kind: ChatWallpaperKind.diagonal,
    light: [Color(0xFFD6F7EC), Color(0xFFD3F0F7), Color(0xFFE8F7D6)],
    dark: [Color(0xFF0B2A24), Color(0xFF0A2530), Color(0xFF15280C)],
  ),
  ChatWallpaperPreset(
    id: 'nebula',
    kind: ChatWallpaperKind.mesh,
    light: [
      Color(0xFFF2EEFB),
      Color(0xFFD9CCF7),
      Color(0xFFCDE7FA),
      Color(0xFFF8D3E6),
    ],
    dark: [
      Color(0xFF0E0F24),
      Color(0xFF2A1650),
      Color(0xFF0E2C4A),
      Color(0xFF3A1236),
    ],
  ),
  ChatWallpaperPreset(
    id: 'bokeh',
    kind: ChatWallpaperKind.bokeh,
    light: [
      Color(0xFFEAF2FB),
      Color(0xFFF5EAF7),
      Color(0xFFD2E4F7),
      Color(0xFFF3D6EC),
    ],
    dark: [
      Color(0xFF0C1426),
      Color(0xFF1A0F24),
      Color(0xFF1B2A4A),
      Color(0xFF35183A),
    ],
  ),
  ChatWallpaperPreset(
    id: 'waves',
    kind: ChatWallpaperKind.waves,
    light: [
      Color(0xFFEAF6FC),
      Color(0xFFE0F1FA),
      Color(0xFFD5ECF8),
      Color(0xFFC6E4F5),
      Color(0xFFB9DDF2),
    ],
    dark: [
      Color(0xFF071724),
      Color(0xFF081C2B),
      Color(0xFF0A2233),
      Color(0xFF0B263A),
      Color(0xFF0C2B40),
    ],
  ),
  ChatWallpaperPreset(
    id: 'dunes',
    kind: ChatWallpaperKind.dunes,
    light: [
      Color(0xFFFFF6E8),
      Color(0xFFFDEFE0),
      Color(0xFFFBEBD4),
      Color(0xFFF6E0C4),
      Color(0xFFF1D6B5),
    ],
    dark: [
      Color(0xFF1A1208),
      Color(0xFF1D1409),
      Color(0xFF241808),
      Color(0xFF2C1E0B),
      Color(0xFF33230D),
    ],
  ),
  ChatWallpaperPreset(
    id: 'topo',
    kind: ChatWallpaperKind.topo,
    light: [Color(0xFFEEF3EC), Color(0xFFC9D8C4)],
    dark: [Color(0xFF0E1A12), Color(0xFF1A2C21)],
  ),
  ChatWallpaperPreset(
    id: 'stars',
    kind: ChatWallpaperKind.stars,
    light: [
      Color(0xFFECE9FB),
      Color(0xFFF7ECF5),
      Color(0xFFCFC6EE),
      Color(0xFFE8D2E8),
    ],
    dark: [
      Color(0xFF070B1E),
      Color(0xFF140A24),
      Color(0xFF222A50),
      Color(0xFF30234C),
    ],
  ),
  ChatWallpaperPreset(
    id: 'confetti',
    kind: ChatWallpaperKind.confetti,
    light: [
      Color(0xFFFAF7F2),
      Color(0xFFF6F4FA),
      Color(0xFFF9D9C9),
      Color(0xFFCDE7DA),
      Color(0xFFD5DDF6),
    ],
    dark: [
      Color(0xFF12121A),
      Color(0xFF14121C),
      Color(0xFF3A1E1A),
      Color(0xFF15332A),
      Color(0xFF1E2647),
    ],
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
      case ChatWallpaperKind.mesh:
        _paintMesh(canvas, rect);
      case ChatWallpaperKind.bokeh:
        _paintGradient(canvas, rect);
        _paintBokeh(canvas, size);
      case ChatWallpaperKind.waves:
      case ChatWallpaperKind.dunes:
        _paintLayers(canvas, size, dunes: kind == ChatWallpaperKind.dunes);
      case ChatWallpaperKind.topo:
        _paintTopo(canvas, size);
      case ChatWallpaperKind.stars:
        _paintGradient(canvas, rect);
        _paintStars(canvas, size);
      case ChatWallpaperKind.confetti:
        _paintGradient(canvas, rect);
        _paintConfetti(canvas, size);
    }
  }

  /// The first two colours as a top-to-bottom gradient.
  void _paintGradient(Canvas canvas, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors[0], colors[1]],
        ).createShader(rect),
    );
  }

  /// Soft glows of colours 1..n over the base, placed relative to the size so
  /// a thumbnail looks like the full screen.
  void _paintMesh(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = colors[0]);
    const anchors = [Offset(0.15, 0.1), Offset(0.9, 0.45), Offset(0.3, 0.95)];
    final reach = rect.longestSide * 0.75;
    for (var index = 1; index < colors.length; index++) {
      final anchor = anchors[(index - 1) % anchors.length];
      final center = Offset(rect.width * anchor.dx, rect.height * anchor.dy);
      final glow = Rect.fromCircle(center: center, radius: reach);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [colors[index], colors[index].withValues(alpha: 0)],
          ).createShader(glow),
      );
    }
  }

  void _paintBokeh(Canvas canvas, Size size) {
    final random = math.Random(7);
    final unit = size.shortestSide;
    for (var index = 0; index < 18; index++) {
      final center = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final radius = unit * (0.06 + random.nextDouble() * 0.16);
      final color = colors[2 + index % 2];
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.9),
              color.withValues(alpha: 0.6),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.7, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  /// Colour 0 as the sky, then one band per further colour, each lower and
  /// darker than the last. Waves repeat quickly; dunes are long, lopsided
  /// hills.
  void _paintLayers(Canvas canvas, Size size, {required bool dunes}) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors[0]);
    final bands = colors.length - 1;
    for (var band = 0; band < bands; band++) {
      final top = size.height * (0.18 + 0.8 * band / bands);
      final amplitude = size.height * (dunes ? 0.07 : 0.025);
      final waves = dunes ? 1.2 + band * 0.3 : 2.5 + band * 0.5;
      final phase = band * 1.7;
      final path = Path()..moveTo(0, size.height);
      const steps = 48;
      for (var step = 0; step <= steps; step++) {
        final x = size.width * step / steps;
        final t = step / steps * math.pi * 2 * waves + phase;
        final wave = dunes
            ? math.sin(t) + 0.35 * math.sin(2 * t + 0.6)
            : math.sin(t);
        path.lineTo(x, top + wave * amplitude);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = colors[band + 1]);
    }
  }

  /// Contour lines around three peaks, like a hiking map.
  void _paintTopo(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors[0]);
    final ink = Paint()
      ..color = colors[1]
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    const peaks = [Offset(0.2, 0.25), Offset(0.85, 0.55), Offset(0.35, 0.9)];
    final unit = size.longestSide;
    for (var peak = 0; peak < peaks.length; peak++) {
      final center = Offset(
        size.width * peaks[peak].dx,
        size.height * peaks[peak].dy,
      );
      for (var ring = 1; ring <= 9; ring++) {
        final base = unit * 0.045 * ring;
        final path = Path();
        const steps = 64;
        for (var step = 0; step <= steps; step++) {
          final angle = step / steps * math.pi * 2;
          final radius =
              base *
              (1 +
                  0.12 * math.sin(3 * angle + peak + ring * 0.3) +
                  0.06 * math.cos(5 * angle + peak * 2));
          final point = center + Offset.fromDirection(angle, radius);
          step == 0
              ? path.moveTo(point.dx, point.dy)
              : path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path..close(), ink);
      }
    }
  }

  /// Small dots and a few four-pointed sparkles at a fixed density, with a
  /// floor of 28 so a preset tile still reads as a starfield.
  void _paintStars(Canvas canvas, Size size) {
    final random = math.Random(11);
    final count = (size.width * size.height / 2600).clamp(28, 900).round();
    for (var index = 0; index < count; index++) {
      final center = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final paint = Paint()..color = colors[2 + random.nextInt(2)];
      if (index % 9 == 0) {
        final arm = 3 + random.nextDouble() * 3;
        final waist = arm * 0.22;
        canvas.drawPath(
          Path()
            ..moveTo(center.dx, center.dy - arm)
            ..lineTo(center.dx + waist, center.dy - waist)
            ..lineTo(center.dx + arm, center.dy)
            ..lineTo(center.dx + waist, center.dy + waist)
            ..lineTo(center.dx, center.dy + arm)
            ..lineTo(center.dx - waist, center.dy + waist)
            ..lineTo(center.dx - arm, center.dy)
            ..lineTo(center.dx - waist, center.dy - waist)
            ..close(),
          paint,
        );
      } else {
        canvas.drawCircle(center, 0.7 + random.nextDouble() * 1.1, paint);
      }
    }
  }

  void _paintConfetti(Canvas canvas, Size size) {
    final random = math.Random(5);
    final count = (size.width * size.height / 5200).clamp(18, 500).round();
    final shapes = colors.length - 2;
    for (var index = 0; index < count; index++) {
      final paint = Paint()..color = colors[2 + index % shapes];
      canvas
        ..save()
        ..translate(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        )
        ..rotate(random.nextDouble() * math.pi);
      switch (index % 3) {
        case 0:
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(-5, -2, 10, 4),
              const Radius.circular(2),
            ),
            paint,
          );
        case 1:
          canvas.drawCircle(Offset.zero, 2.6, paint);
        default:
          canvas.drawPath(
            Path()
              ..moveTo(0, -3.5)
              ..lineTo(3.2, 2.5)
              ..lineTo(-3.2, 2.5)
              ..close(),
            paint,
          );
      }
      canvas.restore();
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
