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

  /// Fetches the current token once per session and forwards it.
  ///
  /// A rotation while the app runs arrives later as `tokenRefreshed`; one that
  /// happened while it was dead is already reflected in what this returns.
  /// A failure is left to the caller's own retry — Play Services can be
  /// missing or offline, and there is nothing useful to do about it here.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    final token = await _channel.invokeMethod<String>('getToken');
    if (token != null && token.isNotEmpty) {
      _onToken?.call(token);
    }
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
    _channel.setMethodCallHandler(null);
  }
}
