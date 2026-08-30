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
  startTimedOut,
  startCancelled,
}

final class VoicePlatformException implements Exception {
  const VoicePlatformException(this.code);

  final VoicePlatformError code;

  @override
  String toString() => 'VoicePlatformException(${code.name})';
}

/// How often loudness samples are requested while recording. Roughly eight
/// samples a second is enough for the waveform to look alive without waking
/// the platform channel on every frame.
const Duration voiceAmplitudeInterval = Duration(milliseconds: 120);

/// dBFS window the waveform maps onto its 0..1 bar height. Anything quieter
/// than [_amplitudeFloorDb] is drawn as silence.
const double _amplitudeFloorDb = -50;

abstract interface class VoiceCaptureBackend {
  Future<bool> requestPermission();

  Future<bool> supportsEncoding();

  Future<void> start({
    required String path,
    required int sampleRate,
    required int channels,
    required int bitRate,
  });

  Future<void> retirePendingStart({required Future<void> pendingStart});

  Future<void> pause();

  Future<void> resume();

  /// Loudness of the running recording, normalised to 0..1. The stream only
  /// ticks while the session is actually capturing; `record` stops its own
  /// amplitude monitoring for the duration of a pause.
  Stream<double> get amplitude;

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
  RecordPluginVoiceCaptureBackend({
    AudioRecorder? recorder,
    AudioRecorder Function()? recorderFactory,
  }) : _recorderFactory = recorderFactory ?? AudioRecorder.new,
       _recorder = recorder ?? (recorderFactory ?? AudioRecorder.new)();

  final AudioRecorder Function() _recorderFactory;
  AudioRecorder _recorder;
  Future<void>? _pendingStart;
  AudioRecorder? _pendingStartRecorder;

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
  }) {
    final recorder = _recorder;
    final pendingStart = recorder.start(
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
    _pendingStart = pendingStart;
    _pendingStartRecorder = recorder;
    return pendingStart;
  }

  @override
  Future<void> retirePendingStart({required Future<void> pendingStart}) {
    if (!identical(_pendingStart, pendingStart)) {
      return Future<void>.value();
    }
    final retired = _pendingStartRecorder!;
    _pendingStart = null;
    _pendingStartRecorder = null;
    if (identical(_recorder, retired)) {
      _recorder = _recorderFactory();
    }
    final initialCancel = _ignoreFailure(retired.cancel);
    return _cleanUpRetiredRecorder(retired, pendingStart, initialCancel);
  }

  Future<void> _cleanUpRetiredRecorder(
    AudioRecorder recorder,
    Future<void> pendingStart,
    Future<void> initialCancel,
  ) async {
    await _ignoreFailure(() => pendingStart);
    await initialCancel;
    await _ignoreFailure(recorder.cancel);
    await _ignoreFailure(recorder.dispose);
  }

  Future<void> _ignoreFailure(Future<void> Function() operation) async {
    try {
      await operation();
    } on Object {
      // A timed-out recorder is retired permanently; cleanup cannot be
      // retried through its serial platform channel.
    }
  }

  @override
  Future<void> pause() => _recorder.pause();

  @override
  Future<void> resume() => _recorder.resume();

  @override
  Stream<double> get amplitude => _recorder
      .onAmplitudeChanged(voiceAmplitudeInterval)
      .map((sample) => normalizedVoiceAmplitude(sample.current));

  @override
  Future<String?> stop() async {
    final path = await _recorder.stop();
    _pendingStart = null;
    _pendingStartRecorder = null;
    return path;
  }

  @override
  Future<void> cancel() async {
    await _recorder.cancel();
    _pendingStart = null;
    _pendingStartRecorder = null;
  }

  @override
  Future<void> dispose() async {
    await _recorder.dispose();
    _pendingStart = null;
    _pendingStartRecorder = null;
  }
}

