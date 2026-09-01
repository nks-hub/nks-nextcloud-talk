import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum VoiceTranscriptionFailure {
  denied,
  restricted,
  unavailable,
  invalidFile,
  failed,
  cancelled,
  unsupported,
}

final class VoiceTranscriptionException implements Exception {
  const VoiceTranscriptionException(this.failure, [this.message]);

  final VoiceTranscriptionFailure failure;
  final String? message;

  @override
  String toString() {
    final detail = message;
    return detail == null
        ? 'VoiceTranscriptionException(${failure.name})'
        : 'VoiceTranscriptionException(${failure.name}, $detail)';
  }
}

abstract interface class VoiceTranscriber {
  Future<String> transcribe({
    required String filePath,
    String? localeIdentifier,
    Duration timeout = const Duration(seconds: 60),
  });

  Future<void> cancel();

  Future<void> dispose();
}

final class MethodChannelVoiceTranscriber implements VoiceTranscriber {
  MethodChannelVoiceTranscriber({
    this._channel = const MethodChannel(channelName),
    bool? supported,
  }) : _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  static const channelName = 'com.nkshub.nextcloudtalk/voice_transcription';
  static const _defaultTimeout = Duration(seconds: 60);
  static const _minimumTimeout = Duration(seconds: 1);
  static const _maximumTimeout = Duration(minutes: 5);

  final MethodChannel _channel;
  final bool _supported;
  int _generation = 0;
  bool _disposed = false;

  @override
  Future<String> transcribe({
    required String filePath,
    String? localeIdentifier,
    Duration timeout = _defaultTimeout,
  }) async {
    if (!_supported) {
      throw const VoiceTranscriptionException(
        VoiceTranscriptionFailure.unsupported,
      );
    }
    if (_disposed) {
      throw const VoiceTranscriptionException(
        VoiceTranscriptionFailure.cancelled,
      );
    }
    if (timeout < _minimumTimeout || timeout > _maximumTimeout) {
      throw const VoiceTranscriptionException(
        VoiceTranscriptionFailure.failed,
        'Invalid transcription timeout.',
      );
    }
    if (localeIdentifier?.isEmpty ?? false) {
      throw const VoiceTranscriptionException(
        VoiceTranscriptionFailure.failed,
        'Invalid transcription locale.',
      );
    }

    final generation = ++_generation;
    final arguments = <String, Object?>{
      'filePath': filePath,
      'timeoutMillis': timeout.inMilliseconds,
      'localeIdentifier': ?localeIdentifier,
    };
    final Object? value;
    try {
      value = await _channel.invokeMethod<Object?>('transcribe', arguments);
    } on PlatformException catch (error) {
      if (!_isCurrent(generation)) {
        throw const VoiceTranscriptionException(
          VoiceTranscriptionFailure.cancelled,
        );
      }
      throw VoiceTranscriptionException(
        _failureForCode(error.code),
        error.message,
      );
    } on MissingPluginException {
      if (!_isCurrent(generation)) {
        throw const VoiceTranscriptionException(
          VoiceTranscriptionFailure.cancelled,
        );
      }
      throw const VoiceTranscriptionException(
        VoiceTranscriptionFailure.unavailable,
      );
    }
    if (!_isCurrent(generation)) {
      throw const VoiceTranscriptionException(
        VoiceTranscriptionFailure.cancelled,
      );
    }
    if (value is! String || value.trim().isEmpty) {
      throw const VoiceTranscriptionException(
        VoiceTranscriptionFailure.failed,
        'Speech recognition returned no text.',
      );
    }
    return value;
  }

  @override
  Future<void> cancel() async {
    if (_disposed) {
      return;
    }
    _generation++;
    if (_supported) {
      await _invokeLifecycleMethod('cancel');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    if (_supported) {
      await _invokeLifecycleMethod('dispose');
    }
  }

  bool _isCurrent(int generation) {
    return !_disposed && generation == _generation;
  }

  Future<void> _invokeLifecycleMethod(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      return;
    }
  }

  VoiceTranscriptionFailure _failureForCode(String code) {
    return switch (code) {
      'denied' => VoiceTranscriptionFailure.denied,
      'restricted' => VoiceTranscriptionFailure.restricted,
      'unavailable' => VoiceTranscriptionFailure.unavailable,
      'invalidFile' => VoiceTranscriptionFailure.invalidFile,
      'cancelled' => VoiceTranscriptionFailure.cancelled,
      _ => VoiceTranscriptionFailure.failed,
    };
  }
}
