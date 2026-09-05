// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:talk_protocol/talk_protocol.dart';

import 'call_audio_interruptions.dart';
import 'call_media_engine.dart';
import 'call_signaling_session.dart';

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

  @override
  String toString() =>
      'CallMediaState(${phase.name}, peers: $connectedPeers/$peers, '
      'muted: $muted, speakerphone: $speakerphone, hand: $handRaised, '
      'raised: $raisedHands, reaction: ${reaction?.emoji}, '
      'error: ${error?.name})';
}

/// A reaction another participant sent into the call.
final class CallReaction {
  const CallReaction({required this.peerId, required this.emoji});

  final String peerId;
  final String emoji;
}

/// Audio media for one room's call, driven by an existing signalling session.
///
/// It opens no transport of its own: offers, answers and candidates travel as
/// ordinary peer messages through the room's signalling session, so the lane,
/// the room epoch and the rule that a new session cancels the old one all
/// still hold. The topology is a peer-to-peer mesh — one connection per
/// participant who is in the call. An HPB that runs an MCU needs a
/// publisher/subscriber flow instead and is reported as unsupported rather
/// than attempted.
final class CallMediaSession {
  CallMediaSession({
    required CallSignalingUpdate initial,
    required Stream<CallSignalingUpdate> updates,
    required Future<bool> Function(SignalingPeerMessage message) sendMessage,
    required CallMediaEngine engine,
    CallAudioInterruptions interruptions = const SilentCallAudioInterruptions(),
    this.reactionDisplay = const Duration(seconds: 4),
  }) : _initial = initial,
       _updates = updates,
       _sendMessage = sendMessage,
       _engine = engine,
       _interruptions = interruptions;

  /// How long an incoming reaction stays in the state before it clears.
  final Duration reactionDisplay;

  /// Talk labels an audio/video peer connection `video` and a screen share
  /// `screen`; an audio-only call is still the `video` kind.
  static const _roomType = 'video';

  final CallSignalingUpdate _initial;
  final Stream<CallSignalingUpdate> _updates;
  final Future<bool> Function(SignalingPeerMessage message) _sendMessage;
  final CallMediaEngine _engine;
  final CallAudioInterruptions _interruptions;
  final Map<String, _MediaPeer> _peers = {};
  final StreamController<CallMediaState> _states =
      StreamController<CallMediaState>.broadcast(sync: true);

  StreamSubscription<CallSignalingUpdate>? _subscription;
  StreamSubscription<CallAudioInterruption>? _interruptionEvents;
  CallLocalAudio? _audio;
  bool _userMuted = false;
  bool _interrupted = false;
  bool _speakerphone = false;
  bool _handRaised = false;
  final Set<String> _raisedHands = <String>{};
  CallReaction? _reaction;
  Timer? _reactionTimer;
  CallMediaState _state = CallMediaState.idle;
  Future<void> _serial = Future<void>.value();
  int? _boundRoomEpoch;
  bool _started = false;
  bool _disposed = false;

  CallMediaState get state => _state;

  Stream<CallMediaState> get states => _states.stream;

  /// Opens the microphone and starts negotiating with everyone the server
  /// already reports as being in the call. Completes once the microphone
  /// question is settled, not once a peer is connected.
  Future<void> start() {
    return _enqueue(() async {
      if (_disposed || _started) {
        return;
      }
      _started = true;
      // Asked before the microphone is, so a call this client cannot join does
      // not raise a permission prompt for nothing.
      if (_initial.topology == SignalingTopology.externalMcu) {
        _emit(
          const CallMediaState(
            phase: CallMediaPhase.failed,
            error: CallMediaError.topologyUnsupported,
          ),
        );
        return;
      }
      _emit(const CallMediaState(phase: CallMediaPhase.preparing));
      // Armed before the microphone so an interruption that lands during the
      // permission prompt is not missed.
      _interruptionEvents = _interruptions.events.listen(_onInterruption);
      try {
        _audio = await _engine.openMicrophone();
      } on CallMediaException catch (error) {
        await _stopMedia();
        _emit(CallMediaState(phase: CallMediaPhase.failed, error: error.code));
        return;
      } on Object {
        await _stopMedia();
        _emit(
          const CallMediaState(
            phase: CallMediaPhase.failed,
            error: CallMediaError.microphoneUnavailable,
          ),
        );
        return;
      }
      if (_disposed) {
        await _stopMedia();
        return;
      }
      // An audio call starts on the earpiece. Measured on 5 September 2026:
      // the WebRTC plugin's own preference puts the loudspeaker ahead of the
      // earpiece and switched it on at every call start
      // (`setSpeakerphoneOn(true)` in `dumpsys audio`), which is the video
      // call convention, not the telephone one. The state above starts as
      // "off", so the route has to be made to match it.
      await _audio!.setSpeakerphone(_speakerphone);
      _subscription = _updates.listen(
        (update) => unawaited(_enqueue(() => _apply(update))),
        // The lane closes its stream when the room session is released or
        // replaced. No further update will arrive, so media that kept running
        // would show a call that has no signalling behind it any more.
        onDone: () => unawaited(
          _enqueue(() => _failAndStop(CallMediaError.signalingLost)),
        ),
      );
      await _apply(_initial);
    });
  }