/// Maps a dBFS reading onto the 0..1 range the waveform draws. Values are
/// clamped instead of rejected because platforms disagree on their silence
/// floor (`-160` on Android, `-120` elsewhere).
double normalizedVoiceAmplitude(double decibels) {
  if (decibels.isNaN) {
    return 0;
  }
  return ((decibels - _amplitudeFloorDb) / -_amplitudeFloorDb).clamp(0.0, 1.0);
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

/// Tells [RecordVoiceRecorder] when recording started, paused and stopped so
/// it can derive a duration. Wall-clock elapsed time is a reliable,
/// container-format-agnostic proxy for audio duration here because the
/// recorder counts only the stretches it was actually capturing — paused
/// stretches are excluded — and it avoids parsing MP4/AAC container metadata
/// just to learn how long a clip is.
abstract interface class VoiceRecordingClock {
  DateTime now();
}

final class SystemVoiceRecordingClock implements VoiceRecordingClock {
  const SystemVoiceRecordingClock();

  @override
  DateTime now() => DateTime.now();
}

enum _RecorderPhase { idle, starting, recording, paused, stopping, closed }

final class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder({
    required VoiceCaptureBackend backend,
    required DurableAttachmentSourceStore store,
    int sampleRate = 48000,
    int channels = 1,
    int bitRate = _voiceBitRate,
    String displayName = 'voice-message.m4a',
    VoiceRecordingClock clock = const SystemVoiceRecordingClock(),
    Duration startTimeout = const Duration(seconds: 10),
  }) : this._(
         backend: backend,
         store: store,
         sampleRate: sampleRate,
         channels: channels,
         bitRate: bitRate,
         displayName: displayName,
         clock: clock,
         startTimeout: startTimeout,
       );

  RecordVoiceRecorder._({
    required this.backend,
    required this.store,
    required this.sampleRate,
    required this.channels,
    required this.bitRate,
    required this.displayName,
    required VoiceRecordingClock clock,
    required this.startTimeout,
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
    if (startTimeout <= Duration.zero) {
      throw ArgumentError.value(startTimeout, 'startTimeout');
    }
  }

  final VoiceCaptureBackend backend;
  final DurableAttachmentSourceStore store;
  final int sampleRate;
  final int channels;
  final int bitRate;
  final String displayName;
  final Duration startTimeout;
  final VoiceRecordingClock _clock;

  _RecorderPhase _phase = _RecorderPhase.idle;
  DurableAttachmentWriteSession? _session;
  DateTime? _startedAt;
  Duration _captured = Duration.zero;
  Future<void>? _closeFuture;
  _VoiceStartAttempt? _startAttempt;

  @override
  Stream<double> get amplitude => backend.amplitude;

  @override
  Future<void> start() async {
    if (_phase == _RecorderPhase.closed) {
      throw const VoicePlatformException(VoicePlatformError.closed);
    }
    if (_phase != _RecorderPhase.idle) {
      throw const VoicePlatformException(VoicePlatformError.alreadyRecording);
    }
    _phase = _RecorderPhase.starting;
    final attempt = _VoiceStartAttempt();
    _startAttempt = attempt;
    DurableAttachmentWriteSession? session;
    try {
      final supported = await backend.supportsEncoding();
      _requireCurrentStart(attempt);
      if (!supported) {
        throw const VoicePlatformException(
          VoicePlatformError.encodingUnsupported,
        );
      }
      session = await store.beginExternalWrite(
        fileExtension: voiceRecordingFileExtension,
      );
      attempt.session = session;
      _requireCurrentStart(attempt);
      _session = session;
      final pendingStart = backend.start(
        path: session.filePath,
        sampleRate: sampleRate,
        channels: channels,
        bitRate: bitRate,
      );
      attempt.pendingStart = pendingStart;
      try {
        await pendingStart.timeout(startTimeout);
      } on TimeoutException {
        _requireCurrentStart(attempt);
        _retireStart(attempt);
        throw const VoicePlatformException(VoicePlatformError.startTimedOut);
      }
      _requireCurrentStart(attempt);
      _startAttempt = null;
      _startedAt = _clock.now();
      _captured = Duration.zero;
      _phase = _RecorderPhase.recording;
    } catch (_) {
      if (identical(_startAttempt, attempt)) {
        _startAttempt = null;
        _session = null;
        _startedAt = null;
        _captured = Duration.zero;
        if (_phase != _RecorderPhase.closed) {
          _phase = _RecorderPhase.idle;
        }
      }
      if (!attempt.retired && session != null && !session.isCompleted) {
        await session.abort();
      }
      rethrow;
    }
  }

  void _requireCurrentStart(_VoiceStartAttempt attempt) {
    if (!identical(_startAttempt, attempt)) {
      final code = _phase == _RecorderPhase.closed
          ? VoicePlatformError.closed
          : VoicePlatformError.startCancelled;
      throw VoicePlatformException(code);
    }
  }

  void _retireStart(_VoiceStartAttempt attempt) {
    final pendingStart = attempt.pendingStart;
    final session = attempt.session;
    if (attempt.retired || pendingStart == null || session == null) {
      return;
    }
    attempt.retired = true;
    final retirement = backend.retirePendingStart(pendingStart: pendingStart);
    unawaited(_settleNativeRetirement(retirement));
    unawaited(_removeRetiredWrite(session));
    unawaited(_removeRetiredWriteAfterStart(pendingStart, session));
  }

  Future<void> _settleNativeRetirement(Future<void> retirement) async {
    try {
      await retirement;
    } on Object {
      // Retirement is best effort after the replacement recorder is active.
    }
  }

  Future<void> _removeRetiredWrite(
    DurableAttachmentWriteSession session,
  ) async {
    try {
      await session.removeLateWrite();
    } on Object {
      // A retired native start cannot be allowed to fail a later recording.
    }
  }

  Future<void> _removeRetiredWriteAfterStart(
    Future<void> pendingStart,
    DurableAttachmentWriteSession session,
  ) async {
    try {
      await pendingStart;
    } on Object {
      // A failed start can still leave a partial file behind.
    }
    await _removeRetiredWrite(session);
  }

  @override
  Future<void> pause() async {
    if (_phase == _RecorderPhase.closed) {
      throw const VoicePlatformException(VoicePlatformError.closed);
    }
    if (_phase != _RecorderPhase.recording || _session == null) {
      throw const VoicePlatformException(VoicePlatformError.noActiveRecording);
    }
    await backend.pause();
    _captured += _clock.now().difference(_startedAt!);
    _startedAt = null;
    _phase = _RecorderPhase.paused;
  }

  @override
  Future<void> resume() async {
    if (_phase == _RecorderPhase.closed) {
      throw const VoicePlatformException(VoicePlatformError.closed);
    }
    if (_phase != _RecorderPhase.paused || _session == null) {
      throw const VoicePlatformException(VoicePlatformError.noActiveRecording);
    }
    await backend.resume();
    _startedAt = _clock.now();
    _phase = _RecorderPhase.recording;
  }

  @override
  Future<VoiceRecording> stop() async {
    if (_phase == _RecorderPhase.closed) {
      throw const VoicePlatformException(VoicePlatformError.closed);
    }
    if ((_phase != _RecorderPhase.recording &&
            _phase != _RecorderPhase.paused) ||
        _session == null) {
      throw const VoicePlatformException(VoicePlatformError.noActiveRecording);
    }
    final startedAt = _startedAt;
    final captured =
        _captured +
        (startedAt == null
            ? Duration.zero
            : _clock.now().difference(startedAt));
    _phase = _RecorderPhase.stopping;
    final session = _session!;
    _session = null;
    _startedAt = null;
    _captured = Duration.zero;
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
      final duration = captured;
      if (duration <= Duration.zero) {
        throw const VoicePlatformException(VoicePlatformError.invalidRecording);
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
    final attempt = _startAttempt;
    final session = attempt?.session ?? _session;
    _startAttempt = null;
    _session = null;
    _startedAt = null;
    _captured = Duration.zero;
    Object? firstFailure;
    StackTrace? firstStack;
    if (attempt?.pendingStart != null) {
      _retireStart(attempt!);
    } else {
      try {
        await backend.cancel();
      } on Object catch (error, stackTrace) {
        firstFailure = error;
        firstStack = stackTrace;
      }
    }
    if (attempt?.retired != true) {
      try {
        await session?.abort();
      } on Object catch (error, stackTrace) {
        firstFailure ??= error;
        firstStack ??= stackTrace;
      }
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

final class _VoiceStartAttempt {
  DurableAttachmentWriteSession? session;
  Future<void>? pendingStart;
  bool retired = false;
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

  Future<void> pause();

  Future<void> resume();

  /// Moves the playhead of the currently loaded file.
  Future<void> seek(Duration position);

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
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

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
