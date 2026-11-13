import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';

final RegExp _hexPattern = RegExp(r'^#?([0-9A-Fa-f]{6})$');

/// `#RRGGBB` for [color], upper case.
String colorPickerHex(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// The colour [text] spells, with or without the leading `#`.
Color? colorPickerParse(String text) {
  final match = _hexPattern.firstMatch(text.trim());
  if (match == null) {
    return null;
  }
  return Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
}

/// A colour picker: a hue bar, a saturation and brightness field, a preview
/// and the hex field, all kept in step. Returns the confirmed text of the hex
/// field, which may be empty to clear the colour, or `null` when dismissed.
/// The hex field and the confirm button take [fieldKey] and [confirmKey], so
/// a test can drive it like a text prompt.
Future<String?> showColorPickerDialog({
  required BuildContext context,
  required String title,
  required String initialValue,
  required String fieldLabel,
  required String cancelLabel,
  required String confirmLabel,
  String? helperText,
  Key? dialogKey,
  Key? fieldKey,
  Key? confirmKey,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _ColorPickerDialog(
      key: dialogKey,
      title: title,
      initialValue: initialValue,
      fieldLabel: fieldLabel,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      helperText: helperText,
      fieldKey: fieldKey,
      confirmKey: confirmKey,
    ),
  );
}

final class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({
    super.key,
    required this.title,
    required this.initialValue,
    required this.fieldLabel,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.helperText,
    required this.fieldKey,
    required this.confirmKey,
  });

  final String title;
  final String initialValue;
  final String fieldLabel;
  final String cancelLabel;
  final String confirmLabel;
  final String? helperText;
  final Key? fieldKey;
  final Key? confirmKey;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

final class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  late HSVColor _hsv = HSVColor.fromColor(
    colorPickerParse(widget.initialValue) ?? const Color(0xFF00679E),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _pick(HSVColor hsv) {
    setState(() => _hsv = hsv);
    final hex = colorPickerHex(hsv.toColor());
    _controller.value = TextEditingValue(
      text: hex,
      selection: TextSelection.collapsed(offset: hex.length),
    );
  }

  void _typed(String text) {
    final color = colorPickerParse(text);
    if (color != null) {
      setState(() => _hsv = HSVColor.fromColor(color));
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final color = _hsv.toColor();
    final hex = colorPickerHex(color);
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 312,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: strings.colorPickerPreview(hex),
              excludeSemantics: true,
              child: Container(
                key: const Key('color-picker-preview'),
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Text(
                  hex,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: onColor),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _ShadeField(
              hsv: _hsv,
              label: strings.colorPickerShade,
              onChanged: _pick,
            ),
            const SizedBox(height: 16),
            _HueBar(hsv: _hsv, label: strings.colorPickerHue, onChanged: _pick),
            const SizedBox(height: 16),
            TextField(
              key: widget.fieldKey,
              controller: _controller,
              maxLength: 7,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[#0-9A-Fa-f]')),
              ],
              decoration: InputDecoration(
                labelText: widget.fieldLabel,
                helperText: widget.helperText,
                helperMaxLines: 3,
              ),
              onChanged: _typed,
              onSubmitted: (_) => Navigator.of(context).pop(_controller.text),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          key: widget.confirmKey,
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Saturation left to right, brightness bottom to top, for the current hue.
/// Screen readers adjust brightness with the increase and decrease actions;
/// the hex field covers everything else.
final class _ShadeField extends StatelessWidget {
  const _ShadeField({
    required this.hsv,
    required this.label,
    required this.onChanged,
  });

  final HSVColor hsv;
  final String label;
  final ValueChanged<HSVColor> onChanged;

  void _at(Offset position, Size size) {
    onChanged(
      hsv
          .withSaturation((position.dx / size.width).clamp(0.0, 1.0))
          .withValue(1 - (position.dy / size.height).clamp(0.0, 1.0)),
    );
  }

  @override
  Widget build(BuildContext context) {
    String describe(HSVColor color) =>
        '${(color.saturation * 100).round()} %, '
        '${(color.value * 100).round()} %';
    final brighter = hsv.withValue((hsv.value + 0.05).clamp(0.0, 1.0));
    final darker = hsv.withValue((hsv.value - 0.05).clamp(0.0, 1.0));
    return Semantics(
      label: label,
      value: describe(hsv),
      increasedValue: describe(brighter),
      decreasedValue: describe(darker),
      onIncrease: () => onChanged(brighter),
      onDecrease: () => onChanged(darker),
      // AlertDialog measures intrinsic sizes, which a LayoutBuilder refuses,
      // so the gesture reads the laid-out size instead.
      child: Builder(
        builder: (context) => GestureDetector(
          key: const Key('color-picker-shade'),
          onPanDown: (details) => _at(details.localPosition, context.size!),
          onPanUpdate: (details) => _at(details.localPosition, context.size!),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CustomPaint(
              size: const Size(double.infinity, 160),
              painter: _ShadePainter(hsv),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ShadePainter extends CustomPainter {
  const _ShadePainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hue = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas
      ..drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            colors: [Colors.white, hue],
          ).createShader(rect),
      )
      ..drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black],
          ).createShader(rect),
      );
    final knob = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    _drawKnob(canvas, knob, hsv.toColor());
  }

  @override
  bool shouldRepaint(_ShadePainter oldDelegate) => oldDelegate.hsv != hsv;
}

final class _HueBar extends StatelessWidget {
  const _HueBar({
    required this.hsv,
    required this.label,
    required this.onChanged,
  });

  final HSVColor hsv;
  final String label;
  final ValueChanged<HSVColor> onChanged;

  void _at(double dx, double width) =>
      onChanged(hsv.withHue((dx / width).clamp(0.0, 1.0) * 359.9));

  @override
  Widget build(BuildContext context) {
    // A grey has no hue to move; give it full saturation so the bar does
    // something visible.
    HSVColor lifted(HSVColor next) =>
        next.saturation == 0 && next.value > 0 ? next.withSaturation(1) : next;
    final up = lifted(hsv.withHue((hsv.hue + 10) % 360));
    final down = lifted(hsv.withHue((hsv.hue + 350) % 360));
    return Semantics(
      label: label,
      value: '${hsv.hue.round()}°',
      increasedValue: '${up.hue.round()}°',
      decreasedValue: '${down.hue.round()}°',
      onIncrease: () => onChanged(up),
      onDecrease: () => onChanged(down),
      child: Builder(
        builder: (context) => GestureDetector(
          key: const Key('color-picker-hue'),
          onPanDown: (details) =>
              _at(details.localPosition.dx, context.size!.width),
          onPanUpdate: (details) =>
              _at(details.localPosition.dx, context.size!.width),
          child: CustomPaint(
            size: const Size(double.infinity, 32),
            painter: _HuePainter(hsv.hue),
          ),
        ),
      ),
    );
  }
}

final class _HuePainter extends CustomPainter {
  const _HuePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final bar = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 6, size.width, size.height - 12),
      const Radius.circular(10),
    );
    canvas.drawRRect(
      bar,
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var step = 0; step <= 6; step++)
              HSVColor.fromAHSV(1, step * 60 % 360, 1, 1).toColor(),
          ],
        ).createShader(bar.outerRect),
    );
    _drawKnob(
      canvas,
      Offset(hue / 360 * size.width, size.height / 2),
      HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
    );
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) => oldDelegate.hue != hue;
}

void _drawKnob(Canvas canvas, Offset center, Color fill) {
  canvas
    ..drawCircle(center, 11, Paint()..color = Colors.black26)
    ..drawCircle(center, 10, Paint()..color = Colors.white)
    ..drawCircle(center, 7, Paint()..color = fill);
}
