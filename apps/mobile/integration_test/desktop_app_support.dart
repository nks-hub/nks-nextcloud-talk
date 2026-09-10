@TestOn('windows')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the desktop integration tests share: waiting on the real clock,
/// minimizing the real window and writing down what happened when.
///
/// These tests drive the shipped app against the machine's own account and a
/// real server, so nothing here is a fake. The one thing that has to be said
/// out loud is the frames: Windows stops delivering them to a minimized
/// window, and `pump` waits for one, so anything that happens while the window
/// is down has to be waited for WITHOUT pumping.

/// A file the test writes its phases into, so a run can be lined up against
/// what a server or a log recorded at the same second.
final class DesktopJournal {
  DesktopJournal(String? path)
    : _file = File(path ?? 'desktop-journal.txt') {
    _file.writeAsStringSync('');
  }

  final File _file;

  void note(String line) {
    final stamp = DateTime.now().toIso8601String();
    _file.writeAsStringSync('$stamp $line\n', mode: FileMode.append);
    debugPrint('DESKTOP-JOURNAL $stamp $line');
  }
}

/// Pumps real frames for [duration].
Future<void> settle(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

/// Lets real time pass WITHOUT asking for a frame — the only way to wait while
/// the window is minimized.
Future<void> holdWithoutFrames(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  }
}

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) => waitUntil(
  tester,
  () => finder.evaluate().isNotEmpty,
  what: what,
  timeout: timeout,
);

Future<void> waitUntilGone(
  WidgetTester tester,
  Finder finder, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) => waitUntil(
  tester,
  () => finder.evaluate().isEmpty,
  what: '$what to go away',
  timeout: timeout,
);

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  fail('Timed out waiting for $what');
}

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindow = _user32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');

final int Function(int, int) _showWindow = _user32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'ShowWindow',
    );

final int Function(int) _isIconic = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');

final int Function(int) _setForegroundWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetForegroundWindow',
    );

int _window() {
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    final handle = _findWindow(className, nullptr);
    if (handle == 0) {
      fail('the test window was not found');
    }
    return handle;
  } finally {
    malloc.free(className);
  }
}

/// Asks Windows to minimize or restore the window — the same thing the title
/// bar's own button and the taskbar send. A restore also asks for the
/// foreground, because that is what clicking the taskbar does and the app
/// treats an inactive window differently from a hidden one.
void showWindow({required bool minimize}) {
  const swMinimize = 6;
  const swRestore = 9;
  final handle = _window();
  _showWindow(handle, minimize ? swMinimize : swRestore);
  if (!minimize) {
    _setForegroundWindow(handle);
  }
}

bool isIconic() => _isIconic(_window()) != 0;
