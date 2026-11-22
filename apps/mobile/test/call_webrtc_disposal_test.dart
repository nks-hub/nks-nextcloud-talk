import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine_webrtc.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_signaling_session.dart';
import 'package:talk_protocol/talk_protocol.dart';

const _videoTrack = {
  'id': 'remote-video',
  'kind': 'video',
  'label': 'remote video',
  'enabled': true,
};
const _rtpParameters = {
  'transactionId': 'fixture-rtp',
  'encodings': [],
  'headerExtensions': [],
  'codecs': [],
  'degradationPreference': 'balanced',
  'rtcp': {'cname': 'fixture', 'reducedSize': true},
};
const _sender = {
  'senderId': 'fixture-sender',
  'track': <String, Object?>{},
  'rtpParameters': _rtpParameters,
  'ownsTrack': false,
};
const _receiver = {
  'receiverId': 'fixture-receiver',
  'track': _videoTrack,
  'rtpParameters': _rtpParameters,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel('FlutterWebRTC.Event');
  const textureEvents = MethodChannel('FlutterWebRTC/Texture23');
  const peerEvents = MethodChannel(
    'FlutterWebRTC/peerConnectionEventpeer-fixture',
  );
  const engine = WebRtcCallMediaEngine();
  final releases = <String>[];
  final failures = <String, PlatformException>{};
  Future<int> Function()? openRenderer;

  setUp(() {
    releases.clear();
    failures.clear();
    openRenderer = null;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(textureEvents, (_) async => null);
    messenger.setMockMethodCallHandler(peerEvents, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'initialize':
        case 'videoRendererSetSrcObject':
        case 'enableSpeakerphone':
          return null;
        case 'getSources':
          return {'sources': []};
        case 'getUserMedia':
          final constraints = (call.arguments as Map)['constraints'] as Map;
          final kind = constraints['audio'] == true ? 'audio' : 'video';
          final trackKey = kind == 'audio' ? 'audioTracks' : 'videoTracks';
          return {
            'streamId': 'local-fixture',
            trackKey: [
              for (final index in [1, 2])
                {
                  'id': '$kind-$index',
                  'kind': kind,
                  'label': '$kind track $index',
                  'enabled': true,
                },
            ],
          };
        case 'createVideoRenderer':
          final open = openRenderer;
          return {'textureId': open == null ? 23 : await open()};
        case 'createPeerConnection':
          return {'peerConnectionId': 'peer-fixture'};
        case 'createDataChannel':
          throw MissingPluginException();
        case 'addTrack':
          return _sender;
        case 'addTransceiver':
          if (failures['addTransceiver'] case final error?) throw error;
          return {
            'transceiverId': 'fixture-transceiver',
            'direction': 'recvonly',
            'sender': _sender,
            'receiver': _receiver,
          };
        case 'peerConnectionClose':
        case 'peerConnectionDispose':
        case 'videoRendererDispose':
        case 'trackDispose':
        case 'streamDispose':
          final key = call.method == 'trackDispose'
              ? (call.arguments as Map)['trackId'] as String
              : call.method;
          releases.add(key);
          if (failures[key] case final error?) throw error;
          return null;
        default:
          throw UnsupportedError(call.method);
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(textureEvents, null);
    messenger.setMockMethodCallHandler(peerEvents, null);
  });

  test('camera releases capture when its preview cannot open', () async {
    openRenderer = () async => throw PlatformException(
      code: 'preview_open',
      message: 'camera preview could not open',
    );
    failures['video-1'] = PlatformException(code: 'NotAllowedError');
    failures['streamDispose'] = PlatformException(code: 'stream_release');

    final failure = await engine.openCamera().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    expect(
      {'failure': failure, 'releases': releases},
      {
        'failure': isA<CallMediaException>().having(
          (error) => error.code,
          'code',
          CallMediaError.cameraUnavailable,
        ),
        'releases': ['video-1', 'video-2', 'streamDispose'],
      },
    );

    openRenderer = null;
    failures.clear();
    releases.clear();
    final retry = await engine.openCamera();
    expect(releases, isEmpty);
    await retry.dispose();
    expect(releases, [
      'videoRendererDispose',
      'video-1',
      'video-2',
      'streamDispose',
    ]);
  });

  test('camera stops its tracks after native renderer release fails', () async {
    final camera = await engine.openCamera();
    failures['videoRendererDispose'] = PlatformException(
      code: 'renderer_release',
      message: 'test renderer failure',
    );
    failures['streamDispose'] = PlatformException(code: 'stream_release');

    await expectLater(
      camera.dispose(),
      throwsA(contains('test renderer failure')),
    );
    await camera.dispose();

    expect(releases, [
      'videoRendererDispose',
      'video-1',
      'video-2',
      'streamDispose',
    ]);
  });

  test('microphone stops the second track after the first fails', () async {
    final microphone = await engine.openMicrophone();
    final routesClosed = microphone.routeChanges.drain<void>();
    failures['audio-1'] = PlatformException(code: 'first_track_release');

    await expectLater(
      microphone.dispose(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'first_track_release',
        ),
      ),
    );
    await routesClosed;
    await microphone.dispose();

    expect(releases, ['audio-1', 'audio-2', 'streamDispose']);
  });

  test('failed peer setup attempts disposal even when closing fails', () async {
    failures['addTransceiver'] = PlatformException(code: 'transceiver_setup');
    failures['peerConnectionClose'] = PlatformException(code: 'peer_close');
    failures['peerConnectionDispose'] = PlatformException(code: 'peer_dispose');

    final error = await engine
        .createPeerConnection(
          iceServers: const [],
          audio: null,
          onIceCandidate: (_) {},
          onConnectionState: (_) {},
          onRemoteVideo: (_) {},
        )
        .then<Object?>((_) => null, onError: (Object error) => error);

    expect(releases, ['peerConnectionClose', 'peerConnectionDispose']);
    expect(
      error,
      isA<CallMediaException>().having(
        (error) => error.code,
        'code',
        CallMediaError.engineFailure,
      ),
    );
  });

  for (final (name, failedMethod) in [
    (
      'closed call handles a late failure to create a video renderer',
      'createVideoRenderer',
    ),
    ('closed call releases a video renderer that opens late', null),
    (
      'closed call handles a late failure to release a video renderer',
      'videoRendererDispose',
    ),
  ]) {
    test(name, () async {
      final opening = Completer<void>();
      final allowRenderer = Completer<int>();
      openRenderer = () {
        opening.complete();
        return allowRenderer.future;
      };

      final updates = StreamController<CallSignalingUpdate>.broadcast();
      final media = CallMediaSession(
        initial: CallSignalingUpdate(
          key: const (accountId: 'account-a', roomToken: 'room-a'),
          outcome: SignalingRuntimeOutcome.unchanged,
          phase: SignalingAccountPhase.signalingReady,
          transport: SignalingTransportKind.externalHpb,
          topology: SignalingTopology.externalPeerToPeer,
          participants: [
            SignalingParticipant(
              peerId: SignalingPeerId.parse('zulu-session'),
              nextcloudSessionId: null,
              userId: 'remote-user',
              inCall: 7,
              permissions: 255,
              actorType: 'users',
              actorId: 'remote-user',
              federated: false,
              features: const [],
            ),
          ],
          roomConfirmed: true,
          federationInterrupted: false,
          renegotiationRequired: false,
          messages: const [],
          controls: const [],
          chatRelay: null,
          roomEpoch: 1,
          chatRelaySupported: false,
          localPeerId: SignalingPeerId.parse('alice-session'),
          iceServers: const [],
          failure: null,
        ),
        updates: updates.stream,
        sendMessage: (_, {required expectedRoomEpoch}) async => true,
        engine: engine,
      );
      addTearDown(updates.close);
      addTearDown(media.dispose);
      addTearDown(() {
        if (!allowRenderer.isCompleted) allowRenderer.complete(23);
      });
      var videoPublished = false;
      final states = media.states.listen((state) {
        videoPublished =
            videoPublished ||
            state.participants.any((peer) => peer.video != null);
      });
      addTearDown(states.cancel);
      await media.start();
      expect(media.state.peers, 1);

      await messenger.handlePlatformMessage(
        peerEvents.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'onTrack',
          'track': _videoTrack,
          'receiver': _receiver,
          'streams': [
            {
              'streamId': 'remote-stream',
              'ownerTag': 'peer-fixture',
              'audioTracks': [],
              'videoTracks': [_videoTrack],
            },
          ],
        }),
        null,
      );
      await opening.future.timeout(const Duration(seconds: 2));

      await media.dispose().timeout(const Duration(seconds: 2));
      expect(releases, isNot(contains('videoRendererDispose')));

      if (failedMethod == 'createVideoRenderer') {
        allowRenderer.completeError(
          PlatformException(code: 'late_renderer_open'),
        );
      } else {
        if (failedMethod == 'videoRendererDispose') {
          failures['videoRendererDispose'] = PlatformException(
            code: 'videoRendererDispose',
            message: 'render [23] not found !',
          );
        }
        allowRenderer.complete(23);
      }
      await pumpEventQueue();

      expect(media.state.phase, CallMediaPhase.idle);
      expect(videoPublished, isFalse);
      expect(releases.where((method) => method == 'peerConnectionDispose'), [
        'peerConnectionDispose',
      ]);
      expect(
        releases.where((method) => method == 'videoRendererDispose'),
        failedMethod == 'createVideoRenderer'
            ? isEmpty
            : ['videoRendererDispose'],
      );
    });
  }
}
