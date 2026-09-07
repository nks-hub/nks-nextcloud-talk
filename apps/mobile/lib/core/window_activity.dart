import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether the app is the window the user is actually working in.
///
/// This is not the same question as "is the app running", and the difference
/// decides whether notifications arrive at all. Nextcloud Talk suppresses a
/// notification for anyone it believes is present in the room, and this client
/// tells the server it is present by holding a Talk room session open for the
/// conversation on screen. On a phone that is fine: the room is only on screen
/// while the app is in front. On a desktop a window keeps its conversation
/// open behind three other windows, so the server went on believing the user
/// was reading it and stayed silent — the exact report of an open conversation
/// never notifying.
///
/// [AppLifecycleState.inactive] therefore has to count as *not* active here,
/// which is the opposite of what a foreground sync loop wants from it: an
/// unfocused desktop window should keep syncing but must stop claiming
/// presence.
bool isWindowActive(AppLifecycleState? state) =>
    state == null || state == AppLifecycleState.resumed;

/// Foreground user activity, expiring after two minutes without input.
final class WindowActivity extends ValueNotifier<bool>
    with WidgetsBindingObserver {
  WindowActivity({
    required WidgetsBinding binding,
    this.inactiveGrace = defaultInactiveGrace,
  }) : _binding = binding,
       super(isWindowActive(binding.lifecycleState)) {
    _binding.addObserver(this);
    _binding.pointerRouter.addGlobalRoute(_onPointer);
    _binding.keyboard.addHandler(_onKey);
    _binding.addSemanticsActionListener(_onSemanticsAction);
    if (value) _renewIdleDeadline();
  }

  /// How long a window may sit inactive before presence is released.
  ///
  /// A photo picker, a permission dialog or the notification shade makes the
  /// app inactive for about a second; releasing the room session at once
  /// and rebuilding it on resume cost a `DELETE`, a `POST`, a signaling
  /// round trip and a presence flap for every such tap. A window that stays
  /// inactive still loses presence, only two seconds later.
  static const defaultInactiveGrace = Duration(seconds: 2);
  static const idleTimeout = Duration(minutes: 2);

  final WidgetsBinding _binding;
  final Duration inactiveGrace;
  Timer? _release;
  Timer? _idle;

  void _renewIdleDeadline() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () {
      _idle = null;
      value = false;
    });
  }

  /// Also called by user-only text change callbacks for software keyboards.
  void recordInteraction() {
    if (!isWindowActive(_binding.lifecycleState)) return;
    _renewIdleDeadline();
    value = true;
  }

  void _onPointer(PointerEvent event) {
    if (event.synthesized) return;
    if (event is PointerDownEvent ||
        event is PointerMoveEvent ||
        event is PointerHoverEvent ||
        event is PointerScrollEvent ||
        event is PointerPanZoomStartEvent ||
        event is PointerPanZoomUpdateEvent) {
      recordInteraction();
    }
  }

  bool _onKey(KeyEvent event) {
    if (!event.synthesized &&
        (event is KeyDownEvent || event is KeyRepeatEvent)) {
      recordInteraction();
    }
    return false;
  }

  void _onSemanticsAction(ui.SemanticsActionEvent event) {
    // Accessibility focus can move after an incoming message, without input.
    if (event.type != ui.SemanticsAction.didGainAccessibilityFocus &&
        event.type != ui.SemanticsAction.didLoseAccessibilityFocus &&
        event.type != ui.SemanticsAction.showOnScreen) {
      recordInteraction();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (isWindowActive(state)) {
      _release?.cancel();
      _release = null;
      _renewIdleDeadline();
      value = true;
      return;
    }
    if (!value || _release != null) {
      return;
    }
    if (inactiveGrace == Duration.zero) {
      value = false;
      return;
    }
    _release = Timer(inactiveGrace, () {
      _release = null;
      if (!isWindowActive(_binding.lifecycleState)) {
        value = false;
      }
    });
  }

  @override
  void dispose() {
    _release?.cancel();
    _idle?.cancel();
    _binding.removeObserver(this);
    _binding.pointerRouter.removeGlobalRoute(_onPointer);
    _binding.keyboard.removeHandler(_onKey);
    _binding.removeSemanticsActionListener(_onSemanticsAction);
    super.dispose();
  }
}
