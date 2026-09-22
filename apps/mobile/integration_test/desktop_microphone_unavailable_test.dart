@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine_webrtc.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a host without audio input reports microphone unavailable', (
    tester,
  ) async {
    final devices = await rtc.Helper.enumerateDevices('audioinput');
    // This on-demand test requires an actual host without a capture device.
    expect(devices, isEmpty, reason: 'The host has an audio input device.');
    debugPrint('Native audio input device count: ${devices.length}');
    CallLocalAudio? audio;
    CallMediaException? failure;
    try {
      audio = await const WebRtcCallMediaEngine().openMicrophone();
    } on CallMediaException catch (error) {
      failure = error;
    } finally {
      await audio?.dispose();
    }
    expect(failure?.code, CallMediaError.microphoneUnavailable);
  });
}
