import 'dart:async';

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

/// Notifies whenever the window becomes active or inactive.
///
/// A [ValueNotifier] rather than a stream so a reader can ask for the current
/// value without waiting for the next change; presence has to be decided the
/// moment a conversation opens, not on the next focus event.
final class WindowActivity extends ValueNotifier<bool>
    with WidgetsBindingObserver {
  WindowActivity({
    required WidgetsBinding binding,
    this.inactiveGrace = defaultInactiveGrace,
  }) : _binding = binding,
       super(isWindowActive(binding.lifecycleState)) {
    _binding.addObserver(this);
  }

  /// How long a window may sit inactive before presence is released.
  ///
  /// A photo picker, a permission dialog or the notification shade makes the
  /// app inactive for about a second; releasing the room session at once
  /// and rebuilding it on resume cost a `DELETE`, a `POST`, a signaling
  /// round trip and a presence flap for every such tap. A window that stays
  /// inactive still loses presence, only two seconds later.
  static const defaultInactiveGrace = Duration(seconds: 2);

  final WidgetsBinding _binding;
  final Duration inactiveGrace;
  Timer? _release;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (isWindowActive(state)) {
      _release?.cancel();
      _release = null;
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
    _binding.removeObserver(this);
    super.dispose();
  }
}
