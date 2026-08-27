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
///
/// Also answers `willPresent`'s foreground-banner question via
/// [shouldSuppressForegroundBanner] — see `ForegroundPushDeduplicator`.
final class ApplePushCoordinator {
  ApplePushCoordinator({
    MethodChannel? channel,
    void Function(String)? onToken,
    bool Function()? shouldSuppressForegroundBanner,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _onToken = onToken,
       _shouldSuppressForegroundBanner = shouldSuppressForegroundBanner {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/apple_push';

  final MethodChannel _channel;
  final void Function(String)? _onToken;
  final bool Function()? _shouldSuppressForegroundBanner;
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

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'deviceTokenChanged':
        final token = call.arguments;
        if (token is String) {
          _emitToken(token);
        }
        return null;
      case 'notificationReceived':
        // Nothing consumes remote-notification content yet: Client Push
        // already covers the live wake-up while there is no Notification
        // Service Extension to decrypt a background push's content. Left as
        // a no-op instead of faking a handler for it.
        return null;
      case 'shouldSuppressForegroundNotification':
        // AppDelegate asks this from `willPresent`, while the app is already
        // in the foreground — see ForegroundPushDeduplicator for why a
        // recent Client Push wake-up is grounds to suppress the banner.
        return _shouldSuppressForegroundBanner?.call() ?? false;
      default:
        throw MissingPluginException('Unknown Apple push callback.');
    }
  }

  void _emitToken(String token) {
    _logToken(token);
    _onToken?.call(token);
  }

  /// Reports that a token arrived without revealing any of it.
  ///
  /// Even a short prefix is a stable device fingerprint that survives across
  /// log files, so nothing derived from the token itself is printed — only
  /// that one arrived, and how long it was, which is what actually helps when
  /// a registration is rejected for its shape.
  void _logToken(String token) {
    if (!kDebugMode) {
      return;
    }
    // ignore: avoid_print
    print('Apple push device token acquired (${token.length} chars).');
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
