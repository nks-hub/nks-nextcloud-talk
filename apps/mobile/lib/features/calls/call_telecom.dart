import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'call_system_screen.dart';

/// One Talk call as Android's Telecom stack knows it.
final class CallTelecomCall implements SystemCallRing {
  const CallTelecomCall({
    required this.accountId,
    required this.roomToken,
    required this.callId,
  });

  static CallTelecomCall? fromMap(Map<Object?, Object?> map) {
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
    return CallTelecomCall(
      accountId: accountId,
      roomToken: roomToken,
      callId: callId,
    );
  }

  @override
  final String accountId;
  @override
  final String roomToken;
  @override
  final String callId;

  @override
  String toString() => 'CallTelecomCall(callId: $callId)';
}

/// Registers a joined call with the system's call lifecycle.
///
/// Android's supported route for an app that draws its own call screen is a
/// self-managed `ConnectionService` — see `CallTelecom.kt` for what that buys
/// and what it deliberately leaves alone. This side only decides when a call
/// exists and hears what the system did to it.
///
/// EVERY ANSWER IS ALLOWED TO BE "NO". A device below API 26, a ROM that
/// refuses the phone account, a platform failure and a host with no channels
/// at all mean the same thing: the call runs exactly as it did before Telecom
/// was involved. Nothing here may throw into a join or a teardown.
abstract interface class CallTelecom
    implements SystemCallScreen<CallTelecomCall> {
  /// Whether this device takes a self-managed call at all.
  Future<bool> supported();

  /// Tells the system this app has started a call. Null when it would not
  /// take it, in which case there is nothing to end later either.
  Future<CallTelecomCall?> startOutgoing({
    required String accountId,
    required String roomToken,
  });

  /// Tells the system a call is ringing for this app. Null when it would not
  /// take it; otherwise the user's answer arrives on [answered].
  Future<CallTelecomCall?> reportIncoming({
    required String accountId,
    required String roomToken,
  });
}

final class AndroidCallTelecom implements CallTelecom {
  AndroidCallTelecom({
    MethodChannel channel = const MethodChannel(channelName),
    String Function() newCallId = _uuid,
  }) : this._(channel, newCallId);

  AndroidCallTelecom._(this._channel, this._newCallId) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/call_telecom';

  static String _uuid() => const Uuid().v4();

  final MethodChannel _channel;
  final String Function() _newCallId;
  final _answered = StreamController<CallTelecomCall>.broadcast();
  final _ended = StreamController<CallTelecomCall?>.broadcast();

  @override
  Stream<CallTelecomCall> get answered => _answered.stream;

  @override
  Stream<CallTelecomCall?> get ended => _ended.stream;

  @override
  Future<bool> supported() async => await _ask('supported') ?? false;

  @override
  Future<CallTelecomCall?> startOutgoing({
    required String accountId,
    required String roomToken,
  }) => _place('startOutgoing', accountId: accountId, roomToken: roomToken);

  @override
  Future<CallTelecomCall?> reportIncoming({
    required String accountId,
    required String roomToken,
  }) => _place('reportIncoming', accountId: accountId, roomToken: roomToken);

  @override
  Future<void> endCall(String callId) async {
    await _ask('endCall', <String, Object?>{'callId': callId});
  }

  Future<CallTelecomCall?> _place(
    String method, {
    required String accountId,
    required String roomToken,
  }) async {
    final call = CallTelecomCall(
      accountId: accountId,
      roomToken: roomToken,
      callId: _newCallId(),
    );
    final placed = await _ask(method, <String, Object?>{
      'callId': call.callId,
      'accountId': accountId,
      'roomToken': roomToken,
    });
    return placed == true ? call : null;
  }

  /// Null rather than false where the platform could not answer, so a caller
  /// can tell "refused" from "not asked". Both mean no Telecom call.
  Future<bool?> _ask(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on Object {
      return null;
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    final map = arguments is Map<Object?, Object?>
        ? arguments
        : const <Object?, Object?>{};
    switch (call.method) {
      case 'telecomAnswered':
        final ring = CallTelecomCall.fromMap(map);
        if (ring != null) {
          _answered.add(ring);
        }
        return null;
      case 'telecomEnded':
        _ended.add(CallTelecomCall.fromMap(map));
        return null;
      case 'telecomShowIncomingUi':
        // A self-managed application has to show its own incoming-call screen
        // here, and this app has none yet. A ring nobody can see or answer
        // would sit in the system as a stuck call, so it is withdrawn instead
        // of left there. Written down as the open half of the TODO item.
        final ring = CallTelecomCall.fromMap(map);
        if (ring != null) {
          await endCall(ring.callId);
        }
        return null;
      default:
        throw MissingPluginException('Unknown Telecom callback.');
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_answered.close());
    unawaited(_ended.close());
  }
}

/// No other platform has Android's Telecom. iOS has CallKit, which is its own
/// channel; everything else has no system call lifecycle to join.
final class NoCallTelecom implements CallTelecom {
  const NoCallTelecom();

  @override
  Stream<CallTelecomCall> get answered => const Stream.empty();

  @override
  Stream<CallTelecomCall?> get ended => const Stream.empty();

  @override
  Future<bool> supported() async => false;

  @override
  Future<CallTelecomCall?> startOutgoing({
    required String accountId,
    required String roomToken,
  }) async => null;

  @override
  Future<CallTelecomCall?> reportIncoming({
    required String accountId,
    required String roomToken,
  }) async => null;

  @override
  Future<void> endCall(String callId) async {}
}
