/// The slice of WebRTC the call layer uses, expressed without any plugin
/// type.
///
/// Everything above this file talks about offers, answers and candidates and
/// never about `flutter_webrtc`, so the negotiation logic can be tested
/// against a stub in a plain Dart test. The one production implementation
/// lives in `call_media_engine_webrtc.dart` and is the only file that imports
/// the plugin.
library;

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
abstract interface class CallLocalAudio {
  Future<void> dispose();
}

abstract interface class CallPeerConnection {
  Future<CallSessionDescription> createOffer();

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

  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio audio,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
  });
}
