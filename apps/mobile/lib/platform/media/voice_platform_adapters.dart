import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:nextcloudtalk/features/chat/composer/voice_message.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:record/record.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// Voice messages are recorded as AAC-LC in an MP4/M4A container instead of
/// raw PCM WAV.
///
/// `record` (pubspec ^7.1.1) implements [AudioEncoder.aacLc] natively on
/// Android through `MediaRecorder`, and `audioplayers` (pubspec ^6.8.1)
/// plays MP4/AAC out of the box on Android, so no extra native codec has to
/// be shipped on either side. At [_voiceBitRate] bit/s a five-second
/// recording drops from roughly 3.1 MB (16-bit PCM WAV) to well under
/// 100 KB, which keeps voice messages on the non-chunked upload path
/// instead of forcing chunked delivery for what is a short clip.
const AudioEncoder _voiceEncoder = AudioEncoder.aacLc;
const int _voiceBitRate = 64000;

/// The real MIME type of the file [RecordVoiceRecorder] produces. It must
/// stay in sync with the encoder above and with
/// [attachmentSupportedVoiceMimeTypes] in `talk_protocol`, because the
/// filename and MIME type sent to the server always have to match the
/// actual bytes on disk.
const String voiceRecordingMimeType = 'audio/mp4';
const String voiceRecordingFileExtension = '.m4a';

enum VoicePlatformError {
  closed,
  alreadyRecording,
  noActiveRecording,
  encodingUnsupported,
  foreignRecordingPath,
  invalidRecording,
  foreignSource,
}

final class VoicePlatformException implements Exception {
  const VoicePlatformException(this.code);

  final VoicePlatformError code;

  @override
  String toString() => 'VoicePlatformException(${code.name})';
}

abstract interface class VoiceCaptureBackend {
  Future<bool> requestPermission();

  Future<bool> supportsEncoding();

  Future<void> start({
    required String path,
    required int sampleRate,
    required int channels,
    required int bitRate,
  });

  Future<String?> stop();

  Future<void> cancel();

  Future<void> dispose();
}

