import 'dart:async';

import 'package:flutter/services.dart';

/// Holds Android's foreground service for as long as something is being
/// sent: an attachment upload or a text message on its way to the server.
///
/// Android freezes a backgrounded app within about ten seconds, the system
/// photo picker included, and a frozen process stops feeding the upload body
/// mid-chunk or never finishes a message sent just before the app was left.
/// The service keeps the process running; it does no work itself.
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
  final Set<Object> _holders = <Object>{};
  Timer? _stopTimer;
  bool _running = false;

  /// A reporter of its own. The service runs while any holder is active, so
  /// one sender finishing does not release it under another.
  void Function(bool active) holder() {
    final key = Object();
    return (active) {
      if (active) {
        _holders.add(key);
      } else {
        _holders.remove(key);
      }
      report(_holders.isNotEmpty);
    };
  }

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
