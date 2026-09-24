import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/stale_modifier_repair.dart';

void main() {
  KeyDownEvent press(PhysicalKeyboardKey physical, LogicalKeyboardKey logical) =>
      KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: Duration.zero,
      );

  late HardwareKeyboard keyboard;
  late DateTime now;
  late bool osDown;
  late StaleModifierRepair repair;

  setUp(() {
    keyboard = HardwareKeyboard();
    now = DateTime.utc(2026, 9, 24, 12);
    osDown = false;
    repair = StaleModifierRepair(
      keyboard: keyboard,
      isDown: (_) => osDown,
      now: () => now,
    )..attach();
  });

  test('an old Shift Windows reports as up is released', () {
    keyboard.handleKeyEvent(
      press(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft),
    );
    now = now.add(const Duration(seconds: 5));

    repair.repair();

    expect(keyboard.isShiftPressed, isFalse);
    expect(keyboard.physicalKeysPressed, isEmpty);
  });

  test('a Ctrl pressed a moment ago is kept even if Windows already let go', () {
    // A quick Ctrl+V: by the time V is looked at, Windows may report the Ctrl
    // as released. Releasing it here would turn the paste into a plain V.
    keyboard.handleKeyEvent(
      press(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft),
    );
    now = now.add(const Duration(milliseconds: 20));

    repair.repair();

    expect(keyboard.isControlPressed, isTrue);
  });

  test('a modifier that is really held stays pressed', () {
    osDown = true;
    keyboard.handleKeyEvent(
      press(PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft),
    );
    now = now.add(const Duration(minutes: 1));

    repair.repair();

    expect(keyboard.isAltPressed, isTrue);
  });

  test('ordinary keys are not second-guessed', () {
    keyboard.handleKeyEvent(
      press(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA),
    );
    now = now.add(const Duration(minutes: 1));

    repair.repair();

    expect(keyboard.logicalKeysPressed, {LogicalKeyboardKey.keyA});
  });
}