/// Native `record` backend.
///
/// Linux recording requires the external `parecord`, `pactl`, and `ffmpeg`
/// commands documented by record 7.1.1. [supportsEncoding] is checked on
/// every recording start so a missing runtime dependency fails closed.
final class RecordPluginVoiceCaptureBackend implements VoiceCaptureBackend {
  RecordPluginVoiceCaptureBackend({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<bool> supportsEncoding() =>
      _recorder.isEncoderSupported(_voiceEncoder);

  @override
  Future<void> start({
    required String path,
    required int sampleRate,
    required int channels,
    required int bitRate,
  }) => _recorder.start(
    RecordConfig(
      encoder: _voiceEncoder,
      bitRate: bitRate,
      sampleRate: sampleRate,
      numChannels: channels,
      autoGain: true,
      echoCancel: true,
      noiseSuppress: true,
    ),
    path: path,
  );

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}

final class RecordMicrophonePermissionGateway
    implements MicrophonePermissionGateway {
  const RecordMicrophonePermissionGateway(this.backend);

  final VoiceCaptureBackend backend;

  @override
  Future<MicrophonePermissionStatus> request() async =>
      await backend.requestPermission()
      ? MicrophonePermissionStatus.granted
      : MicrophonePermissionStatus.denied;
}

/// Tells [RecordVoiceRecorder] when recording started and stopped so it can
/// derive a duration. Wall-clock elapsed time is a reliable,
/// container-format-agnostic proxy for audio duration here because a
/// recording session runs continuously from [start] to [stop] with no
/// seeking or pausing, and it avoids parsing MP4/AAC container metadata
/// just to learn how long a clip is.
abstract interface class VoiceRecordingClock {
  DateTime now();
}

final class SystemVoiceRecordingClock implements VoiceRecordingClock {
  const SystemVoiceRecordingClock();

  @override
  DateTime now() => DateTime.now();
}

enum _RecorderPhase { idle, starting, recording, stopping, closed }

final class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder({
    required VoiceCaptureBackend backend,
    required DurableAttachmentSourceStore store,
    int sampleRate = 48000,
    int channels = 1,
    int bitRate = _voiceBitRate,
    String displayName = 'voice-message.m4a',
    VoiceRecordingClock clock = const SystemVoiceRecordingClock(),
  }) : this._(
         backend: backend,
         store: store,
         sampleRate: sampleRate,
         channels: channels,
         bitRate: bitRate,
         displayName: displayName,
         clock: clock,
       );

  RecordVoiceRecorder._({
    required this.backend,
    required this.store,
    required this.sampleRate,
    required this.channels,
    required this.bitRate,
    required this.displayName,
    required VoiceRecordingClock clock,
    // ignore: prefer_initializing_formals
  }) : _clock = clock {
    if (sampleRate < 8000 || sampleRate > 192000) {
      throw ArgumentError.value(sampleRate, 'sampleRate');
    }
    if (channels < 1 || channels > 2) {
      throw ArgumentError.value(channels, 'channels');
    }
    if (bitRate < 8000 || bitRate > 320000) {
      throw ArgumentError.value(bitRate, 'bitRate');
    }
  }

  final VoiceCaptureBackend backend;
  final DurableAttachmentSourceStore store;
  final int sampleRate;
  final int channels;
  final int bitRate;
  final String displayName;
  final VoiceRecordingClock _clock;

  _RecorderPhase _phase = _RecorderPhase.idle;
  DurableAttachmentWriteSession? _session;
  DateTime? _startedAt;
  Future<void>? _closeFuture;

  @override
  Future<void> start() async {
    if (_phase == _RecorderPhase.closed) {
      throw const VoicePlatformException(VoicePlatformError.closed);
    }
    if (_phase != _RecorderPhase.idle) {
      throw const VoicePlatformException(VoicePlatformError.alreadyRecording);
    }
    _phase = _RecorderPhase.starting;
    DurableAttachmentWriteSession? session;
    try {
      if (!await backend.supportsEncoding()) {
        throw const VoicePlatformException(
          VoicePlatformError.encodingUnsupported,
        );
      }
      session = await store.beginExternalWrite(
        fileExtension: voiceRecordingFileExtension,
      );
      _session = session;
      await backend.start(
        path: session.filePath,
        sampleRate: sampleRate,
        channels: channels,
        bitRate: bitRate,
      );
      _startedAt = _clock.now();
      _phase = _RecorderPhase.recording;
    } catch (_) {
      _session = null;
      _startedAt = null;
      await session?.abort();
      _phase = _RecorderPhase.idle;
      rethrow;
    }
  }

  @override
  Future<VoiceRecording> stop() async {
    if (_phase == _RecorderPhase.closed) {
      throw const VoicePlatformException(VoicePlatformError.closed);
    }
    if (_phase != _RecorderPhase.recording || _session == null) {
      throw const VoicePlatformException(VoicePlatformError.noActiveRecording);
    }
    _phase = _RecorderPhase.stopping;
    final session = _session!;
    final startedAt = _startedAt!;
    _session = null;
    _startedAt = null;
    PreparedAttachmentSource? source;
    try {
      final returnedPath = await backend.stop();
      if (returnedPath == null || !session.matchesReturnedPath(returnedPath)) {
        throw const VoicePlatformException(
          VoicePlatformError.foreignRecordingPath,
        );
      }
      source = await session.commit(
        mimeType: voiceRecordingMimeType,
        displayName: displayName,
      );
      // Re-verifies the committed file still matches the recorded size and
      // hash before the recording is handed back to the caller.
      await store.resolveVerifiedPath(source);
      final duration = _clock.now().difference(startedAt);
      if (duration <= Duration.zero) {
        throw const VoicePlatformException(
          VoicePlatformError.invalidRecording,
        );
      }
      _phase = _RecorderPhase.idle;
      return VoiceRecording(source: source, duration: duration);
    } catch (_) {
      if (!session.isCompleted) {
        await session.abort();
      }
      if (source != null) {
        await store.discard(source.handle);
      }
      _phase = _RecorderPhase.idle;
      rethrow;
    }
  }

  @override
  Future<void> cancel() async {
    if (_phase == _RecorderPhase.closed || _phase == _RecorderPhase.idle) {
      return;
    }
    final session = _session;
    _session = null;
    _startedAt = null;
    Object? firstFailure;
    StackTrace? firstStack;
    try {
      await backend.cancel();
    } on Object catch (error, stackTrace) {
      firstFailure = error;
      firstStack = stackTrace;
    }
    try {
      await session?.abort();
    } on Object catch (error, stackTrace) {
      firstFailure ??= error;
      firstStack ??= stackTrace;
    }
    _phase = _RecorderPhase.idle;
    if (firstFailure != null) {
      Error.throwWithStackTrace(firstFailure, firstStack!);
    }
  }

  @override
  Future<void> discard(PreparedAttachmentSource source) {
    if (source.ownership != AttachmentSourceOwnership.appOwnedCopy) {
      throw const VoicePlatformException(VoicePlatformError.foreignSource);
    }
    return store.discard(source.handle);
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    Object? firstFailure;
    StackTrace? firstStack;
    if (_phase != _RecorderPhase.idle && _phase != _RecorderPhase.closed) {
      try {
        await cancel();
      } on Object catch (error, stackTrace) {
        firstFailure = error;
        firstStack = stackTrace;
      }
    }
    _phase = _RecorderPhase.closed;
    try {
      await backend.dispose();
    } on Object catch (error, stackTrace) {
      firstFailure ??= error;
      firstStack ??= stackTrace;
    }
    if (firstFailure != null) {
      Error.throwWithStackTrace(firstFailure, firstStack!);
    }
  }
}

abstract interface class VoicePlaybackBackend {
  Stream<void> get completed;

