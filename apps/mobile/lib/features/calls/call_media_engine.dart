/// The slice of WebRTC the call layer uses, expressed without any plugin
/// type.
///
/// Everything above this file talks about offers, answers and candidates and
/// never about `flutter_webrtc`, so the negotiation logic can be tested
/// against a stub in a plain Dart test. The one production implementation
/// lives in `call_media_engine_webrtc.dart` and is the only file that imports
/// the plugin.
library;

import 'package:flutter/widgets.dart';

/// An SDP blob with its role. `type` is `offer` or `answer` exactly as it
/// travels on the wire.
typedef CallSessionDescription = ({String type, String sdp});

final class CallIceCandidate {
  const CallIceCandidate({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
  });

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  @override
  String toString() => 'CallIceCandidate(<redacted>)';
}

/// One STUN or TURN server as the room's signalling settings reported it.
final class CallIceServer {
  const CallIceServer({
    required this.urls,
    required this.username,
    required this.credential,
  });

  final List<String> urls;
  final String? username;
  final String? credential;

  @override
  String toString() => 'CallIceServer(<redacted>)';
}

/// The states this layer acts on. Everything libwebrtc reports beyond them
/// (`new`, `disconnected`) collapses into [connecting], because a call only
/// distinguishes "not yet", "yes", "no" and "gone".
enum CallMediaConnectionState { connecting, connected, failed, closed }

enum CallMediaError {
  /// The user refused the microphone, or the system has it blocked.
  microphonePermissionDenied,

  /// The permission is there but no audio track could be opened.
  microphoneUnavailable,

  /// A peer connection could not be built or negotiated.
  engineFailure,

  /// Signalling ended, or its session was replaced, while media were running.
  signalingLost,

  /// The user refused to share their screen.
  screenSharePermissionDenied,

  /// This device cannot capture its screen; nothing was shared.
  screenShareUnavailable,

  /// The user refused the camera, or the system has it blocked. Never fails
  /// the call: the call goes on without video.
  cameraPermissionDenied,

  /// The permission is there but no video track could be opened.
  cameraUnavailable,

  /// The room's signalling is an HPB with an MCU. A publisher/subscriber call
  /// is a separate piece of work; a mesh offer would be answered by nobody.
  topologyUnsupported,
}

final class CallMediaException implements Exception {
  const CallMediaException(this.code);

  final CallMediaError code;

  @override
  String toString() => 'CallMediaException(${code.name})';
}

/// The local microphone capture. Held for the whole call and closed once.
/// Where a call's audio can go. The kinds are the four a phone has; anything
/// the platform names that is none of them stays selectable under its label.
enum CallAudioRouteKind { speaker, earpiece, bluetooth, wiredHeadset, other }

/// One selectable audio output.
final class CallAudioRoute {
  const CallAudioRoute({
    required this.id,
    required this.label,
    required this.kind,
  });

  /// The platform's own id, handed back to select it.
  final String id;
  final String label;
  final CallAudioRouteKind kind;
}

abstract interface class CallLocalAudio {
  /// Stops or resumes capture without tearing the track down, so a call can
  /// give the microphone back to the system for the length of an interruption
  /// and pick it up again afterwards without renegotiating.
  Future<void> setMuted(bool muted);

  /// Routes the call's audio to the loudspeaker or back to the earpiece.
  ///
  /// A phone concept: the desktops have one output and take this as a no-op.
  Future<void> setSpeakerphone(bool on);

  /// The outputs available right now. Empty where the platform lists none.
  Future<List<CallAudioRoute>> routes();

  /// Sends the call's audio to one of [routes] — a Bluetooth headset, wired
  /// headphones, the loudspeaker, the earpiece.
  Future<void> selectRoute(CallAudioRoute route);

  /// Fires when an output appears or goes away (a headset plugged in, a
  /// Bluetooth device connecting), so [routes] is worth asking again.
  Stream<void> get routeChanges;

  Future<void> dispose();
}

/// Another participant's video as something the UI can show.
///
/// Only the engine knows the renderer behind it; the UI is handed a widget
/// and gives the object back with [dispose] when the peer is gone.
abstract interface class CallRemoteVideo {
  Widget build(BuildContext context);

  Future<void> dispose();
}

/// This side's camera: a track to send and a preview to show. Opened once
/// per call while the camera is on, handed to every peer connection.
abstract interface class CallLocalVideo {
  Widget buildPreview(BuildContext context);

  Future<void> dispose();
}

abstract interface class CallPeerConnection {
  /// Starts or stops sending this side's video on the connection's video
  /// line. The caller renegotiates afterwards; this only swaps the track.
  Future<void> setLocalVideo(CallLocalVideo? video);

  /// A fresh offer; with [iceRestart] it carries new ICE credentials so a
  /// connection whose transport died (a network change) can find a path again
  /// without being torn down.
  Future<CallSessionDescription> createOffer({bool iceRestart = false});

  Future<CallSessionDescription> createAnswer();

  Future<void> setLocalDescription(CallSessionDescription description);

  Future<void> setRemoteDescription(CallSessionDescription description);

  Future<void> addIceCandidate(CallIceCandidate candidate);

  Future<void> close();
}

abstract interface class CallMediaEngine {
  /// Opens the microphone, asking for the permission if the platform needs
  /// it. Throws [CallMediaException] with
  /// [CallMediaError.microphonePermissionDenied] on a refusal, so a refusal
  /// is a reported outcome and never a call that silently hangs.
  Future<CallLocalAudio> openMicrophone();

  /// Opens the front camera. Throws [CallMediaException] with
  /// [CallMediaError.cameraPermissionDenied] or
  /// [CallMediaError.cameraUnavailable]; the call is not affected either way.
  Future<CallLocalVideo> openCamera();

  /// Asks for the platform's screen-capture consent WITHOUT starting the
  /// capture, and answers whether it was given.
  ///
  /// Separate from [openScreen] because Android 14 puts a requirement of its
  /// own between the two: the foreground service that a capture needs may
  /// only start once the consent is in hand, and the capture may only start
  /// once that service runs. On a platform that asks for nothing, this is
  /// `true` and [openScreen] does the asking.
  Future<bool> requestScreenConsent();

  /// Opens this device's screen for sharing, reusing the consent above.
  /// Throws [CallMediaException] with
  /// [CallMediaError.screenSharePermissionDenied] or
  /// [CallMediaError.screenShareUnavailable].
  Future<CallLocalVideo> openScreen();

  /// A connection to one peer. With [audio] `null` it sends nothing and only
  /// receives — the shape of a screen share, which Talk carries on a second
  /// connection per participant (`roomType: screen`).
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio? audio,

    /// A picture the connection sends from the start, on a send-only video
    /// line: a screen share, which never receives one back.
    CallLocalVideo? video,

    /// Nothing comes back on this connection: an MCU publisher, which sends
    /// the microphone (and the camera when it is on) to the media server and
    /// receives every other participant on connections of their own.
    bool sendOnly = false,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,

    /// The peer's video arriving (a renderer ready to show) or going away
    /// (`null`). Every connection offers to receive video, so a participant
    /// who sends it is seen without any negotiation on this side.
    required void Function(CallRemoteVideo? video) onRemoteVideo,
  });
}
