/// The platform's own call screen, whichever platform it is.
///
/// CallKit on iOS and Telecom on Android are different APIs that produce the
/// same two decisions — this call was answered, this call ended — and the app
/// answers both by joining or leaving the room the call belongs to. The shared
/// shape is what lets one binding serve both instead of two copies of the same
/// ownership bookkeeping.
library;

/// One call as the platform knows it.
abstract interface class SystemCallRing {
  /// The account whose room the call belongs to.
  String get accountId;
  String get roomToken;

  /// The platform's own identifier for the call. Handing it back to
  /// [SystemCallScreen.endCall] is what takes the system's record down.
  String get callId;
}

abstract interface class SystemCallScreen<T extends SystemCallRing> {
  /// The user took the call — from the system's UI, a headset, a car.
  Stream<T> get answered;

  /// The call ended outside the app: declined, hung up in the system's UI, or
  /// ended by the platform itself. Null when no single call is meant.
  Stream<T?> get ended;

  /// Takes the platform's record of [callId] down. Never throws: it runs from
  /// call teardown, which has to finish.
  Future<void> endCall(String callId);
}
