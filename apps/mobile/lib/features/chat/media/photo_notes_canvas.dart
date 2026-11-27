part of 'photo_notes.dart';

class _PhotoCanvas extends StatefulWidget {
  const _PhotoCanvas({
    required this.image,
    required this.pins,
    required this.selected,
    required this.draft,
    required this.placing,
    required this.focusNode,
    required this.transform,
    required this.onPick,
    required this.onSelect,
  });
  final ui.Image image;
  final List<_Pin> pins;
  final String? selected;
  final Offset? draft;
  final bool placing;
  final FocusNode focusNode;
  final TransformationController transform;
  final ValueChanged<Offset> onPick;
  final ValueChanged<String> onSelect;
  @override
  State<_PhotoCanvas> createState() => _PhotoCanvasState();
}

class _PhotoCanvasState extends State<_PhotoCanvas> {
  Offset _cursor = const Offset(.5, .5);
  bool _keyboard = false;
  @override
  void didUpdateWidget(_PhotoCanvas old) {
    super.didUpdateWidget(old);
    if (widget.placing && !old.placing) {
      _cursor = const Offset(.5, .5);
      _keyboard = false;
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!widget.placing || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      widget.onPick(_cursor);
      return KeyEventResult.handled;
    }
    final delta = {
      LogicalKeyboardKey.arrowLeft: const Offset(-.02, 0),
      LogicalKeyboardKey.arrowRight: const Offset(.02, 0),
      LogicalKeyboardKey.arrowUp: const Offset(0, -.02),
      LogicalKeyboardKey.arrowDown: const Offset(0, .02),
    }[key];
    if (delta == null) return KeyEventResult.ignored;
    setState(() {
      _keyboard = true;
      final moved = _cursor + delta;
      _cursor = Offset(moved.dx.clamp(0, 1), moved.dy.clamp(0, 1));
    });
    return KeyEventResult.handled;
  }

  void _zoom(double factor, Size viewport) {
    final current = widget.transform.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(1.0, 6.0);
    if (next == 1) {
      widget.transform.value = Matrix4.identity();
      return;
    }
    final scale = next / current;
    final center = viewport.center(Offset.zero);
    widget.transform.value =
        (Matrix4.identity()
          ..translateByDouble(center.dx, center.dy, 0, 1)
          ..scaleByDouble(scale, scale, 1, 1)
          ..translateByDouble(-center.dx, -center.dy, 0, 1)) *
        widget.transform.value;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final photo = ColoredBox(
      color: Colors.black,
      child: Focus(
        focusNode: widget.focusNode,
        onKeyEvent: _key,
        child: InteractiveViewer(
          transformationController: widget.transform,
          minScale: 1,
          maxScale: 6,
          child: LayoutBuilder(
            builder: (context, box) {
              final size = applyBoxFit(
                BoxFit.contain,
                Size(
                  widget.image.width.toDouble(),
                  widget.image.height.toDouble(),
                ),
                box.biggest,
              ).destination;
              if (size.isEmpty) return const SizedBox.shrink();
              Widget pin(
                Offset point,
                String label,
                VoidCallback? tap,
                bool selected,
              ) {
                final diameter = 40.0.clamp(0.0, size.shortestSide);
                return Positioned(
                  left: point.dx * size.width - diameter / 2,
                  top: point.dy * size.height - diameter / 2,
                  width: diameter,
                  height: diameter,
                  child: Semantics(
                    button: tap != null,
                    label: '${s.photoPin} $label',
                    child: Tooltip(
                      message: '${s.photoPin} $label',
                      child: IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: selected
                              ? Colors.amber.shade800
                              : Colors.indigo.shade700,
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white, width: 2),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: tap,
                        icon: Text(label),
                      ),
                    ),
                  ),
                );
              }

              return Center(
                child: SizedBox.fromSize(
                  size: size,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          key: const Key('photo-pin-surface'),
                          behavior: HitTestBehavior.opaque,
                          onTapUp: widget.placing
                              ? (tap) => widget.onPick(
                                  Offset(
                                    tap.localPosition.dx / size.width,
                                    tap.localPosition.dy / size.height,
                                  ),
                                )
                              : null,
                          child: RawImage(
                            image: widget.image,
                            fit: BoxFit.fill,
                          ),
                        ),
                      ),
                      if (!widget.placing)
                        for (var i = 0; i < widget.pins.length; i++)
                          pin(
                            widget.pins[i].point,
                            '${i + 1}',
                            () => widget.onSelect(widget.pins[i].entry.id),
                            widget.selected == widget.pins[i].entry.id,
                          ),
                      if (widget.draft case final point?)
                        pin(point, '+', null, true),
                      if (widget.placing && _keyboard)
                        pin(_cursor, '+', null, true),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) => Stack(
        fit: StackFit.expand,
        children: [
          photo,
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    color: Colors.white,
                    tooltip: s.zoomOut,
                    icon: const Icon(Icons.remove),
                    onPressed: () => _zoom(.8, bounds.biggest),
                  ),
                  IconButton(
                    color: Colors.white,
                    tooltip: s.resetZoom,
                    icon: const Icon(Icons.center_focus_strong),
                    onPressed: () =>
                        widget.transform.value = Matrix4.identity(),
                  ),
                  IconButton(
                    color: Colors.white,
                    tooltip: s.zoomIn,
                    icon: const Icon(Icons.add),
                    onPressed: () => _zoom(1.25, bounds.biggest),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