  /// Playback position ticks while a file plays.
  Stream<Duration> get positionChanged;

  /// Fires once the total length of the currently loaded file is known.
  Stream<Duration> get durationChanged;

  /// [mimeType] must describe the real content of [path]; it is forwarded
  /// to the platform player instead of being guessed, so a WAV recording
  /// is never played back as if it were something else.
  Future<void> playFile(String path, {required String mimeType});

  Future<void> stop();

  Future<void> dispose();
}

final class AudioplayersVoicePlaybackBackend implements VoicePlaybackBackend {
  AudioplayersVoicePlaybackBackend({AudioPlayer? player})
    : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Stream<void> get completed => _player.onPlayerComplete;

  @override
  Stream<Duration> get positionChanged => _player.onPositionChanged;

  @override
  Stream<Duration> get durationChanged => _player.onDurationChanged;

  @override
  Future<void> playFile(String path, {required String mimeType}) =>
      _player.play(DeviceFileSource(path, mimeType: mimeType));

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

final class AudioplayersVoicePreviewPlayer implements VoicePreviewPlayer {
  AudioplayersVoicePreviewPlayer({required this.backend, required this.store});

  final VoicePlaybackBackend backend;
  final DurableAttachmentSourceStore store;
  _ActivePlayback? _active;
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  Future<void> play(PreparedAttachmentSource source) async {
    if (_closed) {
      throw const VoicePlatformException(VoicePlatformError.closed);
    }
    if (_active != null) {
      await stop();
    }
    final path = await store.resolveVerifiedPath(source);
    if (_closed) {
      throw const VoicePlatformException(VoicePlatformError.closed);
    }
    final active = _ActivePlayback();
    _active = active;
    active.subscription = backend.completed.listen(
      (_) => _complete(active),
      onError: (Object error, StackTrace stackTrace) =>
          _completeError(active, error, stackTrace),
    );
    try {
      await Future.wait<void>(<Future<void>>[
        backend.playFile(path, mimeType: source.mimeType),
        active.completer.future,
      ], eagerError: true);
    } finally {
      await active.subscription.cancel();
      if (identical(_active, active)) {
        _active = null;
      }
    }
  }

  @override
  Future<void> stop() async {
    final active = _active;
    if (active == null) {
      return;
    }
    _active = null;
    Object? failure;
    StackTrace? failureStack;
    try {
      await backend.stop();
    } on Object catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    if (!active.completer.isCompleted) {
      active.completer.complete();
    }
    await active.subscription.cancel();
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    Object? failure;
    StackTrace? failureStack;
    try {
      await stop();
    } on Object catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    try {
      await backend.dispose();
    } on Object catch (error, stackTrace) {
      failure ??= error;
      failureStack ??= stackTrace;
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
  }

  void _complete(_ActivePlayback active) {
    if (identical(_active, active) && !active.completer.isCompleted) {
      active.completer.complete();
    }
  }

  void _completeError(
    _ActivePlayback active,
    Object error,
    StackTrace stackTrace,
  ) {
    if (identical(_active, active) && !active.completer.isCompleted) {
      active.completer.completeError(error, stackTrace);
    }
  }
}

final class _ActivePlayback {
  final Completer<void> completer = Completer<void>();
  late StreamSubscription<void> subscription;
}
