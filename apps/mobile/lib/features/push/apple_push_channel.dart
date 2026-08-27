import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges the native `com.nkshub.nextcloudtalk/apple_push` channel that
/// `AppDelegate.swift` exposes on iOS.
///
/// There is no push proxy able to accept an APNs token yet — the public
/// Nextcloud push proxy only delivers to the official Talk app's bundle id
/// (see docs/TODO.md R-018). So this only asks for permission and keeps
/// whatever token APNs hands back; it does not register it anywhere, and it
/// never will until a real proxy exists to send it to.
final class ApplePushCoordinator {
  ApplePushCoordinator({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/apple_push';

  final MethodChannel _channel;
  bool _requested = false;

  /// Asks the user for notification permission once per app session and
  /// logs whatever device token APNs hands back.
  ///
  /// Safe to call again later (e.g. after a second account signs in): the
  /// system dialog only appears once, so a repeat ask just returns the
  /// user's earlier decision. The internal guard keeps this coordinator from
  /// firing the request twice for the same session regardless.
  Future<void> requestPermissionAndLogToken() async {
    if (_requested) {
      return;
    }
    _requested = true;
    final granted =
        await _channel.invokeMethod<bool>('requestPermission') ?? false;
    if (!granted) {
      return;
    }
    final token = await _channel.invokeMethod<String>('getDeviceToken');
    if (token != null) {
      _logToken(token);
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'deviceTokenChanged':
        final token = call.arguments;
        if (token is String) {
          _logToken(token);
        }
      case 'notificationReceived':
        // Nothing consumes remote-notification content yet: Client Push
        // already covers the live wake-up, and APNs has nowhere to register
        // a token. Left as a no-op instead of faking a handler for it.
        break;
      default:
        throw MissingPluginException('Unknown Apple push callback.');
    }
  }

  void _logToken(String token) {
    if (!kDebugMode) {
      return;
    }
    final preview = token.length > 8 ? '${token.substring(0, 8)}…' : token;
    // ignore: avoid_print
    print(
      'Apple push device token acquired ($preview, ${token.length} chars) '
      '— not registered anywhere, no proxy exists yet.',
    );
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
