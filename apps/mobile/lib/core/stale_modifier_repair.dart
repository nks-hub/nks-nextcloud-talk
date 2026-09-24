import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

/// Drops modifiers Flutter believes are held while Windows says they are up.
///
/// Flutter keeps its own record of pressed keys and only corrects it from the
/// events the embedder sends. When a release is lost — the window loses focus
/// mid-press, or a release arrives under a different physical key than its
/// press — the record keeps a Shift, Ctrl or Alt that nobody holds, and keeps
/// it until the app restarts (flutter/flutter#106475, #107377). A stale Shift
/// was exactly the reported state: Enter only broke the line, Ctrl+V was read
/// as Ctrl+Shift+V and did nothing, pressing Shift again did not help, and a
/// restart did. Windows' own view of the keyboard is the authority, so a
/// modifier it reports as up is released here with a synthesized key-up.
///
/// Only a modifier pressed at least [grace] ago is judged. Windows answers for
/// the moment it is asked, not for the moment of the key being handled, so in
/// a quick Ctrl+V the Ctrl can already be up by the time the V is looked at —
/// releasing it then broke the very paste this is here to save. The grace is
/// a heuristic: a Ctrl held longer than it and released during a stalled
/// frame can still be dropped a moment early. And only the framework's record
/// is repaired; should the embedder's own record be stuck as well, its next
/// press of that modifier arrives as a repeat and is not counted as held.
final class StaleModifierRepair {
  StaleModifierRepair({
    this.keyboard,
    this.isDown,
    DateTime Function()? now,
    this.grace = const Duration(milliseconds: 500),
  }) : _now = now ?? DateTime.now;

  /// The keyboard record to repair; [HardwareKeyboard.instance] when null.
  final HardwareKeyboard? keyboard;

  /// Whether the OS reports a virtual key as down; Windows when null.
  final bool Function(int virtualKey)? isDown;
  final DateTime Function() _now;
  final Duration grace;
  final Map<PhysicalKeyboardKey, DateTime> _pressedAt = {};
  bool _attached = false;

  HardwareKeyboard get _target => keyboard ?? HardwareKeyboard.instance;

  /// Only Windows is asked; an instance given its own answer is a test.
  bool get _active => isDown != null || Platform.isWindows;

  /// Starts noting when each key went down. Call once at startup, before the
  /// first key, so a modifier pressed for a shortcut is never taken for old.
  void attach() {
    if (_attached || !_active) {
      return;
    }
    _attached = true;
    _target.addHandler(_note);
  }

  bool _note(KeyEvent event) {
    if (event is KeyDownEvent) {
      _pressedAt[event.physicalKey] = _now();
    } else if (event is KeyUpEvent) {
      _pressedAt.remove(event.physicalKey);
    }
    return false;
  }

  /// Releases stale modifiers. Call it with a key press in hand and before
  /// the press is judged, but not from inside [HardwareKeyboard]'s own
  /// handler dispatch: the release is itself dispatched.
  void repair() {
    if (!_active) {
      return;
    }
    final down = isDown ?? _windowsKeyDown;
    final now = _now();
    final stale = <PhysicalKeyboardKey, LogicalKeyboardKey>{};
    for (final physical in _target.physicalKeysPressed) {
      final logical = _target.lookUpLayout(physical);
      final virtualKey = logical == null ? null : _virtualKeys[logical];
      if (virtualKey == null || down(virtualKey)) {
        continue;
      }
      final since = _pressedAt[physical];
      if (since != null && now.difference(since) < grace) {
        continue;
      }
      stale[physical] = logical!;
    }
    for (final MapEntry(key: physical, value: logical) in stale.entries) {
      _target.handleKeyEvent(
        KeyUpEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: Duration(microseconds: now.microsecondsSinceEpoch),
          synthesized: true,
        ),
      );
    }
  }
}

/// The app's one repair, attached in `main`.
final StaleModifierRepair staleModifierRepair = StaleModifierRepair();

final Map<LogicalKeyboardKey, int> _virtualKeys = {
  LogicalKeyboardKey.shiftLeft: 0xA0,
  LogicalKeyboardKey.shiftRight: 0xA1,
  LogicalKeyboardKey.controlLeft: 0xA2,
  LogicalKeyboardKey.controlRight: 0xA3,
  LogicalKeyboardKey.altLeft: 0xA4,
  LogicalKeyboardKey.altRight: 0xA5,
  LogicalKeyboardKey.metaLeft: 0x5B,
  LogicalKeyboardKey.metaRight: 0x5C,
};

final int Function(int) _getAsyncKeyState = DynamicLibrary.open(
  'user32.dll',
).lookupFunction<Int16 Function(Int32), int Function(int)>('GetAsyncKeyState');

bool _windowsKeyDown(int virtualKey) =>
    _getAsyncKeyState(virtualKey) & 0x8000 != 0;
