/// The foreground service a screen capture needs while it runs.
///
/// From Android 10 the system only grants a `MediaProjection` while a
/// foreground service of type `mediaProjection` is running, and from Android
/// 14 it stops the capture outright when there is none. The WebRTC plugin
/// ships no such service, so the app owns one and starts it around the share.
/// Its notification is also what tells the user their screen is visible.
library;

import 'package:flutter/services.dart';

abstract interface class CallScreenShareService {
  /// Whether the platform is ready for a capture. `false` means no share
  /// should be attempted at all.
  Future<bool> start();

  Future<void> stop();
}

final class PlatformCallScreenShareService implements CallScreenShareService {
  const PlatformCallScreenShareService({
    MethodChannel channel = const MethodChannel(channelName),
  }) : this._(channel);

  const PlatformCallScreenShareService._(this._channel);

  static const channelName = 'com.nkshub.nextcloudtalk/screen_share';

  final MethodChannel _channel;

  @override
  Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('start') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing was ever started.
    } on PlatformException {
      // The service is gone either way.
    }
  }
}

/// Platforms that capture without a service of their own.
final class NoCallScreenShareService implements CallScreenShareService {
  const NoCallScreenShareService();

  @override
  Future<bool> start() async => true;

  @override
  Future<void> stop() async {}
}
