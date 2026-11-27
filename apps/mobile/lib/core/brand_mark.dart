import 'package:flutter/material.dart';

final class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'OwnTalk',
      image: true,
      child: ExcludeSemantics(
        child: CustomPaint(
          size: Size.square(size),
          painter: _ConversationMark(scheme.primary),
        ),
      ),
    );
  }
}

final class _ConversationMark extends CustomPainter {
  const _ConversationMark(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48, size.height / 48);
    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final back = Path()
      ..moveTo(30, 14)
      ..cubicTo(27, 8, 19, 6, 12, 9)
      ..cubicTo(3, 12, 1, 22, 8, 28)
      ..lineTo(7, 35)
      ..lineTo(14, 31)
      ..quadraticBezierTo(19, 33, 23, 31);
    final front = Path()
      ..moveTo(39, 33)
      ..lineTo(40, 38)
      ..lineTo(33, 35)
      ..cubicTo(15, 36, 16, 15, 31, 15)
      ..cubicTo(44, 14, 49, 27, 39, 33)
      ..close();
    canvas.drawPath(back, outline);
    canvas.drawPath(front, outline);
  }

  @override
  bool shouldRepaint(_ConversationMark oldDelegate) =>
      color != oldDelegate.color;
}
