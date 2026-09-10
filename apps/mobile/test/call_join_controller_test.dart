import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/chat/chat_room_signaling.dart';
import 'package:talk_protocol/talk_protocol.dart';

const _key = (accountId: 'account-a', roomToken: 'rooma123');

void main() {
  test('a focused window without a visible chat does not claim presence', () {
    final container = ProviderContainer(
      overrides: [windowActiveProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);
    expect(container.read(chatRoomSessionWantedProvider(_key)), isFalse);
  });

  test('a server without signalling admits no room signalling session', () {
    expect(chatRoomSignalingAllowed(_capabilities()), isTrue);
    expect(
      chatRoomSignalingAllowed(_capabilities(features: const [])),
      isFalse,
      reason: 'signaling-v3 is what carries the offer and the answer',
    );
    expect(
      chatRoomSignalingAllowed(
        _capabilities(context: CapabilityContext.anonymous),
      ),
      isFalse,
    );
  });

  test(
    'joining without a signalling session never opens the microphone',
    () async {
      final engine = _RecordingEngine();
      final container = ProviderContainer(
        overrides: [
          callMediaEngineProvider.overrideWithValue(engine),
          chatRoomSignalingProvider.overrideWith(
            (ref, key) async => const ChatRoomSignalingLease.unavailable(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(callJoinControllerProvider(_key).notifier).join();

      final state = container.read(callJoinControllerProvider(_key));
      expect(state.phase, CallJoinPhase.failed);
      expect(state.signalingUnavailable, isTrue);
      expect(engine.microphoneOpens, 0);
      // The failed join does not leave the room held.
      expect(container.read(callHeldRoomsProvider), isEmpty);
    },
  );

  test(
    'a joining call holds the room session until the join settles',
    () async {
      final lease = Completer<ChatRoomSignalingLease>();
      final container = ProviderContainer(
        overrides: [
          callMediaEngineProvider.overrideWithValue(_RecordingEngine()),
          chatRoomSignalingProvider.overrideWith((ref, key) => lease.future),
        ],
      );
      addTearDown(container.dispose);

      final join = container
          .read(callJoinControllerProvider(_key).notifier)
          .join();
      expect(container.read(callHeldRoomsProvider), {_key});
      lease.complete(const ChatRoomSignalingLease.unavailable());
      await join;
      expect(container.read(callHeldRoomsProvider), isEmpty);
    },
  );

  test(
    'a second join while one is running never opens a second call',
    () async {
      // The desktop case behind this: a window that comes back from being
      // minimised rebuilds the screen, and a rebuild that joined again would
      // put two sessions of the same account into one call.
      final engine = _RecordingEngine();
      final lease = Completer<ChatRoomSignalingLease>();
      final container = ProviderContainer(
        overrides: [
          callMediaEngineProvider.overrideWithValue(engine),
          chatRoomSignalingProvider.overrideWith((ref, key) => lease.future),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        callJoinControllerProvider(_key).notifier,
      );

      final first = controller.join();
      // While the first join is still waiting for its signalling lease.
      final second = controller.join();
      expect(container.read(callHeldRoomsProvider), {_key});
      lease.complete(const ChatRoomSignalingLease.unavailable());
      await first;
      await second;

      expect(engine.microphoneOpens, 0);
      expect(container.read(callHeldRoomsProvider), isEmpty);
    },
  );

  test('a call in one room refuses a lease to another room', () async {
    // The server keeps ONE active session per account and the coordinator's
    // lanes are keyed by account, so a second room asking for a session
    // released the call's own and shut its lane down: joining a call in room
    // A and then opening room B ended the call with "the signalling ended".
    final container = ProviderContainer(
      overrides: [windowActiveProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);
    container.read(callHeldRoomsProvider.notifier).state = {_key};
    const other = (accountId: 'account-a', roomToken: 'roomb456');
    container
        .read(chatRoomVisibilityProvider.notifier)
        .setVisible('chat', other);

    expect(
      container.read(chatRoomSessionWantedProvider(other)),
      isTrue,
      reason: 'the visible chat does want one; the call is what outranks it',
    );
    final lease = await container.read(chatRoomSignalingProvider(other).future);
    expect(lease.session, isNull);
    // The call's own room is unaffected.
    expect(container.read(chatRoomSessionWantedProvider(_key)), isTrue);
  });

  test('hanging up while the join is in flight still leaves', () async {
    // The CallKit case: a VoIP push rings, the person answers, and hangs up
    // in the system call screen before the several round trips of the join
    // have finished. `leave()` refused to do anything while the state was
    // busy, so the join finished into a live call with an open microphone
    // and no system UI left to end it.
    final engine = _RecordingEngine();
    final lease = Completer<ChatRoomSignalingLease>();
    final container = ProviderContainer(
      overrides: [
        callMediaEngineProvider.overrideWithValue(engine),
        chatRoomSignalingProvider.overrideWith((ref, key) => lease.future),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      callJoinControllerProvider(_key).notifier,
    );

    final joining = controller.join();
    expect(container.read(callJoinControllerProvider(_key)).isBusy, isTrue);
    // The hang-up arrives here, while nothing can be torn down yet.
    await controller.leave();
    lease.complete(const ChatRoomSignalingLease.unavailable());
    await joining;

    expect(container.read(callHeldRoomsProvider), isEmpty);
    expect(engine.microphoneOpens, 0);
  });

  test(
    'a room held by a call wants its session while the window is inactive',
    () {
      final container = ProviderContainer(
        overrides: [windowActiveProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);

      expect(container.read(chatRoomSessionWantedProvider(_key)), isFalse);
      container.read(callHeldRoomsProvider.notifier).state = {_key};
      expect(container.read(chatRoomSessionWantedProvider(_key)), isTrue);
      expect(
        container.read(
          chatRoomSessionWantedProvider((accountId: 'a', roomToken: 'other')),
        ),
        isFalse,
      );
    },
  );
}

CapabilitySnapshot _capabilities({
  List<String> features = const ['signaling-v3'],
  CapabilityContext context = CapabilityContext.authenticated,
}) => CapabilitySnapshot.fromJson(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'version': <String, Object?>{
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': <String, Object?>{
        'spreed': <String, Object?>{
          'features': <Object?>[...features],
          'config': <String, Object?>{},
          'version': '24.0.2',
        },
      },
    },
  },
}, context: context);

final class _RecordingEngine implements CallMediaEngine {
  int microphoneOpens = 0;

  @override
  Future<CallLocalAudio> openMicrophone() async {
    microphoneOpens++;
    throw const CallMediaException(CallMediaError.microphoneUnavailable);
  }

  @override
  Future<CallLocalVideo> openCamera() async {
    throw const CallMediaException(CallMediaError.cameraUnavailable);
  }

  @override
  Future<bool> requestScreenConsent() async => true;

  @override
  Future<List<CallScreenSource>> screenSources() async => const [];

  @override
  Future<CallLocalVideo> openScreen({CallScreenSource? source}) async {
    throw const CallMediaException(CallMediaError.screenShareUnavailable);
  }

  @override
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio? audio,
    CallLocalVideo? video,
    bool sendOnly = false,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
    required void Function(CallRemoteVideo? video) onRemoteVideo,
    void Function(String type, Object? payload)? onStatusMessage,
  }) async {
    throw const CallMediaException(CallMediaError.engineFailure);
  }
}
