import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/voice_message.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:nextcloudtalk/platform/media/voice_platform_adapters.dart';

void main() {
  late Directory root;
  late DurableAttachmentSourceStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nctalk-voice-adapter-test-');
    store = DurableAttachmentSourceStore(root: root, maximumSourceBytes: 64000);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('RecordMicrophonePermissionGateway', () {
    test(
      'maps the record backend permission result without guessing permanence',
      () async {
        final grantedBackend = _FakeVoiceCaptureBackend(permission: true);
        final deniedBackend = _FakeVoiceCaptureBackend(permission: false);

        expect(
          await RecordMicrophonePermissionGateway(grantedBackend).request(),
          MicrophonePermissionStatus.granted,
        );
        expect(
          await RecordMicrophonePermissionGateway(deniedBackend).request(),
          MicrophonePermissionStatus.denied,
        );
        expect(grantedBackend.permissionRequests, 1);
        expect(deniedBackend.permissionRequests, 1);
      },
    );
  });

  group('RecordVoiceRecorder', () {
    test(
      'commits a valid WAV as an app-owned source with exact duration',
      () async {
        final backend = _FakeVoiceCaptureBackend(wavBytes: _oneSecondWav());
        final recorder = RecordVoiceRecorder(backend: backend, store: store);
        addTearDown(recorder.close);

        await recorder.start();
        final recording = await recorder.stop();

        expect(recording.duration, const Duration(seconds: 1));
        expect(recording.source.mimeType, 'audio/wav');
        expect(recording.source.displayName, 'voice-message.wav');
        expect(
          (await store.observe(
            recording.source.handle,
          )).matches(recording.source),
          isTrue,
        );
        expect(await _stagingFiles(root), isEmpty);

        await recorder.discard(recording.source);
        await expectLater(
          store.observe(recording.source.handle),
          throwsA(isA<DurableAttachmentSourceException>()),
        );
      },
    );

    test(
      'never adopts a path that the active store session does not own',
      () async {
        final foreign = File(
          '${root.parent.path}${Platform.pathSeparator}foreign.wav',
        );
        await foreign.writeAsBytes(_oneSecondWav(), flush: true);
        addTearDown(() async {
          if (await foreign.exists()) {
            await foreign.delete();
          }
        });
        final backend = _FakeVoiceCaptureBackend(
          wavBytes: _oneSecondWav(),
          stopPathOverride: foreign.path,
        );
        final recorder = RecordVoiceRecorder(backend: backend, store: store);
        addTearDown(recorder.close);

        await recorder.start();
        await expectLater(
          recorder.stop(),
          throwsA(
            isA<VoicePlatformException>().having(
              (error) => error.code,
              'code',
              VoicePlatformError.foreignRecordingPath,
            ),
          ),
        );

        expect(await foreign.exists(), isTrue);
        expect(await _stagingFiles(root), isEmpty);
      },
    );

    test(
      'cancel and close release staging and the backend exactly once',
      () async {
        final backend = _FakeVoiceCaptureBackend(wavBytes: _oneSecondWav());
        final recorder = RecordVoiceRecorder(backend: backend, store: store);

        await recorder.start();
        await recorder.cancel();
        expect(await _stagingFiles(root), isEmpty);
        expect(backend.cancels, 1);

        await recorder.close();
        await recorder.close();
        expect(backend.disposes, 1);
      },
    );

    test('fails before recording when WAV is unsupported', () async {
      final backend = _FakeVoiceCaptureBackend(supportsWav: false);
      final recorder = RecordVoiceRecorder(backend: backend, store: store);
      addTearDown(recorder.close);

      await expectLater(
        recorder.start(),
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.wavUnsupported,
          ),
        ),
      );
      expect(backend.starts, 0);
      expect(await _stagingFiles(root), isEmpty);
    });
  });

  group('AudioplayersVoicePreviewPlayer', () {
    test(
      'resolves a verified handle and completes on native playback completion',
      () async {
        final source = await store.copyFromStream(
          stream: Stream<List<int>>.value(_oneSecondWav()),
          mimeType: 'audio/wav',
          displayName: 'preview.wav',
        );
        final backend = _FakeVoicePlaybackBackend();
        final player = AudioplayersVoicePreviewPlayer(
          backend: backend,
          store: store,
        );
        addTearDown(player.close);

        var completed = false;
        final playback = player.play(source).then((_) => completed = true);
        await backend.started.future;
        expect(completed, isFalse);
        expect(backend.lastPath, isNot(contains(source.handle.value)));

        backend.complete();
        await playback;
        expect(completed, isTrue);
      },
    );

    test('stop unblocks active playback and close disposes once', () async {
      final source = await store.copyFromStream(
        stream: Stream<List<int>>.value(_oneSecondWav()),
        mimeType: 'audio/wav',
        displayName: 'preview.wav',
      );
      final backend = _FakeVoicePlaybackBackend();
      final player = AudioplayersVoicePreviewPlayer(
        backend: backend,
        store: store,
      );

      final playback = player.play(source);
      await backend.started.future;
      await player.stop();
      await playback;
      expect(backend.stops, 1);
      expect((await store.observe(source.handle)).matches(source), isTrue);

      await player.close();
      await player.close();
      expect(backend.disposes, 1);
    });

    test(
      'propagates native start failures and clears active playback',
      () async {
        final source = await store.copyFromStream(
          stream: Stream<List<int>>.value(_oneSecondWav()),
          mimeType: 'audio/wav',
          displayName: 'preview.wav',
        );
        final backend = _FakeVoicePlaybackBackend(
          playFailure: StateError('Synthetic playback start failure.'),
        );
        final player = AudioplayersVoicePreviewPlayer(
          backend: backend,
          store: store,
        );
        addTearDown(player.close);

        await expectLater(player.play(source), throwsStateError);
        await player.stop();

        expect(backend.stops, 0);
        expect((await store.observe(source.handle)).matches(source), isTrue);
      },
    );
  });
}

