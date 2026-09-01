import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/platform/media/voice_transcription.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS sends the file, locale, and bounded timeout to native', () async {
    const channel = MethodChannel(
      'com.nkshub.nextcloudtalk/test_voice_transcription',
    );
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return 'spoken words';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final transcriber = MethodChannelVoiceTranscriber(
      channel: channel,
      supported: true,
    );

    final text = await transcriber.transcribe(
      filePath: '/app/audio/message.m4a',
      localeIdentifier: 'cs-CZ',
      timeout: const Duration(seconds: 45),
    );

    expect(text, 'spoken words');
    expect(calls.single.method, 'transcribe');
    expect(calls.single.arguments, <String, Object?>{
      'filePath': '/app/audio/message.m4a',
      'localeIdentifier': 'cs-CZ',
      'timeoutMillis': 45000,
    });
  });

  test('native error codes remain typed at the Dart boundary', () async {
    const channel = MethodChannel(
      'com.nkshub.nextcloudtalk/test_voice_transcription_errors',
    );
    var code = 'denied';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: code);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final transcriber = MethodChannelVoiceTranscriber(
      channel: channel,
      supported: true,
    );
    const expected = <String, VoiceTranscriptionFailure>{
      'denied': VoiceTranscriptionFailure.denied,
      'restricted': VoiceTranscriptionFailure.restricted,
      'unavailable': VoiceTranscriptionFailure.unavailable,
      'invalidFile': VoiceTranscriptionFailure.invalidFile,
      'failed': VoiceTranscriptionFailure.failed,
      'cancelled': VoiceTranscriptionFailure.cancelled,
    };

    for (final entry in expected.entries) {
      code = entry.key;
      await expectLater(
        transcriber.transcribe(filePath: '/app/audio/message.m4a'),
        throwsA(
          isA<VoiceTranscriptionException>().having(
            (error) => error.failure,
            'failure',
            entry.value,
          ),
        ),
      );
    }
  });

  test(
    'a newer request rejects a late result from the old generation',
    () async {
      const channel = MethodChannel(
        'com.nkshub.nextcloudtalk/test_voice_transcription_generation',
      );
      final firstNative = Completer<String>();
      final secondNative = Completer<String>();
      var requests = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            requests++;
            return requests == 1 ? firstNative.future : secondNative.future;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final transcriber = MethodChannelVoiceTranscriber(
        channel: channel,
        supported: true,
      );

      final first = transcriber.transcribe(filePath: '/app/audio/first.m4a');
      final second = transcriber.transcribe(filePath: '/app/audio/second.m4a');
      secondNative.complete('second result');
      expect(await second, 'second result');
      firstNative.complete('stale result');
      await expectLater(
        first,
        throwsA(
          isA<VoiceTranscriptionException>().having(
            (error) => error.failure,
            'failure',
            VoiceTranscriptionFailure.cancelled,
          ),
        ),
      );
    },
  );

  test('cancel and dispose retire the active generation', () async {
    const channel = MethodChannel(
      'com.nkshub.nextcloudtalk/test_voice_transcription_lifecycle',
    );
    final nativeResults = <Completer<String>>[];
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          if (call.method == 'transcribe') {
            final result = Completer<String>();
            nativeResults.add(result);
            return result.future;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final transcriber = MethodChannelVoiceTranscriber(
      channel: channel,
      supported: true,
    );

    final cancelled = transcriber.transcribe(filePath: '/app/audio/cancel.m4a');
    await Future<void>.delayed(Duration.zero);
    await transcriber.cancel();
    nativeResults[0].complete('late cancel result');
    await expectLater(cancelled, throwsA(isA<VoiceTranscriptionException>()));

    final disposed = transcriber.transcribe(filePath: '/app/audio/dispose.m4a');
    await Future<void>.delayed(Duration.zero);
    await transcriber.dispose();
    nativeResults[1].complete('late dispose result');
    await expectLater(disposed, throwsA(isA<VoiceTranscriptionException>()));
    expect(methods, ['transcribe', 'cancel', 'transcribe', 'dispose']);
    await expectLater(
      transcriber.transcribe(filePath: '/app/audio/after-dispose.m4a'),
      throwsA(
        isA<VoiceTranscriptionException>().having(
          (error) => error.failure,
          'failure',
          VoiceTranscriptionFailure.cancelled,
        ),
      ),
    );
  });

  test('unsupported hosts never invoke the iOS channel', () async {
    const channel = MethodChannel(
      'com.nkshub.nextcloudtalk/test_voice_transcription_unsupported',
    );
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invoked = true;
          return 'unexpected';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final transcriber = MethodChannelVoiceTranscriber(
      channel: channel,
      supported: false,
    );

    await expectLater(
      transcriber.transcribe(filePath: '/app/audio/message.m4a'),
      throwsA(
        isA<VoiceTranscriptionException>().having(
          (error) => error.failure,
          'failure',
          VoiceTranscriptionFailure.unsupported,
        ),
      ),
    );
    expect(invoked, isFalse);
  });

  test('empty and malformed native success values fail closed', () async {
    const channel = MethodChannel(
      'com.nkshub.nextcloudtalk/test_voice_transcription_response',
    );
    Object? response = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => response);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final transcriber = MethodChannelVoiceTranscriber(
      channel: channel,
      supported: true,
    );

    for (final value in <Object?>['', 42, null]) {
      response = value;
      await expectLater(
        transcriber.transcribe(filePath: '/app/audio/message.m4a'),
        throwsA(
          isA<VoiceTranscriptionException>().having(
            (error) => error.failure,
            'failure',
            VoiceTranscriptionFailure.failed,
          ),
        ),
      );
    }
  });

  test('iOS declares and localizes speech recognition permission', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final english = File(
      'ios/Runner/en.lproj/InfoPlist.strings',
    ).readAsStringSync();
    final czech = File(
      'ios/Runner/cs.lproj/InfoPlist.strings',
    ).readAsStringSync();

    expect(plist, contains('<key>NSSpeechRecognitionUsageDescription</key>'));
    expect(english, contains('"NSSpeechRecognitionUsageDescription"'));
    expect(czech, contains('"NSSpeechRecognitionUsageDescription"'));
  });
}
