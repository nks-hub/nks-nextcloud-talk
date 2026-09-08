import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_foreground_service.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidCallForegroundService.channelName);
  const service = AndroidCallForegroundService();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'camera foreground upgrade and downgrade retain the exact owner',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'started';
      });
      await service.setCameraEnabled('camera-owner', true);
      await service.setCameraEnabled('camera-owner', false);
      expect(calls.map((call) => call.method), [
        'setCameraEnabled',
        'setCameraEnabled',
      ]);
      expect(calls.map((call) => call.arguments), [
        {'owner': 'camera-owner', 'enabled': true},
        {'owner': 'camera-owner', 'enabled': false},
      ]);
    },
  );

  test('camera denial is distinct from microphone denial', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => 'permission-denied',
    );
    await expectLater(
      service.setCameraEnabled('camera-owner', true),
      throwsA(
        isA<CallMediaException>().having(
          (error) => error.code,
          'code',
          CallMediaError.cameraPermissionDenied,
        ),
      ),
    );
  });

  test(
    'foreground acknowledgement and cleanup use the same exact call owner',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'start' ? 'started' : null;
      });
      await service.start('call-attempt-a');
      await service.stop('call-attempt-a');
      expect(calls.map((c) => c.method), ['start', 'stop']);
      expect(calls.map((c) => c.arguments), [
        {'owner': 'call-attempt-a'},
        {'owner': 'call-attempt-a'},
      ]);
    },
  );

  for (final status in ['permission-denied', 'unavailable', null]) {
    test('native admission $status never claims foreground success', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => status);
      await expectLater(
        service.start('attempt'),
        throwsA(
          isA<CallMediaException>().having(
            (e) => e.code,
            'code',
            status == 'permission-denied'
                ? CallMediaError.microphonePermissionDenied
                : CallMediaError.engineFailure,
          ),
        ),
      );
    });
  }

  test(
    'a missing Android service fails closed but cleanup remains safe',
    () async {
      await expectLater(
        service.start('attempt'),
        throwsA(isA<CallMediaException>()),
      );
      await service.stop('attempt');
    },
  );
}
