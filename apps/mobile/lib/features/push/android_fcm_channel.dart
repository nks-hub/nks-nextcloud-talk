// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/services.dart';

/// Bridges the native `com.nkshub.nextcloudtalk/fcm` channel and hands every
/// FCM registration token to [onToken].
///
/// That token is what the proxy uses to address this device, so it never
/// reaches a log — not truncated, not in a debug build. This class only
/// bridges; the registration itself happens in
/// `push_registration_coordinator.dart`.
final class AndroidFcmChannel {
  AndroidFcmChannel({MethodChannel? channel, void Function(String)? onToken})
    : _channel = channel ?? const MethodChannel(channelName),
      _onToken = onToken {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/fcm';

  final MethodChannel _channel;
  final void Function(String)? _onToken;
  var _started = false;
  var _disposed = false;
  Future<void>? _startFuture;

  /// Fetches the current token once per session and forwards it.
  ///
  /// A rotation while the app runs arrives later as `tokenRefreshed`; one that
  /// happened while it was dead is already reflected in what this returns.
  /// A failed request clears the single-flight slot so the provider's bounded
  /// retry can ask Play Services again in this process.
  Future<void> start() {
    if (_disposed || _started) {
      return Future<void>.value();
    }
    final existing = _startFuture;
    if (existing != null) {
      return existing;
    }
    late final Future<void> current;
    current = _fetchToken().whenComplete(() {
      if (identical(_startFuture, current)) {
        _startFuture = null;
      }
    });
    _startFuture = current;
    return current;
  }

  Future<void> _fetchToken() async {
    final token = await _channel.invokeMethod<String>('getToken');
    if (_disposed) {
      return;
    }
    if (token == null || token.isEmpty) {
      throw StateError('FCM returned an empty registration token');
    }
    _onToken?.call(token);
    _started = true;
  }

  /// Tells the native side which accounts are signed in. A delivery can wake
  /// a dead process, and the account a message belongs to is whichever one's
  /// device key opens it, so the list has to outlive the app.
  Future<void> setAccounts(Iterable<String> accountIds) {
    return _channel.invokeMethod<void>('setAccounts', {
      'accountIds': accountIds.toList(growable: false),
    });
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'tokenRefreshed') {
      throw MissingPluginException('Unknown FCM callback.');
    }
    final token = call.arguments;
    if (token is String && token.isNotEmpty) {
      _onToken?.call(token);
    }
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}
