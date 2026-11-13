import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:talk_protocol/talk_protocol.dart' show ChatEmojiSizeReference;

import 'emoji_only_message.dart';

/// The conversation's quick emoji as a bare glyph button.
///
/// A tap sends it at the ordinary size. Press and hold grows a preview of the
/// emoji over [growDuration]; releasing sends it at the size step reached
/// (1 to [ChatEmojiSizeReference.maxStep]), dragging away from the button
/// cancels. The preview lives in the [Overlay], so no composer ancestor clips
/// it.
final class QuickEmojiHoldButton extends StatefulWidget {
  const QuickEmojiHoldButton({
    super.key,
    required this.emoji,
    required this.tooltip,
    required this.enabled,
    required this.onSend,
  });

  /// Time a hold needs, after the long-press delay, to reach the largest step.
  static const Duration growDuration = Duration(milliseconds: 1500);

  /// Drag distance from the press point that cancels the hold.
  static const double cancelDistance = 64;

  final String emoji;
  final String tooltip;
  final bool enabled;

  /// `sizeStep` is null for a plain tap.
  final void Function(String emoji, int? sizeStep) onSend;

  @override
  State<QuickEmojiHoldButton> createState() => _QuickEmojiHoldButtonState();
}

final class _QuickEmojiHoldButtonState extends State<QuickEmojiHoldButton>
    with SingleTickerProviderStateMixin {
  static const double _glyphSize = 30;
  static const int _maxStep = ChatEmojiSizeReference.maxStep;

  final LayerLink _link = LayerLink();
  final OverlayPortalController _preview = OverlayPortalController();
  late final AnimationController _grow;
  bool _holding = false;
  int _announcedStep = 1;

  int get _step => (_grow.value * _maxStep).ceil().clamp(1, _maxStep);

  @override
  void initState() {
    super.initState();
    _grow = AnimationController(
      vsync: this,
      duration: QuickEmojiHoldButton.growDuration,
    )..addListener(_onGrow);
  }

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  void _onGrow() {
    if (_holding && _step != _announcedStep) {
      _announcedStep = _step;
      _haptic(HapticFeedback.selectionClick);
    }
  }

  void _start(LongPressStartDetails details) {
    if (!widget.enabled) {
      return;
    }
    _holding = true;
    _announcedStep = 1;
    _haptic(HapticFeedback.selectionClick);
    _preview.show();
    _grow
      ..value = 0
      ..forward();
  }

  void _move(LongPressMoveUpdateDetails details) {
    if (_holding &&
        details.offsetFromOrigin.distance >
            QuickEmojiHoldButton.cancelDistance) {
      _stop();
      _haptic(HapticFeedback.lightImpact);
    }
  }

  void _end(LongPressEndDetails details) {
    if (!_holding) {
      return;
    }
    final step = _step;
    _stop();
    _haptic(HapticFeedback.lightImpact);
    widget.onSend(widget.emoji, step);
  }

  void _stop() {
    _holding = false;
    _grow.stop();
    _preview.hide();
  }

  // Not every platform has a haptic engine; a missing one is not an error.
  void _haptic(Future<void> Function() feedback) =>
      unawaited(feedback().catchError((Object _) {}));

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _preview,
      overlayChildBuilder: (context) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.bottomRight,
          child: IgnorePointer(
            child: Material(
              type: MaterialType.transparency,
              child: AnimatedBuilder(
                animation: _grow,
                builder: (context, _) => Text(
                  widget.emoji,
                  key: const Key('quick-emoji-hold-preview'),
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize:
                        _glyphSize +
                        (enlargedEmojiFontSizeForStep(_maxStep) - _glyphSize) *
                            _grow.value,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: GestureDetector(
          key: const Key('quick-emoji-hold-gesture'),
          excludeFromSemantics: true,
          onLongPressStart: _start,
          onLongPressMoveUpdate: _move,
          onLongPressEnd: _end,
          onLongPressCancel: () {
            if (_holding) {
              _stop();
            }
          },
          // The tooltip must not claim the long press itself, or the hold
          // never reaches this button; hovering still shows it.
          child: Tooltip(
            message: widget.tooltip,
            triggerMode: TooltipTriggerMode.manual,
            child: SizedBox.square(
              dimension: 48,
              child: IconButton(
                key: const Key('send-quick-emoji'),
                onPressed: widget.enabled
                    ? () => widget.onSend(widget.emoji, null)
                    : null,
                padding: EdgeInsets.zero,
                icon: ExcludeSemantics(
                  child: Opacity(
                    opacity: widget.enabled ? 1 : 0.38,
                    child: Text(
                      widget.emoji,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: _glyphSize, height: 1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
