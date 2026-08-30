import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/voice_message.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:nextcloudtalk/platform/media/voice_platform_adapters.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

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

  group('RecordPluginVoiceCaptureBackend', () {
    test(
      'a retired start swaps recorder before its native call returns',
      () async {
        final originalPlatform = RecordPlatform.instance;
        final firstStartGate = Completer<void>();
        final platform = _ControlledRecordPlatform(
          firstStartGate,
          failFirstCancel: true,
        );
        RecordPlatform.instance = platform;
        addTearDown(() => RecordPlatform.instance = originalPlatform);
        final backend = RecordPluginVoiceCaptureBackend();
        addTearDown(backend.dispose);

        final firstStart = backend.start(
          path: 'first.m4a',
          sampleRate: 48000,
          channels: 1,
          bitRate: 64000,
        );
        await _waitUntil(() => platform.startedRecorderIds.length == 1);
        final retirement = backend.retirePendingStart(pendingStart: firstStart);

        await backend.start(
          path: 'second.m4a',
          sampleRate: 48000,
          channels: 1,
          bitRate: 64000,
        );
        final retiredId = platform.startedRecorderIds.first;
        final currentId = platform.startedRecorderIds.last;
        expect(currentId, isNot(retiredId));

        firstStartGate.complete();
        await retirement;

        expect(platform.cancelledRecorderIds, <String>[retiredId, retiredId]);
        expect(platform.disposedRecorderIds, <String>[retiredId]);
        expect(platform.disposedRecorderIds, isNot(contains(currentId)));
      },
    );
  });

  group('RecordVoiceRecorder', () {
    test('a paused stretch is left out of the recorded duration', () async {
      final backend = _FakeVoiceCaptureBackend(
        recordingBytes: _fakeRecordingBytes(),
      );
      final clock = _FakeVoiceRecordingClock(DateTime(2026, 1, 1));
      final recorder = RecordVoiceRecorder(
        backend: backend,
        store: store,
        clock: clock,
      );
      addTearDown(recorder.close);

      await recorder.start();
      clock.advance(const Duration(seconds: 2));
      await recorder.pause();
      clock.advance(const Duration(seconds: 30));
      await recorder.resume();
      clock.advance(const Duration(seconds: 3));
      final recording = await recorder.stop();

      expect(recording.duration, const Duration(seconds: 5));
      expect(backend.pauses, 1);
      expect(backend.resumes, 1);

      await recorder.discard(recording.source);
    });

    test('stopping straight from a pause keeps the captured stretch', () async {
      final backend = _FakeVoiceCaptureBackend(
        recordingBytes: _fakeRecordingBytes(),
      );
      final clock = _FakeVoiceRecordingClock(DateTime(2026, 1, 1));
      final recorder = RecordVoiceRecorder(
        backend: backend,
        store: store,
        clock: clock,
      );
      addTearDown(recorder.close);

      await recorder.start();
      clock.advance(const Duration(seconds: 7));
      await recorder.pause();
      clock.advance(const Duration(minutes: 5));
      final recording = await recorder.stop();

      expect(recording.duration, const Duration(seconds: 7));

      await recorder.discard(recording.source);
    });

    test('pause and resume are refused outside a live session', () async {
      final backend = _FakeVoiceCaptureBackend(
        recordingBytes: _fakeRecordingBytes(),
      );
      final recorder = RecordVoiceRecorder(backend: backend, store: store);
      addTearDown(recorder.close);

      await expectLater(
        recorder.pause(),
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.noActiveRecording,
          ),
        ),
      );
      await recorder.start();
      await expectLater(
        recorder.resume(),
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.noActiveRecording,
          ),
        ),
      );
      expect(backend.resumes, 0);
      await recorder.cancel();
    });

    test('maps the platform dBFS range onto drawable bar heights', () {
      expect(normalizedVoiceAmplitude(0), 1);
      expect(normalizedVoiceAmplitude(-25), closeTo(0.5, 0.001));
      expect(normalizedVoiceAmplitude(-160), 0);
      expect(normalizedVoiceAmplitude(double.nan), 0);
    });

    test('commits a compressed recording as an app-owned source with elapsed '
        'duration and the configured bit rate', () async {
      final backend = _FakeVoiceCaptureBackend(
        recordingBytes: _fakeRecordingBytes(),
      );
      final clock = _FakeVoiceRecordingClock(DateTime(2026, 1, 1));
      final recorder = RecordVoiceRecorder(
        backend: backend,
        store: store,
        clock: clock,
      );
      addTearDown(recorder.close);

      await recorder.start();
      clock.advance(const Duration(seconds: 4, milliseconds: 250));
      final recording = await recorder.stop();

      expect(recording.duration, const Duration(seconds: 4, milliseconds: 250));
      expect(recording.source.mimeType, voiceRecordingMimeType);
      expect(recording.source.displayName, 'voice-message.m4a');
      expect(backend.lastBitRate, 64000);
      expect(backend.lastSampleRate, 48000);
      expect(backend.lastChannels, 1);
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
    });

    test(
      'rejects a recording whose stop time did not advance past its start',
      () async {
        final backend = _FakeVoiceCaptureBackend(
          recordingBytes: _fakeRecordingBytes(),
        );
        final clock = _FakeVoiceRecordingClock(DateTime(2026, 1, 1));
        final recorder = RecordVoiceRecorder(
          backend: backend,
          store: store,
          clock: clock,
        );
        addTearDown(recorder.close);

        await recorder.start();
        await expectLater(
          recorder.stop(),
          throwsA(
            isA<VoicePlatformException>().having(
              (error) => error.code,
              'code',
              VoicePlatformError.invalidRecording,
            ),
          ),
        );
        expect(await _stagingFiles(root), isEmpty);
      },
    );

    test(
      'never adopts a path that the active store session does not own',
      () async {
        final foreign = File(
          '${root.parent.path}${Platform.pathSeparator}foreign.m4a',
        );
        await foreign.writeAsBytes(_fakeRecordingBytes(), flush: true);
        addTearDown(() async {
          if (await foreign.exists()) {
            await foreign.delete();
          }
        });
        final backend = _FakeVoiceCaptureBackend(
          recordingBytes: _fakeRecordingBytes(),
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
        final backend = _FakeVoiceCaptureBackend(
          recordingBytes: _fakeRecordingBytes(),
        );
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

    test('fails before recording when the encoder is unsupported', () async {
      final backend = _FakeVoiceCaptureBackend(supportsEncoding: false);
      final recorder = RecordVoiceRecorder(backend: backend, store: store);
      addTearDown(recorder.close);

      await expectLater(
        recorder.start(),
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.encodingUnsupported,
          ),
        ),
      );
      expect(backend.starts, 0);
      expect(await _stagingFiles(root), isEmpty);
    });

    test('a late native start is retired without breaking a retry', () async {
      final startGate = Completer<void>();
      final backend = _FakeVoiceCaptureBackend(
        recordingBytes: _fakeRecordingBytes(),
        startCompleters: <Completer<void>>[startGate],
      );
      final clock = _FakeVoiceRecordingClock(DateTime(2026, 1, 1));
      final recorder = RecordVoiceRecorder(
        backend: backend,
        store: store,
        clock: clock,
        startTimeout: const Duration(seconds: 2),
      );
      addTearDown(recorder.close);

      final start = recorder.start();
      await expectLater(
        start,
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.startTimedOut,
          ),
        ),
      );
      await recorder.start();
      clock.advance(const Duration(seconds: 1));
      startGate.complete();
      await backend.retiredCleanup;
      await _waitUntilAsync(
        () async => (await _stagingFiles(root)).length == 1,
      );
      final recording = await recorder.stop();

      expect(backend.retiredStarts, 1);
      expect(backend.retiredCancels, 2);
      expect(backend.retiredDisposes, 1);
      expect(recording.duration, const Duration(seconds: 1));
      expect(await _stagingFiles(root), isEmpty);
      await recorder.discard(recording.source);
    });

    test('cancel during native start leaves a retry isolated', () async {
      final startGate = Completer<void>();
      final backend = _FakeVoiceCaptureBackend(
        recordingBytes: _fakeRecordingBytes(),
        startCompleters: <Completer<void>>[startGate],
      );
      final clock = _FakeVoiceRecordingClock(DateTime(2026, 1, 1));
      final recorder = RecordVoiceRecorder(
        backend: backend,
        store: store,
        clock: clock,
        startTimeout: const Duration(seconds: 1),
      );
      addTearDown(recorder.close);

      final firstStart = recorder.start();
      await _waitUntil(() => backend.starts == 1);
      await recorder.cancel();
      await recorder.start();
      clock.advance(const Duration(seconds: 1));

      startGate.complete();
      await expectLater(
        firstStart,
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.startCancelled,
          ),
        ),
      );
      await backend.retiredCleanup;
      await _waitUntilAsync(
        () async => (await _stagingFiles(root)).length == 1,
      );
      final recording = await recorder.stop();

      expect(recording.duration, const Duration(seconds: 1));
      expect(await _stagingFiles(root), isEmpty);
      await recorder.discard(recording.source);
    });

    test('close during native start cannot reopen the recorder', () async {
      final startGate = Completer<void>();
      final backend = _FakeVoiceCaptureBackend(
        startCompleters: <Completer<void>>[startGate],
      );
      final recorder = RecordVoiceRecorder(
        backend: backend,
        store: store,
        startTimeout: const Duration(seconds: 1),
      );

      final start = recorder.start();
      await _waitUntil(() => backend.starts == 1);
      await recorder.close();
      startGate.complete();

      await expectLater(
        start,
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.closed,
          ),
        ),
      );
      await expectLater(
        recorder.start(),
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.closed,
          ),
        ),
      );
    });

    test('late staging cleanup does not wait for native retirement', () async {
      final startGate = Completer<void>();
      final retirementGate = Completer<void>();
      final backend = _FakeVoiceCaptureBackend(
        recordingBytes: _fakeRecordingBytes(),
        startCompleters: <Completer<void>>[startGate],
        retirementGate: retirementGate,
      );
      final clock = _FakeVoiceRecordingClock(DateTime(2026, 1, 1));
      final recorder = RecordVoiceRecorder(
        backend: backend,
        store: store,
        clock: clock,
        startTimeout: const Duration(seconds: 2),
      );
      addTearDown(recorder.close);

      await expectLater(
        recorder.start(),
        throwsA(
          isA<VoicePlatformException>().having(
            (error) => error.code,
            'code',
            VoicePlatformError.startTimedOut,
          ),
        ),
      );
      await recorder.start();
      clock.advance(const Duration(seconds: 1));
      startGate.complete();
      await _waitUntilAsync(
        () async => (await _stagingFiles(root)).length == 1,
      );

      final recording = await recorder.stop();
      await recorder.discard(recording.source);
      retirementGate.complete();
      await backend.retiredCleanup;
    });
  });

  group('AudioplayersVoicePreviewPlayer', () {
    test('resolves a verified handle, forwards the real MIME type, and '
        'completes on native playback completion', () async {
      final source = await store.copyFromStream(
        stream: Stream<List<int>>.value(_fakeRecordingBytes()),
        mimeType: 'audio/mp4',
        displayName: 'preview.m4a',
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
      expect(backend.lastMimeType, 'audio/mp4');

      backend.complete();
      await playback;
      expect(completed, isTrue);
    });

    test('stop unblocks active playback and close disposes once', () async {
      final source = await store.copyFromStream(
        stream: Stream<List<int>>.value(_fakeRecordingBytes()),
        mimeType: 'audio/mp4',
        displayName: 'preview.m4a',
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
          stream: Stream<List<int>>.value(_fakeRecordingBytes()),
          mimeType: 'audio/mp4',
          displayName: 'preview.m4a',
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
    bool supportsEncoding = true,
    this.recordingBytes,
    this.stopPathOverride,
    this.startCompleters = const <Completer<void>>[],
    this.retirementGate,
    // ignore: prefer_initializing_formals
  }) : _supportsEncoding = supportsEncoding;

  final bool permission;
  final bool _supportsEncoding;
  final List<int>? recordingBytes;
  final String? stopPathOverride;
  final List<Completer<void>> startCompleters;
  final Completer<void>? retirementGate;
  final StreamController<double> _amplitude =
      StreamController<double>.broadcast();
  String? _path;
  int permissionRequests = 0;
  int starts = 0;
  int pauses = 0;
  int resumes = 0;
  int cancels = 0;
  int disposes = 0;
  int retiredStarts = 0;
  int retiredCancels = 0;
  int retiredDisposes = 0;
  Future<void> retiredCleanup = Future<void>.value();

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Stream<double> get amplitude => _amplitude.stream;
  int? lastBitRate;
  int? lastSampleRate;
  int? lastChannels;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<bool> supportsEncoding() async => _supportsEncoding;

  @override
  Future<void> start({
    required String path,
    required int sampleRate,
    required int channels,
    required int bitRate,
  }) {
    starts++;
    _path = path;
    lastBitRate = bitRate;
    lastSampleRate = sampleRate;
    lastChannels = channels;
    final pendingStart = _completeStart(path, starts - 1);
    return pendingStart;
  }

  Future<void> _completeStart(String path, int gateIndex) async {
    final bytes = recordingBytes;
    if (bytes != null) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    if (gateIndex < startCompleters.length) {
      await startCompleters[gateIndex].future;
    }
  }

  @override
  Future<void> retirePendingStart({required Future<void> pendingStart}) {
    retiredStarts++;
    retiredCleanup = () async {
      retiredCancels++;
      try {
        await pendingStart;
      } on Object {
        // This fake mirrors retirement after either late success or failure.
      }
      retiredCancels++;
      await retirementGate?.future;
      retiredDisposes++;
    }();
    return retiredCleanup;
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

final class _FakeVoiceRecordingClock implements VoiceRecordingClock {
  _FakeVoiceRecordingClock(this._value);

  DateTime _value;

  @override
  DateTime now() => _value;

  void advance(Duration by) {
    _value = _value.add(by);
  }
}

final class _FakeVoicePlaybackBackend implements VoicePlaybackBackend {
  _FakeVoicePlaybackBackend({this.playFailure});

  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _duration =
      StreamController<Duration>.broadcast();
  final Completer<void> started = Completer<void>();
  final Object? playFailure;
  String? lastPath;
  String? lastMimeType;
  final List<Duration> seeks = <Duration>[];
  int stops = 0;
  int disposes = 0;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<Duration> get positionChanged => _position.stream;

  @override
  Stream<Duration> get durationChanged => _duration.stream;

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> playFile(String path, {required String mimeType}) async {
    lastPath = path;
    lastMimeType = mimeType;
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
    await _position.close();
    await _duration.close();
  }
}

Uint8List _fakeRecordingBytes() =>
    Uint8List.fromList(List<int>.generate(64, (index) => index));

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

final class _ControlledRecordPlatform extends RecordPlatform {
  _ControlledRecordPlatform(
    this.firstStartGate, {
    this.failFirstCancel = false,
  });

  final Completer<void> firstStartGate;
  final bool failFirstCancel;
  final List<String> startedRecorderIds = <String>[];
  final List<String> cancelledRecorderIds = <String>[];
  final List<String> disposedRecorderIds = <String>[];

  @override
  Future<void> create(String recorderId) async {}

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    startedRecorderIds.add(recorderId);
    if (startedRecorderIds.length == 1) {
      await firstStartGate.future;
    }
  }

  @override
  Future<void> cancel(String recorderId) async {
    cancelledRecorderIds.add(recorderId);
    if (failFirstCancel && cancelledRecorderIds.length == 1) {
      throw StateError('Synthetic first cancel failure.');
    }
  }

  @override
  Future<void> dispose(String recorderId) async {
    disposedRecorderIds.add(recorderId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition did not become true.');
}

Future<void> _waitUntilAsync(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (await condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Async condition did not become true.');
}
