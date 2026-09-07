part of 'call_media_session.dart';

enum CallMediaPhase {
  /// Nothing is running.
  idle,

  /// The microphone is being opened, or signalling is not ready yet.
  preparing,

  /// At least one peer connection exists and none of them is connected.
  negotiating,

  /// At least one peer connection reports a connected transport.
  connected,

  /// Media stopped and will not resume on its own.
  failed,
}

final class CallMediaState {
  const CallMediaState({
    required this.phase,
    this.error,
    this.connectedPeers = 0,
    this.peers = 0,
    this.muted = false,
    this.speakerphone = false,
    this.handRaised = false,
    this.raisedHands = 0,
    this.reaction,
    this.participants = const <CallPeerState>[],
    this.cameraOn = false,
    this.localVideo,
    this.screenSharing = false,
    this.audioRoutes = const <CallAudioRoute>[],
    this.audioRoute,
  });

  static const idle = CallMediaState(phase: CallMediaPhase.idle);

  final CallMediaPhase phase;
  final CallMediaError? error;
  final int connectedPeers;
  final int peers;

  /// The user's own mute, as shown on the control. A system interruption also
  /// closes the microphone but is not reported here: it is not the user's
  /// choice and it lifts on its own.
  final bool muted;

  /// Whether the audio goes to the loudspeaker. Off means the earpiece, the
  /// route a call starts on.
  final bool speakerphone;

  /// This participant's own raised hand.
  final bool handRaised;

  /// How many other participants have their hand up right now.
  final int raisedHands;

  /// The most recent reaction from another participant, shown for a moment
  /// and then gone — a reaction is a gesture, not a state.
  final CallReaction? reaction;

  /// Every other participant in the call, in the order they were seen.
  final List<CallPeerState> participants;

  /// Whether this side sends its camera, and the preview of it while it does.
  final bool cameraOn;
  final CallLocalVideo? localVideo;

  /// Whether this device's screen is going out to the call.
  final bool screenSharing;

  /// The outputs the platform offers right now, and the one the user picked
  /// from them (`null` until they pick — the platform's own default is then
  /// in effect, which [speakerphone] describes on a phone).
  final List<CallAudioRoute> audioRoutes;
  final CallAudioRoute? audioRoute;

  @override
  String toString() =>
      'CallMediaState(${phase.name}, peers: $connectedPeers/$peers, '
      'muted: $muted, speakerphone: $speakerphone, hand: $handRaised, '
      'raised: $raisedHands, reaction: ${reaction?.emoji}, '
      'error: ${error?.name})';
}

/// One other participant of the call as this side sees them.
final class CallPeerState {
  const CallPeerState({
    required this.peerId,
    required this.actorType,
    required this.actorId,
    required this.connected,
    required this.handRaised,
    required this.since,
    this.video,
    this.screen,
    this.audioMuted = false,
    this.speaking = false,
  });

  final String peerId;
  final String actorType;
  final String actorId;
  final bool connected;
  final bool handRaised;

  /// The peer's video while they send one; owned by the session.
  final CallRemoteVideo? video;

  /// The peer's shared screen while they share one; owned by the session.
  final CallRemoteVideo? screen;

  /// Whether the peer said their microphone is off (`mute {name: audio}`, or
  /// the `audioOff` twin on Talk's status data channel).
  final bool audioMuted;

  /// Whether the peer's status channel currently says they are talking
  /// (`speaking`/`stoppedSpeaking`). No UI reads this yet — see the call
  /// session notes for where wiring it stops.
  final bool speaking;

  /// When this side first saw the peer in the call. A peer still connecting
  /// long after that is most likely a departed session the server has not
  /// timed out yet (measured on 5 September 2026 after a browser re-joined).
  final DateTime since;
}

/// A reaction another participant sent into the call.
final class CallReaction {
  const CallReaction({required this.peerId, required this.emoji});

  final String peerId;
  final String emoji;
}
