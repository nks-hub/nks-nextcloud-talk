import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/window_activity.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/chat/chat_room_signaling.dart';

/// Whether the app counts as "the window the user is in" decides whether any
/// notification arrives at all.
///
/// Talk withholds a notification from anyone it believes is present in the
/// room, and this client claims presence by holding a room session for the
/// conversation on screen. A desktop window keeps that conversation open
/// behind three other windows, so the server stayed silent — reported as an
/// open conversation that never notifies.
void main() {
  testWidgets('idle expiry releases chat presence but retains a joined call', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final activity = WindowActivity(binding: tester.binding);
    final container = ProviderContainer(
      overrides: [windowActivityProvider.overrideWithValue(activity)],
    );
    const chat = (accountId: 'account-a', roomToken: 'rooma123');
    const call = (accountId: 'account-a', roomToken: 'roomb123');
    container
        .read(chatRoomVisibilityProvider.notifier)
        .setVisible(Object(), chat);
    container.listen(chatRoomSessionWantedProvider(chat), (_, _) {});
    container.listen(chatRoomSessionWantedProvider(call), (_, _) {});
    container.read(callHeldRoomsProvider.notifier).state = {call};
    expect(container.read(chatRoomSessionWantedProvider(chat)), isTrue);
    await tester.pump(const Duration(minutes: 2));
    expect(container.read(chatRoomSessionWantedProvider(chat)), isFalse);
    expect(container.read(chatRoomSessionWantedProvider(call)), isTrue);
    container.read(callHeldRoomsProvider.notifier).state = {};
    expect(container.read(chatRoomSessionWantedProvider(call)), isFalse);
    tester.binding.pointerRouter.route(const PointerDownEvent());
    expect(container.read(chatRoomSessionWantedProvider(chat)), isTrue);
    container.dispose();
    activity.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('accessibility input restores presence but focus events do not', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final activity = WindowActivity(binding: tester.binding);
    await tester.pump(const Duration(minutes: 2));
    final dispatch = tester.binding.platformDispatcher.onSemanticsActionEvent!;
    dispatch(
      ui.SemanticsActionEvent(
        type: ui.SemanticsAction.didGainAccessibilityFocus,
        viewId: tester.view.viewId,
        nodeId: 0,
      ),
    );
    expect(activity.value, isFalse);
    dispatch(
      ui.SemanticsActionEvent(
        type: ui.SemanticsAction.tap,
        viewId: tester.view.viewId,
        nodeId: 0,
      ),
    );
    expect(activity.value, isTrue);
    activity.dispose();
  });

  testWidgets('synthetic pointer movement cannot restore idle presence', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final activity = WindowActivity(binding: tester.binding);
    await tester.pump(const Duration(minutes: 2));
    tester.binding.pointerRouter.route(
      const PointerHoverEvent(synthesized: true),
    );
    expect(activity.value, isFalse);
    tester.binding.pointerRouter.route(const PointerHoverEvent());
    expect(activity.value, isTrue);
    activity.dispose();
  });

  testWidgets('a focused window releases presence after two idle minutes', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final activity = WindowActivity(binding: tester.binding);

    await tester.pump(const Duration(seconds: 119));
    expect(activity.value, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(activity.value, isFalse);
    await tester.pump(const Duration(minutes: 5));
    expect(activity.value, isFalse, reason: 'frames do not represent input');
    activity.dispose();
  });

  testWidgets('pointer input renews and restores idle presence', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final activity = WindowActivity(binding: tester.binding);

    await tester.pump(const Duration(seconds: 110));
    tester.binding.pointerRouter.route(const PointerDownEvent());
    await tester.pump(const Duration(seconds: 110));
    expect(activity.value, isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(activity.value, isFalse);
    tester.binding.pointerRouter.route(
      const PointerScrollEvent(scrollDelta: Offset(0, 12)),
    );
    expect(activity.value, isTrue);
    activity.dispose();
  });

  testWidgets('keyboard input restores presence without consuming the key', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final activity = WindowActivity(binding: tester.binding);
    await tester.pump(const Duration(minutes: 2));
    expect(activity.value, isFalse);
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(activity.value, isTrue);
    expect(handled, isFalse);
    activity.dispose();
  });

  testWidgets('input outside a foreground window cannot renew presence', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final activity = WindowActivity(binding: tester.binding);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 3));
    tester.binding.pointerRouter.route(const PointerDownEvent());
    expect(activity.value, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(activity.value, isTrue);
    await tester.pump(const Duration(minutes: 2));
    expect(activity.value, isFalse);
    activity.dispose();
  });

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
    final activity = WindowActivity(
      binding: tester.binding,
      inactiveGrace: Duration.zero,
    );
    final seen = <bool>[];
    activity.addListener(() => seen.add(activity.value));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(seen, <bool>[false, true]);
    expect(activity.value, isTrue);
    activity.dispose();
  });

  testWidgets('a short inactive blip keeps presence, a long one releases it', (
    tester,
  ) async {
    // A picker or a permission dialog makes the app inactive for about a
    // second. Releasing the room session for that costs a DELETE, a POST and
    // a signaling round trip per tap, so the release waits a moment.
    final activity = WindowActivity(binding: tester.binding);
    final seen = <bool>[];
    activity.addListener(() => seen.add(activity.value));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 800));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(seen, isEmpty, reason: 'a blip never released presence');
    expect(activity.value, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 3));
    expect(seen, <bool>[false]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(seen, <bool>[false, true]);
    activity.dispose();
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
