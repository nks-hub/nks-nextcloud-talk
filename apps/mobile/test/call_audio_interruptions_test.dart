import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/calls/call_audio_interruptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'calls and recordings share one native audio focus subscription',
    () async {
      const channel = MethodChannel(PlatformCallAudioInterruptions.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeCalls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      Future<void> emit(String event) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeSuccessEnvelope(event),
          (_) => done.complete(),
        );
        await done.future;
      }

      final source = PlatformCallAudioInterruptions();
      final callEvents = <CallAudioInterruption>[];
      final recordingEvents = <CallAudioInterruption>[];
      final call = source.events.listen(callEvents.add);
      final recording = source.events.listen(recordingEvents.add);
      addTearDown(call.cancel);
      addTearDown(recording.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(nativeCalls, ['listen']);

      await emit('began');
      expect(callEvents, [CallAudioInterruption.began]);
      expect(recordingEvents, [CallAudioInterruption.began]);
      await call.cancel();
      expect(nativeCalls, ['listen']);
      await emit('ended');
      expect(recordingEvents.last, CallAudioInterruption.ended);

      await recording.cancel();
      expect(nativeCalls, ['listen', 'cancel']);
      final nextCall = source.events.listen(callEvents.add);
      await Future<void>.delayed(Duration.zero);
      await emit('began');
      expect(callEvents.length, 2);
      await nextCall.cancel();
      expect(nativeCalls, ['listen', 'cancel', 'listen', 'cancel']);
    },
  );

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
        reason:
            '$platform has no handler for '
            '${PlatformCallAudioInterruptions.channelName}',
      );
    }
  });
}
