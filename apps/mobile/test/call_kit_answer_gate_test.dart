import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_kit_channel.dart';
import 'package:nextcloudtalk/features/calls/call_lifecycle_service.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel(CallKitChannel.channelName);
  const key = (accountId: 'account-a', roomToken: 'rooma123');
  late CallKitChannel channel;
  late ProviderContainer container;
  late List<MethodCall> nativeCalls;
  late List<CallRoomKey> joinedRooms;
  late _AnswerController controller;

  setUp(() {
    nativeCalls = [];
    joinedRooms = [];
    controller = _AnswerController(joinedRooms);
    channel = CallKitChannel(channel: native);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
          nativeCalls.add(call);
          return null;
        });
    final binding = Provider<void>((ref) => bindCallKitActions(ref, channel));
    container = ProviderContainer(
      overrides: [callJoinControllerProvider.overrideWith(() => controller)],
    );
    container.read(binding);
  });

  tearDown(() {
    container.dispose();
    channel.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  Future<void> nativeAction(String method, String callId) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          CallKitChannel.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, {
              'accountId': key.accountId,
              'roomToken': key.roomToken,
              'callId': callId,
            }),
          ),
          (_) {},
        );
    await pumpEventQueue();
  }

  Future<void> answer(String callId) => nativeAction('callAnswered', callId);

  test('an unsupported answer releases exactly its native ring', () async {
    await answer('11111111-1111-1111-1111-111111111111');
    expect(joinedRooms, [key]);
    expect(nativeCalls.single.method, 'endCall');
    expect(nativeCalls.single.arguments, {
      'callId': '11111111-1111-1111-1111-111111111111',
    });
  });

  test('an accepted answer remains connected to the native ring', () async {
    controller.accept = true;
    await answer('11111111-1111-1111-1111-111111111111');
    expect(joinedRooms, [key]);
    expect(nativeCalls, isEmpty);
  });

  test(
    'ending an accepted native ring releases its controller ownership',
    () async {
      controller.accept = true;
      const id = '11111111-1111-1111-1111-111111111111';
      await answer(id);
      await container.pump();
      expect(controller.wasDisposed, isFalse);
      await nativeAction('callEnded', id);
      expect(controller.leaves, 1);
      await container.pump();
      expect(controller.wasDisposed, isTrue);
    },
  );

  test('an old native end cannot hang up a newer same-room ring', () async {
    controller.accept = true;
    await answer('11111111-1111-1111-1111-111111111111');
    await answer('22222222-2222-2222-2222-222222222222');
    await nativeAction('callEnded', '11111111-1111-1111-1111-111111111111');
    expect(controller.leaves, 0);
    expect(nativeCalls, isEmpty);
    expect(controller.wasDisposed, isFalse);
  });

  test('an unexpected join error still releases the native ring', () async {
    controller.joinError = StateError('join failed');
    await answer('11111111-1111-1111-1111-111111111111');
    expect(nativeCalls.single.method, 'endCall');
  });

  test(
    'same-room answers share the pending join and release its current ring on failure',
    () async {
      final first = Completer<bool>();
      controller.outcomes.add(first.future);
      await answer('11111111-1111-1111-1111-111111111111');
      await answer('22222222-2222-2222-2222-222222222222');
      expect(nativeCalls, isEmpty);
      first.complete(false);
      await pumpEventQueue();
      expect(joinedRooms, [key]);
      expect(nativeCalls.single.arguments, {
        'callId': '22222222-2222-2222-2222-222222222222',
      });
    },
  );

  test(
    'a pending native answer owns the controller without a call widget',
    () async {
      final pending = Completer<bool>();
      controller.outcomes.add(pending.future);
      await answer('11111111-1111-1111-1111-111111111111');
      await container.pump();
      expect(controller.wasDisposed, isFalse);
      pending.complete(false);
      await pumpEventQueue();
      expect(nativeCalls.single.method, 'endCall');
      await container.pump();
      expect(controller.wasDisposed, isTrue);
    },
  );

  test('disposing the binding ignores a late failed answer', () async {
    final pending = Completer<bool>();
    controller.outcomes.add(pending.future);
    await answer('11111111-1111-1111-1111-111111111111');
    container.dispose();
    pending.complete(false);
    await pumpEventQueue();
    expect(nativeCalls, isEmpty);
  });
}

final class _AnswerController extends CallJoinController {
  _AnswerController(this.joinedRooms);

  final List<CallRoomKey> joinedRooms;
  bool accept = false;
  Object? joinError;
  final outcomes = <Future<bool>>[];
  bool wasDisposed = false;
  int leaves = 0;

  @override
  CallJoinState build(CallRoomKey arg) {
    ref.onDispose(() => wasDisposed = true);
    return const CallJoinState();
  }

  @override
  Future<void> join() async {
    if (state.isBusy || state.phase == CallJoinPhase.joined) return;
    joinedRooms.add(arg);
    state = const CallJoinState(phase: CallJoinPhase.joining);
    if (joinError != null) throw joinError!;
    final accepted = outcomes.isEmpty ? accept : await outcomes.removeAt(0);
    if (wasDisposed) return;
    state = accepted
        ? const CallJoinState(phase: CallJoinPhase.joined)
        : const CallJoinState(
            phase: CallJoinPhase.failed,
            lifecycleError: CallLifecycleError.endToEndEncryptionUnsupported,
          );
  }

  @override
  Future<void> leave() async {
    leaves++;
    state = const CallJoinState();
  }
}
