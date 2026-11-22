import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine_webrtc.dart';

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

  setUp(() {
    releases.clear();
    failures.clear();
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(textureEvents, (_) async => null);
    messenger.setMockMethodCallHandler(peerEvents, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'initialize':
        case 'videoRendererSetSrcObject':
          return null;
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
          return {'textureId': 23};
        case 'createPeerConnection':
          return {'peerConnectionId': 'peer-fixture'};
        case 'addTransceiver':
          throw PlatformException(code: 'transceiver_setup');
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
}
