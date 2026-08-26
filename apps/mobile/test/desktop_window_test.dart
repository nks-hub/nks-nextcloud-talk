import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The desktop runners are native code that no widget test can exercise, so the
/// one thing worth guarding is that the three platforms keep declaring the same
/// minimum window size and that the size stays compatible with the adaptive
/// layout the Flutter side implements.
void main() {
  const expectedWidth = 600;
  const expectedHeight = 400;

  int readConstant(String path, String pattern) {
    final source = File(path).readAsStringSync();
    final match = RegExp(pattern).firstMatch(source);
    expect(match, isNotNull, reason: 'no $pattern in $path');
    return int.parse(match!.group(1)!);
  }

  test('windows runner declares the shared minimum window size', () {
    const path = 'windows/runner/window_state.h';
    expect(
      readConstant(path, r'kMinimumWindowWidth\s*=\s*(\d+)'),
      expectedWidth,
    );
    expect(
      readConstant(path, r'kMinimumWindowHeight\s*=\s*(\d+)'),
      expectedHeight,
    );
  });

  test('macos runner declares the shared minimum window size', () {
    const path = 'macos/Runner/MainFlutterWindow.swift';
    expect(
      readConstant(path, r'minimumWindowWidth:\s*CGFloat\s*=\s*(\d+)'),
      expectedWidth,
    );
    expect(
      readConstant(path, r'minimumWindowHeight:\s*CGFloat\s*=\s*(\d+)'),
      expectedHeight,
    );
  });

  test('linux runner declares the shared minimum window size', () {
    const path = 'linux/runner/my_application.cc';
    expect(
      readConstant(path, r'kMinimumWindowWidth\s*=\s*(\d+)'),
      expectedWidth,
    );
    expect(
      readConstant(path, r'kMinimumWindowHeight\s*=\s*(\d+)'),
      expectedHeight,
    );
  });

  test('the minimum window fits inside a supported adaptive layout', () {
    final breakpoint = readConstant(
      'lib/features/conversations/conversation_workspace.dart',
      r'constraints\.maxWidth\s*<\s*(\d+)',
    );
    // Narrower than the breakpoint is fine — that is the compact single-pane
    // layout. Wider would mean the window can never reach the expanded layout.
    expect(expectedWidth, lessThanOrEqualTo(breakpoint));
  });

  test('windows runner wires save and restore of the window bounds', () {
    final runner = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();
    expect(runner, contains('RestoreWindowBounds('));
    expect(runner, contains('SaveWindowBounds('));
    expect(runner, contains('WM_EXITSIZEMOVE'));

    final state = File('windows/runner/window_state.cpp').readAsStringSync();
    // Bounds from a display that is gone must never be restored.
    expect(state, contains('MONITOR_DEFAULTTONULL'));
  });
}
