import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/calls/call_audio_interruptions.dart';

void main() {
  CallAudioInterruptions read(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    final container = ProviderContainer();
    addTearDown(() {
      container.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
    return container.read(callAudioInterruptionsProvider);
  }

  test('audio focus is read where a handler is registered', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      expect(
        read(platform),
        isA<PlatformCallAudioInterruptions>(),
        reason: '$platform reports audio focus and a call must hear it',
      );
    }
  });

  test('the desktop never subscribes to the audio focus channel', () {
    // Nothing registers the channel there, and a failed EventChannel `listen`
    // is reported through FlutterError rather than through the stream, so
    // subscribing cost two unhandled errors per call - seen on a real Windows
    // call before this choice existed.
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      expect(
        read(platform),
        isA<SilentCallAudioInterruptions>(),
        reason: '$platform has no handler for '
            '${PlatformCallAudioInterruptions.channelName}',
      );
    }
  });
}