  Future<void> dispose() {
    return _enqueue(() async {
      if (_disposed) {
        return;
      }
      _disposed = true;
      _reactionTimer?.cancel();
      await _subscription?.cancel();
      _subscription = null;
      await _stopMedia();
      _emit(CallMediaState.idle);
      await _states.close();
    });
  }

  Future<void> _apply(CallSignalingUpdate update) async {
    if (_disposed || _state.phase == CallMediaPhase.failed) {
      return;
    }
    if (update.failure != null) {
      await _failAndStop(CallMediaError.signalingLost);
      return;
    }
    // The runtime sets this when a reconnect or a possibly-sent batch made the
    // peer state unreliable, and it also refuses to carry SDP while it is set.
    // Media therefore cannot rebuild the mesh from here; stopping and saying so
    // is the only honest outcome.
    if (update.renegotiationRequired) {
      await _failAndStop(CallMediaError.signalingLost);
      return;
    }
    if (update.topology == SignalingTopology.externalMcu) {
      await _failAndStop(CallMediaError.topologyUnsupported);
      return;
    }
    if (!update.signalingReady || !update.roomConfirmed) {
      await _closeAllPeers();
      _emit(const CallMediaState(phase: CallMediaPhase.preparing));
      return;
    }
    final localPeerId = update.localPeerId;
    if (localPeerId == null) {
      _emit(const CallMediaState(phase: CallMediaPhase.preparing));
      return;
    }
    // A new room epoch means the relay stream restarted, so every peer
    // connection built against the previous one is stale.
    if (_boundRoomEpoch != null && _boundRoomEpoch != update.roomEpoch) {
      await _closeAllPeers();
    }
    _boundRoomEpoch = update.roomEpoch;

    final iceServers = update.iceServers
        .map(
          (server) => CallIceServer(
            urls: server.urls,
            username: server.username,
            credential: server.credential,
          ),
        )
        .toList(growable: false);

    final expected = <String>{
      for (final participant in update.participants)
        if (participant.inCall != 0 && participant.peerId != localPeerId)
          participant.peerId.value,
    };
    for (final gone in _peers.keys.toSet().difference(expected)) {
      await _closePeer(gone);
    }
    for (final peerId in expected) {
      if (_peers.containsKey(peerId)) {
        continue;
      }
      await _openPeer(
        peerId: peerId,
        localPeerId: localPeerId.value,
        iceServers: iceServers,
      );
    }

    for (final message in update.messages) {
      await _receive(
        message: message,
        localPeerId: localPeerId.value,
        iceServers: iceServers,
      );
    }
    _publish();
  }

  Future<void> _openPeer({
    required String peerId,
    required String localPeerId,
    required List<CallIceServer> iceServers,
  }) async {
    final peer = _MediaPeer(peerId);
    _peers[peerId] = peer;
    final connection = await _createConnection(peer, iceServers);
    if (connection == null) {
      return;
    }
    if (_handRaised) {
      // A hand raised before this participant arrived is otherwise invisible
      // to them: the web client only learns of a hand from the message.
      await _sendRaiseHand(peerId);
    }
    if (!_isOfferer(localPeerId: localPeerId, remotePeerId: peerId)) {
      return;
    }
    try {
      final offer = await connection.createOffer();
      await connection.setLocalDescription(offer);
      peer.localOfferPending = true;
      await _send(peerId: peerId, type: 'offer', payload: _sdpPayload(offer));
    } on CallMediaException {
      await _closePeer(peerId);
    }
  }

  /// Exactly one side of a pair offers, and both sides decide it from the same
  /// ordered pair of session ids. The comparison is only meaningful while both
  /// ids come from the same namespace, which is why [CallSignalingUpdate]
  /// derives the local one the same way the participant ids are derived.
  static bool _isOfferer({
    required String localPeerId,
    required String remotePeerId,
  }) => remotePeerId.compareTo(localPeerId) < 0;

