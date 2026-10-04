import 'dart:async';

import 'package:flutter/services.dart';

/// Holds Android's foreground service for as long as attachments transfer.
///
/// Android freezes a backgrounded app within about ten seconds, the system
/// photo picker included, and a frozen process stops feeding the upload body
/// mid-chunk. The service keeps the process running; it does no work itself.
///
/// Stopping lingers for [linger]: the next chunk or retry usually follows
/// within it, and a service stopped before it reached the foreground would
/// crash the process on Android 12+.
final class AttachmentTransferKeepAlive {
  AttachmentTransferKeepAlive({
    this._channel = const MethodChannel(channelName),
    this.linger = const Duration(seconds: 5),
  });

  static const channelName = 'com.nkshub.nextcloudtalk/attachment_transfer';

  final MethodChannel _channel;
  final Duration linger;
  Timer? _stopTimer;
  bool _running = false;

  void report(bool active) {
    if (active) {
      _stopTimer?.cancel();
      _stopTimer = null;
      if (!_running) {
        _running = true;
        unawaited(_invoke('start'));
      }
      return;
    }
    if (!_running || _stopTimer != null) {
      return;
    }
    _stopTimer = Timer(linger, () {
      _stopTimer = null;
      _running = false;
      unawaited(_invoke('stop'));
    });
  }

  void dispose() {
    _stopTimer?.cancel();
    _stopTimer = null;
    if (_running) {
      _running = false;
      unawaited(_invoke('stop'));
    }
  }

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Not Android, or no engine attached: nothing to keep alive.
    } on PlatformException {
      // Best effort; the upload runs either way.
    }
  }
}
