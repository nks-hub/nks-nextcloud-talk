/// Tells a call when the system has taken the audio away from it.
///
/// Measured on 5 September 2026 with a connected call and an incoming GSM call
/// on the emulator: Android reports `onAudioFocusChange(-2)`
/// (`AUDIOFOCUS_LOSS_TRANSIENT`) and the WebRTC audio carries on regardless —
/// the microphone kept capturing for the fourteen seconds the phone rang and
/// the other participants kept hearing the room. That is a privacy problem,
/// so the call has to hear about it.
///
/// THE LIFECYCLE IS THE WRONG SIGNAL for this and is deliberately not used.
/// The app already watches it through `WindowActivity`, but switching to
/// another app during a call must KEEP the call running, while losing audio
/// focus must mute it. Only the platform's own focus and interruption
/// notifications separate the two.
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// What the platform did to the call's audio.
enum CallAudioInterruption {
  /// The system took the audio away and will give it back — an incoming
  /// telephone call, an alarm. The call stays up and the microphone closes.
  began,

  /// The audio is ours again.
  ended,
}

abstract interface class CallAudioInterruptions {
  /// Interruptions for as long as the stream is listened to.
  Stream<CallAudioInterruption> get events;
}

/// Reads the platform's audio focus. Silent where no implementation is
/// registered: a platform that never interrupts is indistinguishable from one
/// that has not been taught to report it, and neither is a reason to fail a
/// call.
final class PlatformCallAudioInterruptions implements CallAudioInterruptions {
  const PlatformCallAudioInterruptions({
    EventChannel channel = const EventChannel(channelName),
  }) : this._(channel);

  const PlatformCallAudioInterruptions._(this._channel);

  static const channelName = 'com.nkshub.nextcloudtalk/call_audio_focus';

  final EventChannel _channel;

  @override
  Stream<CallAudioInterruption> get events => _channel
      .receiveBroadcastStream()
      .map(_parse)
      .where((event) => event != null)
      .cast<CallAudioInterruption>()
      .handleError(
        (Object _) {},
        test: (error) => error is MissingPluginException,
      );

  static CallAudioInterruption? _parse(Object? event) => switch (event) {
    'began' => CallAudioInterruption.began,
    'ended' => CallAudioInterruption.ended,
    _ => null,
  };
}

/// Never interrupts. Used where a call runs without a platform behind it.
final class SilentCallAudioInterruptions implements CallAudioInterruptions {
  const SilentCallAudioInterruptions();

  @override
  Stream<CallAudioInterruption> get events => const Stream.empty();
}
