// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A tapped push notification's routing target, straight from the account
/// whose key actually decrypted it — see `PushNotificationRouteStore.swift`.
/// Never reconstructed from a server host, which is ambiguous when two
/// signed-in accounts share one server. Mirrors Android's
/// `AndroidNotificationOpen`.
final class ApplePushNotificationOpen {
  const ApplePushNotificationOpen({
    required this.accountId,
    required this.roomToken,
  });

  final String accountId;
  final String roomToken;

  factory ApplePushNotificationOpen.fromMap(Map<Object?, Object?> map) {
    final accountId = map['accountId'];
    final roomToken = map['roomToken'];
    if (accountId is! String ||
        accountId.isEmpty ||
        roomToken is! String ||
        roomToken.isEmpty) {
      throw const FormatException('Native push notification open is invalid.');
    }
    return ApplePushNotificationOpen(
      accountId: accountId,
      roomToken: roomToken,
    );
  }

  @override
  String toString() =>
      'ApplePushNotificationOpen(accountId: <redacted>, roomToken: <redacted>)';
}

/// Bridges the native `com.nkshub.nextcloudtalk/apple_push` channel that
/// `AppDelegate.swift` exposes on iOS.
///
/// Asks for notification permission and hands every APNs device token it
/// receives to [onToken], which — once `nks-talk-notify` is registered
/// downstream — drives the push-v2 registration in
/// `push_registration_coordinator.dart`. This class itself never
/// registers anything; it only bridges the platform channel.
///
/// Also queues a tapped notification's [ApplePushNotificationOpen] (cold
/// start included, see [checkLaunchNotificationOpen]) and runs a tapped
/// Reply/Mark-as-read notification action via [onNotificationAction].
final class ApplePushCoordinator {
  ApplePushCoordinator({
    MethodChannel? channel,
    void Function(String)? onToken,
    Future<void> Function({
      required String kind,
      required String accountId,
      required String roomToken,
      String? replyText,
    })?
    onNotificationAction,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _onToken = onToken,
       _onNotificationAction = onNotificationAction {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/apple_push';

  final MethodChannel _channel;
  final void Function(String)? _onToken;
  final Future<void> Function({
    required String kind,
    required String accountId,
    required String roomToken,
    String? replyText,
  })?
  _onNotificationAction;
  bool _requested = false;

  final ListQueue<ApplePushNotificationOpen> _pendingOpens = ListQueue();
  final StreamController<void> _notificationOpenedController =
      StreamController<void>.broadcast();

  /// Fires whenever a newly queued notification open is ready to be taken.
  Stream<void> get notificationOpened => _notificationOpenedController.stream;

  ApplePushNotificationOpen? takeNextNotificationOpen() =>
      _pendingOpens.isEmpty ? null : _pendingOpens.removeFirst();

  /// Asks native for the notification that cold-launched the app, if any.
  /// Safe to call once at startup regardless of whether any account is
  /// signed in yet — the queue just holds it until a consumer drains it.
  Future<void> checkLaunchNotificationOpen() async {
    final Object? response;
    try {
      response = await _channel.invokeMethod<Object?>(
        'getLaunchNotificationOpen',
      );
    } on MissingPluginException {
      return;
    }
    if (response is Map<Object?, Object?>) {
      _queueOpen(response);
    }
  }

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
    final bool granted;
    try {
      granted = await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      // `UNErrorDomain 1` (notifications not allowed for this app) and a
      // simulator without a push entitlement both come back as a platform
      // error, not as `false`. Neither is something the app can act on beyond
      // running without push; the caller fires this and forgets it, so the
      // error must not reach the zone (fatal report on build 47).
      return;
    } on MissingPluginException {
      return;
    }
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
      case 'notificationOpened':
        final args = call.arguments;
        if (args is Map<Object?, Object?>) {
          _queueOpen(args);
        }
        return null;
      case 'notificationAction':
        // A tap on the Reply or Mark-as-read banner action — AppDelegate
        // waits for this to complete before it releases the OS's background
        // completion handler, so the reply/read actually lands before iOS
        // can suspend the app.
        final args = call.arguments as Map<Object?, Object?>?;
        final kind = args?['kind'] as String?;
        final accountId = args?['accountId'] as String?;
        final roomToken = args?['roomToken'] as String?;
        if (kind != null && accountId != null && roomToken != null) {
          await _onNotificationAction?.call(
            kind: kind,
            accountId: accountId,
            roomToken: roomToken,
            replyText: args?['replyText'] as String?,
          );
        }
        return null;
      default:
        throw MissingPluginException('Unknown Apple push callback.');
    }
  }

  void _queueOpen(Map<Object?, Object?> map) {
    try {
      _pendingOpens.add(ApplePushNotificationOpen.fromMap(map));
      _notificationOpenedController.add(null);
    } on FormatException {
      // Malformed native payload — nothing sane to route to.
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
    unawaited(_notificationOpenedController.close());
  }
}