  Future<CallPeerConnection?> _createConnection(
    _MediaPeer peer,
    List<CallIceServer> iceServers,
  ) async {
    final audio = _audio;
    if (audio == null) {
      return null;
    }
    try {
      final connection = await _engine.createPeerConnection(
        iceServers: iceServers,
        audio: audio,
        onIceCandidate: (candidate) => unawaited(
          _enqueue(() => _sendLocalCandidate(peer.peerId, candidate)),
        ),
        onConnectionState: (state) => unawaited(
          _enqueue(() async => _recordConnectionState(peer.peerId, state)),
        ),
      );
      if (_disposed || !identical(_peers[peer.peerId], peer)) {
        await connection.close();
        return null;
      }
      peer.connection = connection;
      return connection;
    } on CallMediaException {
      await _closePeer(peer.peerId);
      return null;
    }
  }

  Future<void> _receive({
    required SignalingPeerMessage message,
    required String localPeerId,
    required List<CallIceServer> iceServers,
  }) async {
    final sender = message.sender;
    if (sender == null ||
        sender.value == localPeerId ||
        (message.roomType.isNotEmpty && message.roomType != _roomType)) {
      return;
    }
    switch (message.type) {
      case 'offer':
        await _receiveOffer(
          senderId: sender.value,
          localPeerId: localPeerId,
          payload: message.payload,
          iceServers: iceServers,
        );
      case 'answer':
        await _receiveAnswer(senderId: sender.value, payload: message.payload);
      case 'candidate':
        await _receiveCandidate(
          senderId: sender.value,
          payload: message.payload,
        );
      case 'raiseHand':
        _receiveRaiseHand(senderId: sender.value, payload: message.payload);
      case 'reaction':
        _receiveReaction(senderId: sender.value, payload: message.payload);
      default:
        return;
    }
  }

  Future<void> _receiveOffer({
    required String senderId,
    required String localPeerId,
    required SignalingOpaquePayload? payload,
    required List<CallIceServer> iceServers,
  }) async {
    final sdp = _readSdp(payload, expectedType: 'offer');
    if (sdp == null) {
      return;
    }
    var peer = _peers[senderId];
    // Our own offer is still unanswered: only one side of a pair offers, so an
    // offer arriving here would be a role collision. Answering it as well
    // would leave both sides waiting.
    if (peer != null && peer.localOfferPending) {
      return;
    }
    if (peer == null) {
      // The server relays a peer message only from a current participant, so a
      // sender we have not listed yet is one whose participant event has not
      // arrived; building the connection now is what avoids losing the offer.
      peer = _MediaPeer(senderId);
      _peers[senderId] = peer;
      if (await _createConnection(peer, iceServers) == null) {
        return;
      }
    }
    final connection = peer.connection;
    if (connection == null) {
      return;
    }
    try {
      await connection.setRemoteDescription(sdp);
      peer.remoteDescriptionSet = true;
      await _drainRemoteCandidates(peer);
      final answer = await connection.createAnswer();
      await connection.setLocalDescription(answer);
      await _send(
        peerId: senderId,
        type: 'answer',
        payload: _sdpPayload(answer),
      );
    } on CallMediaException {
      await _closePeer(senderId);
    }
  }

  Future<void> _receiveAnswer({
    required String senderId,
    required SignalingOpaquePayload? payload,
  }) async {
    final peer = _peers[senderId];
    final connection = peer?.connection;
    if (peer == null || connection == null || !peer.localOfferPending) {
      return;
    }
    final sdp = _readSdp(payload, expectedType: 'answer');
    if (sdp == null) {
      return;
    }
    try {
      await connection.setRemoteDescription(sdp);
      peer.localOfferPending = false;
      peer.remoteDescriptionSet = true;
      await _drainRemoteCandidates(peer);
    } on CallMediaException {
      await _closePeer(senderId);
    }
  }

  Future<void> _receiveCandidate({
    required String senderId,
    required SignalingOpaquePayload? payload,
  }) async {
    final peer = _peers[senderId];
    if (peer == null) {
      return;
    }
    final candidate = _readCandidate(payload);
    if (candidate == null) {
      return;
    }
    // libwebrtc rejects a candidate before the remote description exists, and
    // candidates routinely overtake the answer, so they wait here instead.
    if (!peer.remoteDescriptionSet) {
      if (peer.pendingRemoteCandidates.length < _maximumPendingCandidates) {
        peer.pendingRemoteCandidates.add(candidate);
      }
      return;
    }
    final connection = peer.connection;
    if (connection == null) {
      return;
    }
    try {
      await connection.addIceCandidate(candidate);
    } on CallMediaException {
      // A candidate the engine refuses is one path out of many; the others can
      // still connect the call.
    }
  }

