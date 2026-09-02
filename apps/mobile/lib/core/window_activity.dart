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
  WindowActivity({required WidgetsBinding binding})
    : _binding = binding,
      super(isWindowActive(binding.lifecycleState)) {
    _binding.addObserver(this);
  }

  final WidgetsBinding _binding;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    value = isWindowActive(state);
  }

  @override
  void dispose() {
    _binding.removeObserver(this);
    super.dispose();
  }
}
