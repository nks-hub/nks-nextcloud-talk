// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges the native `com.nkshub.nextcloudtalk/apple_push` channel that
/// `AppDelegate.swift` exposes on iOS.
///
/// Asks for notification permission and hands every APNs device token it
/// receives to [onToken], which — once `nks-talk-notify` is registered
/// downstream — drives the push-v2 registration in
/// `apple_push_registration_coordinator.dart`. This class itself never
/// registers anything; it only bridges the platform channel.
final class ApplePushCoordinator {
  ApplePushCoordinator({MethodChannel? channel, void Function(String)? onToken})
    : _channel = channel ?? const MethodChannel(channelName),
      _onToken = onToken {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/apple_push';

  final MethodChannel _channel;
  final void Function(String)? _onToken;
  bool _requested = false;

  /// Asks the user for notification permission once per app session and
  /// forwards whatever device token APNs hands back.
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
      _emitToken(token);
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'deviceTokenChanged':
        final token = call.arguments;
        if (token is String) {
          _emitToken(token);
        }
      case 'notificationReceived':
        // Nothing consumes remote-notification content yet: Client Push
        // already covers the live wake-up while there is no Notification
        // Service Extension to decrypt a background push's content. Left as
        // a no-op instead of faking a handler for it.
        break;
      default:
        throw MissingPluginException('Unknown Apple push callback.');
    }
  }

  void _emitToken(String token) {
    _logToken(token);
    _onToken?.call(token);
  }

  void _logToken(String token) {
    if (!kDebugMode) {
      return;
    }
    final preview = token.length > 8 ? '${token.substring(0, 8)}…' : token;
    // ignore: avoid_print
    print(
      'Apple push device token acquired ($preview, ${token.length} chars).',
    );
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
