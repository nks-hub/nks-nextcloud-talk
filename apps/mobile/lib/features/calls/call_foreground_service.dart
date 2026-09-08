import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_media_engine.dart';

abstract interface class CallForegroundService {
  Future<void> start(String owner);
  Future<void> stop(String owner);
}

final callForegroundServiceProvider = Provider<CallForegroundService>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? const AndroidCallForegroundService()
      : const NoCallForegroundService(),
);

final class AndroidCallForegroundService implements CallForegroundService {
  const AndroidCallForegroundService({
    MethodChannel channel = const MethodChannel(channelName),
  }) : this._(channel);

  const AndroidCallForegroundService._(this._channel);

  static const channelName = 'com.nkshub.nextcloudtalk/call_foreground';
  final MethodChannel _channel;

  @override
  Future<void> start(String owner) async {
    try {
      final status = await _channel.invokeMethod<String>('start', {
        'owner': owner,
      });
      if (status == 'started') return;
      throw CallMediaException(
        status == 'permission-denied'
            ? CallMediaError.microphonePermissionDenied
            : CallMediaError.engineFailure,
      );
    } on MissingPluginException {
      throw const CallMediaException(CallMediaError.engineFailure);
    } on PlatformException {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
  }

  @override
  Future<void> stop(String owner) async {
    try {
      await _channel.invokeMethod<void>('stop', {'owner': owner});
    } on MissingPluginException {
      // Activity destruction also releases every token owned by its channel.
    } on PlatformException {
      // The native owner may already have been stopped by Android.
    }
  }
}

/// Other platforms do not require an Android microphone foreground service.
final class NoCallForegroundService implements CallForegroundService {
  const NoCallForegroundService();
  @override
  Future<void> start(String owner) async {}
  @override
  Future<void> stop(String owner) async {}
}
