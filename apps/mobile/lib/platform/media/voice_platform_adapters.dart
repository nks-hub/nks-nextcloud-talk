import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:nextcloudtalk/features/chat/composer/voice_message.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:record/record.dart';
import 'package:talk_protocol/talk_protocol.dart';

enum VoicePlatformError {
  closed,
  alreadyRecording,
  noActiveRecording,
  wavUnsupported,
  foreignRecordingPath,
  invalidWave,
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

  Future<bool> supportsWaveEncoding();

  Future<void> startWave({
    required String path,
    required int sampleRate,
    required int channels,
  });

  Future<String?> stop();

  Future<void> cancel();

  Future<void> dispose();
}

/// Native `record` backend.
///
/// Linux recording requires the external `parecord`, `pactl`, and `ffmpeg`
/// commands documented by record 7.1.1. [supportsWaveEncoding] is checked on
/// every recording start so a missing runtime dependency fails closed.
final class RecordPluginVoiceCaptureBackend implements VoiceCaptureBackend {
  RecordPluginVoiceCaptureBackend({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<bool> supportsWaveEncoding() =>
      _recorder.isEncoderSupported(AudioEncoder.wav);

  @override
  Future<void> startWave({
    required String path,
    required int sampleRate,
    required int channels,
  }) => _recorder.start(
    RecordConfig(
      encoder: AudioEncoder.wav,
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

enum _RecorderPhase { idle, starting, recording, stopping, closed }

final class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder({
    required VoiceCaptureBackend backend,
    required DurableAttachmentSourceStore store,
    int sampleRate = 48000,
    int channels = 1,
    String displayName = 'voice-message.wav',
    WavDurationReader durationReader = const WavDurationReader(),
  }) : this._(
         backend: backend,
         store: store,
         sampleRate: sampleRate,
         channels: channels,
         displayName: displayName,
         durationReader: durationReader,
       );

  RecordVoiceRecorder._({
    required this.backend,
    required this.store,
    required this.sampleRate,
    required this.channels,
    required this.displayName,
    required this._durationReader,
  }) {
    if (sampleRate < 8000 || sampleRate > 192000) {
      throw ArgumentError.value(sampleRate, 'sampleRate');
    }
    if (channels < 1 || channels > 2) {
      throw ArgumentError.value(channels, 'channels');
    }
  }

  final VoiceCaptureBackend backend;
  final DurableAttachmentSourceStore store;
  final int sampleRate;
  final int channels;
  final String displayName;
  final WavDurationReader _durationReader;

  _RecorderPhase _phase = _RecorderPhase.idle;
  DurableAttachmentWriteSession? _session;
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
      if (!await backend.supportsWaveEncoding()) {
        throw const VoicePlatformException(VoicePlatformError.wavUnsupported);
      }
      session = await store.beginExternalWrite(fileExtension: '.wav');
      _session = session;
      await backend.startWave(
        path: session.filePath,
        sampleRate: sampleRate,
        channels: channels,
      );
      _phase = _RecorderPhase.recording;
    } catch (_) {
      _session = null;
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
    _session = null;
    PreparedAttachmentSource? source;
    try {
      final returnedPath = await backend.stop();
      if (returnedPath == null || !session.matchesReturnedPath(returnedPath)) {
        throw const VoicePlatformException(
          VoicePlatformError.foreignRecordingPath,
        );
      }
      source = await session.commit(
        mimeType: 'audio/wav',
        displayName: displayName,
      );
      final path = await store.resolveVerifiedPath(source);
      final duration = await _durationReader.read(path);
      if (duration <= Duration.zero) {
        throw const VoicePlatformException(VoicePlatformError.invalidWave);
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

final class WavDurationReader {
  const WavDurationReader();

  Future<Duration> read(String path) async {
    final file = await File(path).open(mode: FileMode.read);
    try {
      final fileLength = await file.length();
      if (fileLength < 44) {
        throw const VoicePlatformException(VoicePlatformError.invalidWave);
      }
      final header = await file.read(12);
      if (_ascii(header, 0) != 'RIFF' || _ascii(header, 8) != 'WAVE') {
        throw const VoicePlatformException(VoicePlatformError.invalidWave);
      }
      int? byteRate;
      int? dataLength;
      var position = 12;
      while (position + 8 <= fileLength) {
        await file.setPosition(position);
        final chunkHeader = await file.read(8);
        if (chunkHeader.length != 8) {
          break;
        }
        final chunkName = _ascii(chunkHeader, 0);
        final chunkLength = ByteData.sublistView(
          Uint8List.fromList(chunkHeader),
        ).getUint32(4, Endian.little);
        final dataStart = position + 8;
        final paddedLength = chunkLength + (chunkLength.isOdd ? 1 : 0);
        if (chunkLength < 0 || dataStart + paddedLength > fileLength) {
          throw const VoicePlatformException(VoicePlatformError.invalidWave);
        }
        if (chunkName == 'fmt ') {
          if (chunkLength < 16) {
            throw const VoicePlatformException(VoicePlatformError.invalidWave);
          }
          await file.setPosition(dataStart);
          final formatBytes = await file.read(16);
          if (formatBytes.length != 16) {
            throw const VoicePlatformException(VoicePlatformError.invalidWave);
          }
          final format = ByteData.sublistView(Uint8List.fromList(formatBytes));
          final encoding = format.getUint16(0, Endian.little);
          final channels = format.getUint16(2, Endian.little);
          final sampleRate = format.getUint32(4, Endian.little);
          final declaredByteRate = format.getUint32(8, Endian.little);
          final blockAlign = format.getUint16(12, Endian.little);
          final bitsPerSample = format.getUint16(14, Endian.little);
          if (encoding != 1 ||
              channels < 1 ||
              sampleRate < 1 ||
              blockAlign < 1 ||
              bitsPerSample < 1 ||
              bitsPerSample % 8 != 0 ||
              blockAlign != channels * (bitsPerSample ~/ 8) ||
              declaredByteRate != sampleRate * blockAlign) {
            throw const VoicePlatformException(VoicePlatformError.invalidWave);
          }
          byteRate = declaredByteRate;
        } else if (chunkName == 'data') {
          dataLength = chunkLength;
        }
        if (byteRate != null && dataLength != null) {
          break;
        }
        position = dataStart + paddedLength;
      }
      if (byteRate == null || dataLength == null || dataLength < 1) {
        throw const VoicePlatformException(VoicePlatformError.invalidWave);
      }
      final microseconds =
          (dataLength * Duration.microsecondsPerSecond + byteRate ~/ 2) ~/
          byteRate;
      if (microseconds < 1) {
        throw const VoicePlatformException(VoicePlatformError.invalidWave);
      }
      return Duration(microseconds: microseconds);
    } finally {
      await file.close();
    }
  }

  String _ascii(List<int> bytes, int start) {
    if (start < 0 || start + 4 > bytes.length) {
      return '';
    }
    return String.fromCharCodes(bytes.sublist(start, start + 4));
  }
}

abstract interface class VoicePlaybackBackend {
  Stream<void> get completed;

  Future<void> playFile(String path);

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
  Future<void> playFile(String path) =>
      _player.play(DeviceFileSource(path, mimeType: 'audio/wav'));

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
        backend.playFile(path),
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
