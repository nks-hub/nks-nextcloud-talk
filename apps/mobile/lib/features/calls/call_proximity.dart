import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Blanks the screen while the phone is at the ear during a call.
///
/// The decision of when to blank belongs to the platform: Android's
/// `PROXIMITY_SCREEN_OFF_WAKE_LOCK` turns the screen and the touchscreen off
/// while the sensor reports "near" and back on when it does not. This side only
/// says whether the call currently wants that behaviour at all — see
/// [callWantsProximityBlanking] — and releasing it always gives the screen
/// back.
abstract interface class CallProximityScreen {
  /// Whether this device can blank on proximity. A tablet usually cannot.
  Future<bool> supported();

  /// Hands the screen to the sensor. False when the platform refused.
  Future<bool> acquire();

  /// Gives the screen back. Safe when nothing is held.
  Future<void> release();
}

/// Whether the screen should follow the proximity sensor right now.
///
/// Only the earpiece is held against a face. Every other output means the phone
/// is being looked at or is not at the ear at all, and a picture — sent or
/// received — means the screen is the point of the call, so blanking it would
/// be wrong even on the earpiece.
bool callWantsProximityBlanking({
  required bool joined,
  required bool onEarpiece,
  required bool cameraOn,
  required bool screenSharing,
  required bool receivingVideo,
}) => joined && onEarpiece && !cameraOn && !screenSharing && !receivingVideo;

final callProximityScreenProvider = Provider<CallProximityScreen>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? const AndroidCallProximityScreen()
      : const NoCallProximityScreen(),
);

final class AndroidCallProximityScreen implements CallProximityScreen {
  const AndroidCallProximityScreen({
    MethodChannel channel = const MethodChannel(channelName),
  }) : this._(channel);

  const AndroidCallProximityScreen._(this._channel);

  static const channelName = 'com.nkshub.nextcloudtalk/call_proximity';
  final MethodChannel _channel;

  @override
  Future<bool> supported() => _ask('supported');

  @override
  Future<bool> acquire() => _ask('acquire');

  @override
  Future<void> release() => _ask('release');

  /// Nothing about the screen may reach the call.
  ///
  /// A missing plugin, a platform failure and a host with no channels at all
  /// mean the same thing here — the screen cannot be handed to a sensor — and
  /// the release runs from a call teardown, which has to finish. So every
  /// failure answers "no" instead of propagating.
  Future<bool> _ask(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on Object {
      return false;
    }
  }
}

/// No other platform puts its screen against a face.
final class NoCallProximityScreen implements CallProximityScreen {
  const NoCallProximityScreen();

  @override
  Future<bool> supported() async => false;

  @override
  Future<bool> acquire() async => false;

  @override
  Future<void> release() async {}
}

/// Keeps at most one proximity hold and knows when to stop asking.
///
/// A device that has no proximity sensor answers every request the same way,
/// so the first refusal is remembered and no further call is made: the state
/// this follows changes on every audio route change and every peer's video,
/// and a platform round trip per update for an answer that cannot change is
/// waste.
final class CallProximityHold {
  CallProximityHold(this._screen);

  final CallProximityScreen _screen;
  bool _held = false;
  bool _refused = false;

  /// Whether the screen is currently the sensor's to blank.
  bool get held => _held;

  Future<void> apply({required bool wanted}) async {
    if (wanted == _held || (wanted && _refused)) {
      return;
    }
    if (!wanted) {
      _held = false;
      await _screen.release();
      return;
    }
    _held = await _screen.acquire();
    _refused = !_held;
  }

  /// Gives the screen back for good — teardown, failure, disposal.
  Future<void> release() async {
    if (!_held) {
      return;
    }
    _held = false;
    await _screen.release();
  }
}
