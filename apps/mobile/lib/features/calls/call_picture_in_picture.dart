/// Keeps a call on screen as a small window when the user leaves the app.
///
/// The call screen arms this while it is showing and disarms it when it goes
/// away, so only a call ever shrinks into a window. The platform decides when
/// the window appears (the home gesture, a switch to another app) and tells
/// the screen through [active], which then draws just the participants.
library;

import 'dart:async';

import 'package:flutter/services.dart';

abstract interface class CallPictureInPicture {
  /// Whether leaving the app should shrink the call into a window. Answers
  /// whether the platform can do that at all.
  Future<bool> setAvailable(bool available);

  /// `true` while the call is shown as a small window.
  Stream<bool> get active;
}

/// The platform's window. Unavailable where no implementation is registered
/// — a desktop, a test — which is not a reason to fail a call.
final class PlatformCallPictureInPicture implements CallPictureInPicture {
  PlatformCallPictureInPicture({
    MethodChannel channel = const MethodChannel(channelName),
  }) : this._(channel);

  PlatformCallPictureInPicture._(this._channel) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/call_picture_in_picture';

  final MethodChannel _channel;
  final _active = StreamController<bool>.broadcast();

  @override
  Future<bool> setAvailable(bool available) async {
    try {
      return await _channel.invokeMethod<bool>('setAvailable', available) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Stream<bool> get active => _active.stream;

  Future<void> _onCall(MethodCall call) async {
    if (call.method == 'modeChanged') {
      _active.add(call.arguments == true);
    }
  }
}

/// Never shrinks. Used where a call runs without a platform behind it.
final class UnavailableCallPictureInPicture implements CallPictureInPicture {
  const UnavailableCallPictureInPicture();

  @override
  Future<bool> setAvailable(bool available) async => false;

  @override
  Stream<bool> get active => const Stream.empty();
}
