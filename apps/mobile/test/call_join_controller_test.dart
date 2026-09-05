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
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio audio,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
    required void Function(CallRemoteVideo? video) onRemoteVideo,
  }) async {
    throw const CallMediaException(CallMediaError.engineFailure);
  }
}
