import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/window_activity.dart';

/// Whether the app counts as "the window the user is in" decides whether any
/// notification arrives at all.
///
/// Talk withholds a notification from anyone it believes is present in the
/// room, and this client claims presence by holding a room session for the
/// conversation on screen. A desktop window keeps that conversation open
/// behind three other windows, so the server stayed silent — reported as an
/// open conversation that never notifies.
void main() {
  test('an unfocused window is not active, unlike for a sync loop', () {
    // The whole point: `inactive` is the desktop state for a visible but
    // unfocused window. A foreground sync loop wants to keep running there;
    // presence must not.
    expect(isWindowActive(AppLifecycleState.inactive), isFalse);
    expect(isWindowActive(AppLifecycleState.hidden), isFalse);
    expect(isWindowActive(AppLifecycleState.paused), isFalse);
    expect(isWindowActive(AppLifecycleState.detached), isFalse);
  });

  test('a focused window is active, and so is an unknown state', () {
    expect(isWindowActive(AppLifecycleState.resumed), isTrue);
    // Before the first lifecycle event there is nothing to go on, and
    // claiming presence is the recoverable direction: the session is torn
    // down on the first inactive event.
    expect(isWindowActive(null), isTrue);
  });

  testWidgets('the notifier reports every change to its listeners', (
    tester,
  ) async {
    final activity = WindowActivity(binding: tester.binding);
    addTearDown(activity.dispose);
    final seen = <bool>[];
    activity.addListener(() => seen.add(activity.value));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(seen, <bool>[false, true]);
    expect(activity.value, isTrue);
  });

  testWidgets('disposal stops the notifier observing the binding', (
    tester,
  ) async {
    final activity = WindowActivity(binding: tester.binding);
    final seen = <bool>[];
    activity.addListener(() => seen.add(activity.value));
    activity.dispose();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

    expect(
      seen,
      isEmpty,
      reason: 'a disposed notifier must not keep listening',
    );
  });
}
