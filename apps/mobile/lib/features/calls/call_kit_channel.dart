// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/services.dart';

/// The call a ring in the system's call UI stands for.
final class CallKitRing {
  const CallKitRing({
    required this.accountId,
    required this.roomToken,
    required this.callId,
  });

  final String accountId;
  final String roomToken;

  /// The UUID CallKit knows this call by. Handing it back to [CallKitChannel.
  /// endCall] is what takes the system's call screen down.
  final String callId;

  static CallKitRing? fromMap(Map<Object?, Object?> map) {
    final accountId = map['accountId'];
    final roomToken = map['roomToken'];
    final callId = map['callId'];
    if (accountId is! String ||
        accountId.isEmpty ||
        roomToken is! String ||
        roomToken.isEmpty ||
        callId is! String ||
        callId.isEmpty) {
      return null;
    }
    return CallKitRing(
      accountId: accountId,
      roomToken: roomToken,
      callId: callId,
    );
  }

  @override
  String toString() => 'CallKitRing(callId: $callId)';
}

/// Bridges `CallPushKit.swift` — the PushKit device token and the two
/// decisions the system call screen can produce.
///
/// A VoIP push wakes even a terminated app, so the ring is reported natively
/// and this side only hears the outcome: [answered] when the user took the
/// call, [ended] when they declined it or hung up from the system UI. The
/// token goes to the push registration, which is the only thing that makes
/// the proxy send a VoIP push at all.
///
/// Every platform but iOS answers `MissingPluginException`, which this
/// treats as "no CallKit here" rather than as a failure.
final class CallKitChannel {
  CallKitChannel({MethodChannel? channel, void Function(String)? onVoipToken})
    : _channel = channel ?? const MethodChannel(channelName),
      _onVoipToken = onVoipToken {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/call_kit';

  final MethodChannel _channel;
  final void Function(String)? _onVoipToken;
  final StreamController<CallKitRing> _answered =
      StreamController<CallKitRing>.broadcast();
  final StreamController<CallKitRing?> _ended =
      StreamController<CallKitRing?>.broadcast();

  /// The user accepted a ringing call; the room is theirs to join.
  Stream<CallKitRing> get answered => _answered.stream;

  /// The user declined a ringing call, or ended a joined one from the system
  /// UI. Null when the system reset its provider and no single call is meant.
  Stream<CallKitRing?> get ended => _ended.stream;

  /// Collects the token that arrived before this side existed. Safe to call
  /// on every platform and at any point in the launch.
  Future<void> checkLaunchVoipToken() async {
    final String? token;
    try {
      token = await _channel.invokeMethod<String>('getVoipToken');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    if (token != null && token.isNotEmpty) {
      _onVoipToken?.call(token);
    }
  }

  /// Takes the system call screen down for [callId] — the call ended
  /// somewhere else, or this side left it.
  Future<void> endCall(String callId) async {
    try {
      await _channel.invokeMethod<void>('endCall', <String, Object?>{
        'callId': callId,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    final map = arguments is Map<Object?, Object?>
        ? arguments
        : const <Object?, Object?>{};
    switch (call.method) {
      case 'voipTokenChanged':
        final token = map['token'];
        if (token is String && token.isNotEmpty) {
          _onVoipToken?.call(token);
        }
        return null;
      case 'callAnswered':
        final ring = CallKitRing.fromMap(map);
        if (ring != null) {
          _answered.add(ring);
        }
        return null;
      case 'callEnded':
        _ended.add(CallKitRing.fromMap(map));
        return null;
      default:
        throw MissingPluginException('Unknown CallKit callback.');
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_answered.close());
    unawaited(_ended.close());
  }
}
