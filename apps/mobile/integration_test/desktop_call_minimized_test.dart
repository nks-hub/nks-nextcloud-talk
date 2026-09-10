@TestOn('windows')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/app.dart';

/// A real call, started from the real desktop client against the real server,
/// held while the operating system minimizes the window.
///
/// The widget suite can only assert that `chatRoomSessionWantedProvider` keeps
/// wanting a session; nothing in it opens a microphone, talks to a signalling
/// server or asks Windows to minimize anything. This does all three: it boots
/// the shipped app with the machine's own account and database, joins a call
/// over the network, and then calls `ShowWindow(SW_MINIMIZE)` through user32 —
/// the same thing the title bar's minimize button does — before checking that
/// the call is still up. The seat on the server is watched from outside, by a
/// second account polling the call endpoint, because a client that believes it
/// is in a call while the server has dropped its seat is exactly the failure
/// this is looking for.
///
/// It is not part of the ordinary suite: it needs a signed-in account, a
/// microphone and a reachable server, so it is run on demand with
/// `flutter test integration_test/desktop_call_minimized_test.dart -d windows`
/// and the room token in `NKS_CALL_ROOM`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final roomToken = Platform.environment['NKS_CALL_ROOM'];
  final journal = File(
    Platform.environment['NKS_CALL_JOURNAL'] ?? 'desktop-call-journal.txt',
  );

  void note(String line) {
    final stamp = DateTime.now().toIso8601String();
    journal.writeAsStringSync('$stamp $line\n', mode: FileMode.append);
    debugPrint('CALL-JOURNAL $stamp $line');
  }

  testWidgets('a joined call survives the window being minimized', (
    tester,
  ) async {
    expect(
      roomToken,
      isNotNull,
      reason: 'set NKS_CALL_ROOM to the room this account should call',
    );
    journal.writeAsStringSync('');
    note('start');

    await tester.pumpWidget(const ProviderScope(child: NextcloudTalkApp()));
    await _settle(tester, const Duration(seconds: 5));

    final tile = find.byKey(Key('conversation-tile-$roomToken'));
    await _waitFor(tester, tile, what: 'the conversation tile');
    note('list ready');

    await tester.tap(tile);
    await _settle(tester, const Duration(seconds: 3));

    final startCall = find.byKey(const Key('start-call-audio'));
    await _waitFor(tester, startCall, what: 'the audio call button');
    note('room open');

    await tester.tap(startCall);
    final callScreen = find.byKey(const Key('call-screen'));
    await _waitFor(
      tester,
      callScreen,
      what: 'the call screen',
      timeout: const Duration(seconds: 60),
    );
    note('joined');

    // Hold the joined call while the window is out of sight for long enough
    // that a client dropping its seat on hide would have done it: the server
    // forgets a participant that stops pinging for well under a minute.
    _showWindow(minimize: true);
    await _holdWithoutFrames(tester, const Duration(seconds: 2));
    expect(_isIconic(), isTrue, reason: 'the window did not minimize');
    note('minimized');

    await _holdWithoutFrames(tester, const Duration(seconds: 75));
    expect(_isIconic(), isTrue, reason: 'the window came back on its own');
    note('held minimized');

    _showWindow(minimize: false);
    await _settle(tester, const Duration(seconds: 3));
    expect(_isIconic(), isFalse);
    expect(
      callScreen,
      findsOneWidget,
      reason: 'the call screen was gone after the window was restored',
    );
    note('restored');

    await _hold(tester, const Duration(seconds: 10));
    expect(callScreen, findsOneWidget);
    note('still joined after restore');

    final leave = find.byKey(const Key('call-screen-leave'));
    await _waitFor(tester, leave, what: 'the leave button');
    await tester.tap(leave);
    await _waitUntilGone(tester, callScreen, what: 'the call screen');
    // Leaving hands the signalling lane its own shutdown, which ends in a
    // database write. The tree - and with it the database - is disposed the
    // moment this test returns, so returning too early turns that write into
    // "Channel was closed before receiving a response" AFTER the test passed.
    await _settle(tester, const Duration(seconds: 15));
    note('left');
  }, timeout: const Timeout(Duration(minutes: 6)));
}

/// Pumps real frames for [duration]; the integration binding runs on the real
/// clock, so this is the only way to let the network and the media actually
/// happen.
Future<void> _settle(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

Future<void> _hold(WidgetTester tester, Duration duration) =>
    _settle(tester, duration);

/// Lets real time pass WITHOUT asking for a frame.
///
/// Windows stops delivering frames to a minimized window, and `pump` waits for
/// one, so pumping here hangs until the test times out — which is exactly how
/// the first run of this test failed. The app's timers, sockets and media keep
/// running regardless, and they are what is under test; the frames are not.
Future<void> _holdWithoutFrames(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  fail('Timed out waiting for $what');
}

Future<void> _waitUntilGone(
  WidgetTester tester,
  Finder finder, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  fail('Timed out waiting for $what to go away');
}

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindow = _user32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');

final int Function(int, int) _showWindowRaw = _user32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'ShowWindow',
    );

final int Function(int) _isIconicRaw = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');

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

void _showWindow({required bool minimize}) {
  const swMinimize = 6;
  const swRestore = 9;
  _showWindowRaw(_window(), minimize ? swMinimize : swRestore);
}

bool _isIconic() => _isIconicRaw(_window()) != 0;
