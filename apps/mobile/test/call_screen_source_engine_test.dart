import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine_webrtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel('FlutterWebRTC.Event');
  const engine = WebRtcCallMediaEngine();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'initialize') return null;
          calls.add(call);
          if (call.method == 'getDesktopSources') {
            return {
              'sources': [
                {
                  'id': 'display-7',
                  'name': 'Display 7',
                  'type': 'screen',
                  'thumbnailSize': {'width': 160, 'height': 90},
                },
                {
                  'id': 'window-8',
                  'name': 'Document window',
                  'type': 'window',
                  'thumbnailSize': {'width': 160, 'height': 90},
                },
              ],
            };
          }
          if (call.method == 'getDisplayMedia') {
            throw PlatformException(code: 'capture_unavailable');
          }
          throw StateError('Unexpected native call: ${call.method}');
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, null);
  });

  test(
    'enumeration requests monitors and windows and preserves opaque ids',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final sources = await engine.screenSources();
      expect(sources.map((source) => source.id), ['display-7', 'window-8']);
      expect(sources.map((source) => source.isWindow), [false, true]);
      expect((calls.single.arguments as Map)['types'], ['screen', 'window']);
    },
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test('$platform refuses desktop capture without a selection', () async {
      debugDefaultTargetPlatformOverride = platform;
      await expectLater(
        engine.openScreen(),
        throwsA(isA<CallMediaException>()),
      );
      expect(calls, isEmpty);
    });

    test('$platform sends the selected source as deviceId.exact', () async {
      debugDefaultTargetPlatformOverride = platform;
      const source = CallScreenSource(
        id: 'window-8',
        name: 'Document window',
        isWindow: true,
      );
      await expectLater(
        engine.openScreen(source: source),
        throwsA(isA<CallMediaException>()),
      );
      final constraints = (calls.single.arguments as Map)['constraints'] as Map;
      expect((constraints['video'] as Map)['deviceId'], {'exact': source.id});
      expect(constraints['audio'], isFalse);
    });
  }

  test('iOS retains the BroadcastExtension capture request', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await expectLater(engine.openScreen(), throwsA(isA<CallMediaException>()));
    final constraints = (calls.single.arguments as Map)['constraints'] as Map;
    expect((constraints['video'] as Map)['deviceId'], 'broadcast');
  });

  test('Android retains system-selected display capture', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await expectLater(engine.openScreen(), throwsA(isA<CallMediaException>()));
    final constraints = (calls.single.arguments as Map)['constraints'] as Map;
    // The plugin adds cursor preferences on a desktop test host.
    expect(
      constraints['video'],
      anyOf(
        isTrue,
        isA<Map>().having(
          (video) => video.containsKey('deviceId'),
          'source',
          false,
        ),
      ),
    );
  });
}