  Future<void> _drainRemoteCandidates(_MediaPeer peer) async {
    final connection = peer.connection;
    if (connection == null) {
      return;
    }
    final pending = List<CallIceCandidate>.of(peer.pendingRemoteCandidates);
    peer.pendingRemoteCandidates.clear();
    for (final candidate in pending) {
      try {
        await connection.addIceCandidate(candidate);
      } on CallMediaException {
        continue;
      }
    }
  }

  Future<void> _sendLocalCandidate(
    String peerId,
    CallIceCandidate candidate,
  ) async {
    if (_disposed || !_peers.containsKey(peerId)) {
      return;
    }
    await _send(
      peerId: peerId,
      type: 'candidate',
      payload: <String, Object?>{
        'candidate': <String, Object?>{
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      },
    );
  }

  /// Hands the microphone back for the length of a system interruption.
  ///
  /// Muting rather than closing: a closed track cannot be reopened without
  /// renegotiating with every peer, and an interruption is over in seconds.
  /// The call stays up throughout, which is what the other participants see.
  Future<void> _onInterruption(CallAudioInterruption event) async {
    _interrupted = event == CallAudioInterruption.began;
    await _applyMicrophone();
  }

  /// The user's mute control. Survives an interruption: a microphone the user
  /// closed stays closed when the system hands the audio back.
  Future<void> setMicrophoneMuted(bool muted) {
    return _enqueue(() async {
      if (_disposed || _userMuted == muted) {
        return;
      }
      _userMuted = muted;
      await _applyMicrophone();
      _publish();
    });
  }

  /// The user's speaker control.
  Future<void> setSpeakerphone(bool on) {
    return _enqueue(() async {
      final audio = _audio;
      if (_disposed || audio == null || _speakerphone == on) {
        return;
      }
      _speakerphone = on;
      await audio.setSpeakerphone(on);
      _publish();
    });
  }

  /// One place decides what the track does: closed if EITHER the user or the
  /// system wants it closed, open only when neither does.
  Future<void> _applyMicrophone() async {
    final audio = _audio;
    if (_disposed || audio == null) {
      return;
    }
    await audio.setMuted(_userMuted || _interrupted);
  }

  void _recordConnectionState(String peerId, CallMediaConnectionState state) {
    final peer = _peers[peerId];
    if (peer == null) {
      return;
    }
    peer.state = state;
    _publish();
  }

  Future<void> _send({
    required String peerId,
    required String type,
    required Map<String, Object?> payload,
  }) async {
    if (_disposed) {
      return;
    }
    final SignalingPeerMessage message;
    try {
      message = SignalingPeerMessage(
        type: type,
        roomType: _roomType,
        sid: null,
        recipient: SignalingPeerId.parse(peerId),
        sender: null,
        payload: SignalingOpaquePayload.fromJson(payload),
      );
    } on TalkProtocolException {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
    await _sendMessage(message);
  }

  Future<void> _failAndStop(CallMediaError error) async {
    await _stopMedia();
    _emit(CallMediaState(phase: CallMediaPhase.failed, error: error));
  }

  Future<void> _stopMedia() async {
    final interruptions = _interruptionEvents;
    _interruptionEvents = null;
    await interruptions?.cancel();
    await _closeAllPeers();
    final audio = _audio;
    _audio = null;
    await audio?.dispose();
  }

  Future<void> _closeAllPeers() async {
    for (final peerId in _peers.keys.toList(growable: false)) {
      await _closePeer(peerId);
    }
  }

  Future<void> _closePeer(String peerId) async {
    final peer = _peers.remove(peerId);
    _raisedHands.remove(peerId);
    await peer?.connection?.close();
  }

  /// Raises or lowers this participant's hand for everyone in the call.
  ///
  /// Talk's wire form, as the web client sends and reads it: a `raiseHand`
  /// message per recipient with `{"state": bool, "timestamp": ms}` as the
  /// payload. There is no acknowledgement and nothing to renegotiate.
  Future<void> setHandRaised(bool raised) {
    return _enqueue(() async {
      if (_disposed || _handRaised == raised) {
        return;
      }
      _handRaised = raised;
      for (final peerId in _peers.keys.toList(growable: false)) {
        await _sendRaiseHand(peerId);
      }
      _publish();
    });
  }

  Future<void> _sendRaiseHand(String peerId) async {
    try {
      await _send(
        peerId: peerId,
        type: 'raiseHand',
        payload: <String, Object?>{
          'state': _handRaised,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      );
    } on CallMediaException {
      // A hand that did not reach one peer is not a reason to end the call.
    }
  }

  /// Sends a reaction to everyone in the call. Talk's wire form, as the web
  /// client sends and reads it: a `reaction` message per recipient with
  /// `{"reaction": "👍"}`. Nothing is kept locally — it is the others' screens
  /// that show it.
  Future<void> sendReaction(String emoji) {
    return _enqueue(() async {
      if (_disposed || emoji.isEmpty) {
        return;
      }
      for (final peerId in _peers.keys.toList(growable: false)) {
        try {
          await _send(
            peerId: peerId,
            type: 'reaction',
            payload: <String, Object?>{'reaction': emoji},
          );
        } on CallMediaException {
          // A reaction that missed one peer is not a reason to end the call.
        }
      }
    });
  }

  void _receiveReaction({
    required String senderId,
    required SignalingOpaquePayload? payload,
  }) {
    final emoji = payload?.wire['reaction'];
    if (emoji is! String || emoji.isEmpty || emoji.length > 16) {
      return;
    }
    _reaction = CallReaction(peerId: senderId, emoji: emoji);
    _reactionTimer?.cancel();
    _reactionTimer = Timer(reactionDisplay, () {
      _reactionTimer = null;
      if (_disposed) {
        return;
      }
      _reaction = null;
      _publish();
    });
    _publish();
  }

  void _receiveRaiseHand({
    required String senderId,
    required SignalingOpaquePayload? payload,
  }) {
    final state = payload?.wire['state'];
    if (state is! bool) {
      return;
    }
    final changed = state
        ? _raisedHands.add(senderId)
        : _raisedHands.remove(senderId);
    if (changed) {
      _publish();
    }
  }

  void _publish() {
    if (_state.phase == CallMediaPhase.failed || _disposed) {
      return;
    }
    final connected = _peers.values
        .where((peer) => peer.state == CallMediaConnectionState.connected)
        .length;
    _emit(
      CallMediaState(
        phase: connected > 0
            ? CallMediaPhase.connected
            : (_peers.isEmpty
                  ? CallMediaPhase.preparing
                  : CallMediaPhase.negotiating),
        connectedPeers: connected,
        peers: _peers.length,
        muted: _userMuted,
        speakerphone: _speakerphone,
        handRaised: _handRaised,
        raisedHands: _raisedHands.length,
        reaction: _reaction,
      ),
    );
  }

  void _emit(CallMediaState state) {
    _state = state;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _serial = _serial.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

/// A peer's candidates may arrive before its description; the queue is bounded
/// so a peer that never describes itself cannot grow it without limit.
const _maximumPendingCandidates = 128;

final class _MediaPeer {
  _MediaPeer(this.peerId);

  final String peerId;
  CallPeerConnection? connection;
  bool localOfferPending = false;
  bool remoteDescriptionSet = false;
  CallMediaConnectionState state = CallMediaConnectionState.connecting;
  final List<CallIceCandidate> pendingRemoteCandidates = [];
}

Map<String, Object?> _sdpPayload(CallSessionDescription description) =>
    <String, Object?>{'type': description.type, 'sdp': description.sdp};

CallSessionDescription? _readSdp(
  SignalingOpaquePayload? payload, {
  required String expectedType,
}) {
  final wire = payload?.wire;
  if (wire == null) {
    return null;
  }
  final type = wire['type'];
  final sdp = wire['sdp'];
  if (sdp is! String || sdp.isEmpty) {
    return null;
  }
  if (type is String && type.isNotEmpty && type != expectedType) {
    return null;
  }
  return (type: expectedType, sdp: sdp);
}

CallIceCandidate? _readCandidate(SignalingOpaquePayload? payload) {
  final wire = payload?.wire['candidate'];
  if (wire is! Map<String, Object?>) {
    return null;
  }
  final candidate = wire['candidate'];
  if (candidate is! String || candidate.isEmpty) {
    return null;
  }
  final sdpMid = wire['sdpMid'];
  final sdpMLineIndex = wire['sdpMLineIndex'];
  return CallIceCandidate(
    candidate: candidate,
    sdpMid: sdpMid is String ? sdpMid : null,
    sdpMLineIndex: sdpMLineIndex is int ? sdpMLineIndex : null,
  );
}