final class _FakeVoiceCaptureBackend implements VoiceCaptureBackend {
  _FakeVoiceCaptureBackend({
    this.permission = true,
    this.supportsWav = true,
    this.wavBytes,
    this.stopPathOverride,
  });

  final bool permission;
  final bool supportsWav;
  final List<int>? wavBytes;
  final String? stopPathOverride;
  String? _path;
  int permissionRequests = 0;
  int starts = 0;
  int cancels = 0;
  int disposes = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<bool> supportsWaveEncoding() async => supportsWav;

  @override
  Future<void> startWave({
    required String path,
    required int sampleRate,
    required int channels,
  }) async {
    starts++;
    _path = path;
    final bytes = wavBytes;
    if (bytes != null) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
  }

  @override
  Future<String?> stop() async => stopPathOverride ?? _path;

  @override
  Future<void> cancel() async {
    cancels++;
    final path = _path;
    if (path != null && await File(path).exists()) {
      await File(path).delete();
    }
  }

  @override
  Future<void> dispose() async {
    disposes++;
  }
}

final class _FakeVoicePlaybackBackend implements VoicePlaybackBackend {
  _FakeVoicePlaybackBackend({this.playFailure});

  final StreamController<void> _completed = StreamController<void>.broadcast();
  final Completer<void> started = Completer<void>();
  final Object? playFailure;
  String? lastPath;
  int stops = 0;
  int disposes = 0;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Future<void> playFile(String path) async {
    lastPath = path;
    if (!started.isCompleted) {
      started.complete();
    }
    final failure = playFailure;
    if (failure != null) {
      throw failure;
    }
  }

  void complete() => _completed.add(null);

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposes++;
    await _completed.close();
  }
}

Uint8List _oneSecondWav() {
  const sampleRate = 8000;
  const channels = 1;
  const bitsPerSample = 16;
  const dataLength = sampleRate * channels * (bitsPerSample ~/ 8);
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);

  _ascii(bytes, 0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  _ascii(bytes, 8, 'WAVE');
  _ascii(bytes, 12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  _ascii(bytes, 36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  return bytes;
}

void _ascii(Uint8List bytes, int offset, String value) {
  for (var index = 0; index < value.length; index++) {
    bytes[offset + index] = value.codeUnitAt(index);
  }
}

Future<List<File>> _stagingFiles(Directory root) async {
  final staging = Directory('${root.path}${Platform.pathSeparator}staging');
  if (!await staging.exists()) {
    return <File>[];
  }
  return staging
      .list(recursive: true, followLinks: false)
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
}
