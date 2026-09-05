// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

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

  /// Whether the peer said their microphone is off (`mute {name: audio}`).
  final bool audioMuted;

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

    /// Control messages to the signalling server itself — `requestoffer` to
    /// an MCU. Absent on the internal transport, which has no server to ask.
    Future<bool> Function(HpbControlMessage control)? sendControl,
    CallAudioInterruptions interruptions = const SilentCallAudioInterruptions(),
    this.reactionDisplay = const Duration(seconds: 4),
  }) : _initial = initial,
       _updates = updates,
       _sendMessage = sendMessage,
       _sendControl = sendControl,
       _engine = engine,
       _interruptions = interruptions;

  /// How long an incoming reaction stays in the state before it clears.
  final Duration reactionDisplay;

  /// Talk labels an audio/video peer connection `video` and a screen share
  /// `screen`; an audio-only call is still the `video` kind.
  static const _roomType = 'video';

  /// Talk shares a screen on a SECOND connection per participant, whose
  /// messages carry `roomType: screen` and their own `sid`. This side only
  /// ever receives one: the sharer offers, we answer.
  static const _screenRoomType = 'screen';

  /// Screens arriving from other participants, one connection per sharer.
  final Map<String, _MediaPeer> _screens = <String, _MediaPeer>{};

  /// This side's screen going out, one connection per participant. Separate
  /// from [_screens] because two people can share at once, and then one peer
  /// has two screen connections that only their direction tells apart.
  final Map<String, _MediaPeer> _shares = <String, _MediaPeer>{};
  CallLocalVideo? _screen;
  List<CallIceServer> _iceServers = const <CallIceServer>[];
  List<CallAudioRoute> _audioRoutes = const <CallAudioRoute>[];
  CallAudioRoute? _audioRoute;

  /// This side's own session id, as the room lists it; a share names it as
  /// the broadcaster so the far side knows whose screen it is.
  String? _localPeerId;
  StreamSubscription<void>? _routeChanges;

  final CallSignalingUpdate _initial;
  final Stream<CallSignalingUpdate> _updates;
  final Future<bool> Function(SignalingPeerMessage message) _sendMessage;
  final Future<bool> Function(HpbControlMessage control)? _sendControl;

  /// With an MCU every stream goes through the media server: this side
  /// publishes ONCE, on a connection whose offer is addressed to its own
  /// session id, and every other participant arrives as an offer FROM their
  /// session id that the server makes on their behalf once it is asked with
  /// `requestoffer`. The mesh's "one side offers" rule does not apply.
  bool _mcu = false;
  _MediaPeer? _publisher;
  final Map<String, Timer> _offerRequests = <String, Timer>{};
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
  final Set<String> _peerAudioMuted = <String>{};
  CallReaction? _reaction;
  Timer? _reactionTimer;
  CallLocalVideo? _video;
  final Map<String, SignalingParticipant> _participantsByPeer = {};
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
      // An MCU needs the server to ask for offers on this side's behalf;
      // without that channel the call would only ever hear itself.
      if (_initial.topology == SignalingTopology.externalMcu &&
          _sendControl == null) {
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
        _routeChanges ??= _audio!.routeChanges.listen(
          (_) => unawaited(_enqueue(_refreshAudioRoutes)),
        );
        await _refreshAudioRoutes();
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
      await _routeChanges?.cancel();
      _routeChanges = null;
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
    if (update.topology == SignalingTopology.externalMcu &&
        _sendControl == null) {
      await _failAndStop(CallMediaError.topologyUnsupported);
      return;
    }
    _mcu = update.topology == SignalingTopology.externalMcu;
    if (!update.signalingReady || !update.roomConfirmed) {
      await _closeAllPeers();
      _emit(const CallMediaState(phase: CallMediaPhase.preparing));
      return;
    }
    final localPeerId = update.localPeerId;
    _localPeerId = localPeerId?.value;
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

    _iceServers = update.iceServers
        .map(
          (server) => CallIceServer(
            urls: server.urls,
            username: server.username,
            credential: server.credential,
          ),
        )
        .toList(growable: false);
    final iceServers = _iceServers;

    final expected = <String>{
      for (final participant in update.participants)
        if (participant.inCall != 0 && participant.peerId != localPeerId)
          participant.peerId.value,
    };
    _participantsByPeer
      ..clear()
      ..addEntries([
        for (final participant in update.participants)
          if (expected.contains(participant.peerId.value))
            MapEntry(participant.peerId.value, participant),
      ]);
    for (final gone in _peers.keys.toSet().difference(expected)) {
      await _closePeer(gone);
    }
    if (_mcu) {
      await _ensurePublisher(localPeerId.value, iceServers);
    }
    for (final peerId in expected) {
      if (_peers.containsKey(peerId)) {
        continue;
      }
      if (_mcu) {
        await _subscribe(peerId);
        // Someone who joins while the screen is up has to be told about it:
        // the one publisher already carries the picture, but the server does
        // not announce it to them by itself.
        if (_screen != null) {
          await _announceShare(peerId);
        }
        continue;
      }
      await _openPeer(
        peerId: peerId,
        localPeerId: localPeerId.value,
        iceServers: iceServers,
      );
      // Someone who joins while the screen is up gets it too. In the mesh
      // that means one more screen connection.
      await _openShare(peerId);
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

  /// The one connection that carries this side's media to the MCU. Offered
  /// to this side's own session id; the server answers from the same id.
  Future<void> _ensurePublisher(
    String localPeerId,
    List<CallIceServer> iceServers,
  ) async {
    if (_publisher != null || _audio == null) {
      return;
    }
    final publisher = _MediaPeer(localPeerId, publisher: true);
    _publisher = publisher;
    try {
      final connection = await _engine.createPeerConnection(
        iceServers: iceServers,
        audio: _audio,
        sendOnly: true,
        onIceCandidate: (candidate) =>
            unawaited(_enqueue(() => _sendCandidate(publisher, candidate))),
        onConnectionState: (state) => unawaited(
          _enqueue(() async {
            if (identical(_publisher, publisher)) {
              publisher.state = state;
              _publish();
              if (state == CallMediaConnectionState.failed) {
                await _offer(publisher, iceRestart: true);
              }
            }
          }),
        ),
        onRemoteVideo: (video) => unawaited(video?.dispose()),
      );
      if (_disposed || !identical(_publisher, publisher)) {
        await connection.close();
        return;
      }
      publisher.connection = connection;
      final video = _video;
      if (video != null) {
        try {
          await connection.setLocalVideo(video);
        } on CallMediaException {
          // Audio still publishes.
        }
      }
    } on CallMediaException {
      _publisher = null;
      return;
    }
    debugPrint('[call] publisher → $localPeerId sid=${publisher.sid}');
    await _offer(publisher);
  }

  /// Asks the MCU for the participant's stream. The server answers with an
  /// offer FROM that participant's session id, which the ordinary offer path
  /// then takes; until it does, the request is repeated every ten seconds,
  /// the way the web client does, because a participant who has not
  /// published yet is simply not there to be offered.
  Future<void> _subscribe(String peerId) async {
    if (_peers.containsKey(peerId)) {
      return;
    }
    _peers[peerId] = _MediaPeer(peerId);
    await _requestOffer(peerId);
    _offerRequests[peerId]?.cancel();
    _offerRequests[peerId] = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(
        _enqueue(() async {
          final peer = _peers[peerId];
          if (_disposed || peer == null || peer.connection != null) {
            _offerRequests.remove(peerId)?.cancel();
            return;
          }
          await _requestOffer(peerId);
        }),
      );
    });
  }

  /// Asks the MCU for a participant's stream.
  ///
  /// A PEER MESSAGE, not a control frame: the standalone signalling API
  /// carries `requestoffer` as `{"type":"message","message":{"recipient":…,
  /// "data":{"type":"requestoffer","sid":…,"roomType":"video"}}}`, and the
  /// server answers an offer only on that path. Sent as a control it was
  /// accepted far enough for the server to create a listener and no offer
  /// ever came back — measured against the reference cloud on 5 September
  /// 2026, with the web client's own request in the server log for contrast.
  /// The `sid` names the subscriber connection the offer belongs to.
  Future<void> _requestOffer(String peerId) async {
    final peer = _peers[peerId];
    if (peer == null) {
      return;
    }
    debugPrint('[call] requestoffer → $peerId sid=${peer.sid}');
    try {
      await _send(
        peerId: peerId,
        type: 'requestoffer',
        payload: null,
        via: peer,
      );
    } on CallMediaException {
      // Nothing to subscribe to under that id.
    }
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
    await _announceMedia(peerId);
    final video = _video;
    if (video != null) {
      // A camera already on rides in the very first offer to a newcomer.
      try {
        await connection.setLocalVideo(video);
      } on CallMediaException {
        // The newcomer simply does not get our video.
      }
    }
    if (!_isOfferer(localPeerId: localPeerId, remotePeerId: peerId)) {
      return;
    }
    await _offer(peer);
  }

  /// Creates and sends an offer on an existing connection — the first one,
  /// a renegotiation after the video line changed, or an ICE restart after
  /// the transport failed.
  Future<void> _offer(_MediaPeer peer, {bool iceRestart = false}) async {
    final connection = peer.connection;
    if (connection == null) {
      return;
    }
    try {
      final offer = await connection.createOffer(iceRestart: iceRestart);
      await connection.setLocalDescription(offer);
      peer.localOfferPending = true;
      debugPrint(
        '[call] offer → ${peer.peerId} sid=${peer.sid} '
        'video=${_video != null} iceRestart=$iceRestart '
        'lines=${_mediaLines(offer.sdp)}',
      );
      await _send(
        peerId: peer.peerId,
        type: 'offer',
        payload: _sdpPayload(offer),
        // The connection this offer belongs to decides its room type and
        // sid: a share and the call itself both offer to the same peer.
        via: peer,
      );
    } on CallMediaException {
      await _closePeer(peer.peerId);
    }
  }

  /// Turns this side's camera on or off for everyone in the call.
  ///
  /// The video line of every connection swaps its track and direction, then a
  /// new offer goes out: a track added after the first negotiation is not on
  /// the wire until the peer has answered again. A camera that cannot be
  /// opened leaves the call as it was — audio only.
  Future<void> setCameraEnabled(bool enabled) {
    return _enqueue(() async {
      if (_disposed || (enabled == (_video != null))) {
        return;
      }
      if (enabled) {
        try {
          _video = await _engine.openCamera();
        } on CallMediaException {
          return;
        }
      }
      final video = _video;
      if (!enabled) {
        _video = null;
      }
      final publisher = _publisher;
      for (final peer in <_MediaPeer>[
        ?publisher,
        if (!_mcu) ..._peers.values,
      ]) {
        final connection = peer.connection;
        if (connection == null) {
          continue;
        }
        try {
          await connection.setLocalVideo(enabled ? video : null);
        } on CallMediaException catch (error) {
          debugPrint(
            '[call] video line → ${peer.peerId} failed: ${error.code.name}',
          );
          continue;
        }
        // Glare guard: a peer whose offer of ours is still unanswered gets
        // the change with the next negotiation instead of a second offer.
        if (!peer.localOfferPending) {
          await _offer(peer);
        }
      }
      await _announceMediaToAll();
      if (!enabled) {
        await video?.dispose();
      }
      _publish();
    });
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
        // Through an MCU this side's microphone travels on the publisher
        // only; a participant's connection just listens.
        audio: _mcu ? null : audio,
        onIceCandidate: (candidate) => unawaited(
          _enqueue(() => _sendLocalCandidate(peer.peerId, candidate)),
        ),
        onConnectionState: (state) => unawaited(
          _enqueue(() async => _recordConnectionState(peer.peerId, state)),
        ),
        onRemoteVideo: (video) =>
            unawaited(_enqueue(() => _recordRemoteVideo(peer, video))),
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
    if (sender == null) {
      return;
    }
    if (sender.value == localPeerId) {
      // Only an MCU ever talks back from this side's own session id, and it
      // does so for BOTH of this side's publishes: the audio/video publisher
      // and the screen, which is published to the same own session id with
      // `roomType: screen`. Routing this by the publisher alone dropped every
      // screen answer without a word — the defect that made screen sharing
      // through the MCU look like a server that never answers (5 September
      // 2026); the server had answered all along.
      final own = message.roomType == _screenRoomType
          ? _shares[localPeerId]
          : _publisher;
      if (own == null || message.sid == null || message.sid != own.sid) {
        return;
      }
      switch (message.type) {
        case 'answer':
          await _receiveAnswerOn(own, message.payload);
        case 'candidate':
          await _receiveCandidateFor(own, message.payload);
        default:
          return;
      }
      return;
    }
    if (message.roomType == _screenRoomType) {
      await _receiveScreen(
        senderId: sender.value,
        message: message,
        iceServers: iceServers,
      );
      return;
    }
    if (message.roomType.isNotEmpty && message.roomType != _roomType) {
      return;
    }
    switch (message.type) {
      case 'offer':
        await _receiveOffer(
          senderId: sender.value,
          localPeerId: localPeerId,
          payload: message.payload,
          sid: message.sid,
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
      case 'unshareScreen':
        await _closeScreen(sender.value);
      case 'mute':
      case 'unmute':
        // The peer's own word on its microphone, the same message this side
        // sends; a video state travels as the track itself.
        if (message.payload?.wire['name'] == 'audio') {
          final changed = message.type == 'mute'
              ? _peerAudioMuted.add(sender.value)
              : _peerAudioMuted.remove(sender.value);
          if (changed) {
            _publish();
          }
        }
      default:
        return;
    }
  }

  Future<void> _receiveScreen({
    required String senderId,
    required SignalingPeerMessage message,
    required List<CallIceServer> iceServers,
  }) async {
    final share = _shares[senderId];
    final sid = message.sid;
    switch (message.type) {
      case 'offer':
        await _receiveScreenOffer(
          senderId: senderId,
          payload: message.payload,
          sid: sid,
          iceServers: iceServers,
        );
      case 'answer':
        // Only this side's own share is ever answered.
        await _receiveAnswerOn(share, message.payload);
      case 'candidate':
        // Two screen connections to one peer are told apart by sid: ours
        // carries the one this side named when it offered.
        final mine = share != null && sid != null && sid == share.sid;
        await _receiveCandidateFor(
          mine ? share : _screens[senderId],
          message.payload,
        );
      case 'unshareScreen':
        await _closeScreen(senderId);
      default:
        return;
    }
  }

  /// Starts or stops sharing this device's screen with everyone in the call.
  ///
  /// Talk carries a share as a second connection per participant, so this
  /// opens one per peer and offers on it; stopping sends the web client's own
  /// `unshareScreen` (which carries no payload) before closing them. A screen
  /// that cannot be opened leaves the call as it was.
  Future<void> setScreenSharing(bool sharing) {
    return _enqueue(() async {
      if (_disposed || sharing == (_screen != null)) {
        return;
      }
      if (!sharing) {
        await _stopSharing();
        _publish();
        return;
      }
      final CallLocalVideo screen;
      try {
        screen = await _engine.openScreen();
      } on CallMediaException catch (error) {
        debugPrint('[call] screen share refused: ${error.code.name}');
        return;
      }
      if (_disposed) {
        await screen.dispose();
        return;
      }
      _screen = screen;
      if (_mcu) {
        final localPeerId = _localPeerId;
        if (localPeerId != null) {
          await _openShare(localPeerId);
          for (final peerId in _peers.keys.toList(growable: false)) {
            await _announceShare(peerId);
          }
        }
      } else {
        for (final peerId in _peers.keys.toList(growable: false)) {
          await _openShare(peerId);
        }
      }
      _publish();
    });
  }

  /// One outgoing screen connection.
  ///
  /// Through an MCU there is exactly one, offered to this side's own session
  /// id the way the publisher is — the media server fans it out. In the mesh
  /// there is one per participant. [peerId] is the recipient either way.
  Future<void> _openShare(String peerId) async {
    final screen = _screen;
    if (screen == null || _shares.containsKey(peerId)) {
      return;
    }
    final share = _MediaPeer(
      peerId,
      roomType: _screenRoomType,
      ownScreen: true,
    );
    _shares[peerId] = share;
    try {
      final connection = await _engine.createPeerConnection(
        iceServers: _iceServers,
        audio: null,
        video: screen,
        onIceCandidate: (candidate) =>
            unawaited(_enqueue(() => _sendCandidate(share, candidate))),
        onConnectionState: (state) => unawaited(
          _enqueue(() async {
            if (identical(_shares[peerId], share)) {
              share.state = state;
            }
          }),
        ),
        onRemoteVideo: (video) => unawaited(video?.dispose()),
      );
      if (_disposed || !identical(_shares[peerId], share)) {
        await connection.close();
        return;
      }
      share.connection = connection;
    } on CallMediaException {
      _shares.remove(peerId);
      return;
    }
    debugPrint('[call] share → $peerId sid=${share.sid}');
    await _offer(share);
  }

  /// Tells one participant that this side is publishing a screen.
  ///
  /// Through an MCU the screen is published once, to this side's own session,
  /// and NOTHING tells the other participants it exists — the media server
  /// does not announce a publisher and there is no `requestoffer` they could
  /// know to send. The publisher has to push: `sendoffer` makes the server
  /// build a subscriber for that participant and hand them the offer. This is
  /// what talk-web does for the same reason, with the same note in its source
  /// (`sendOffer(sessionId, 'screen')`). Without it the publish succeeds and
  /// no one ever sees the screen.
  Future<void> _announceShare(String peerId) async {
    debugPrint('[call] sendoffer(screen) → $peerId');
    try {
      await _send(
        peerId: peerId,
        type: 'sendoffer',
        payload: null,
        roomType: _screenRoomType,
      );
    } on CallMediaException {
      // The participant left between the list and this message.
    }
  }

  /// Tells everyone the share is over and closes it. Quiet about a failure to
  /// send: the connections go either way, and a peer that missed the message
  /// sees the track end.
  Future<void> _stopSharing() async {
    // Through an MCU the only share is the publish to this side's own
    // session, which tells the SERVER to drop the publisher; the other
    // participants hear nothing from it, so they are told separately.
    if (_mcu) {
      for (final peerId in _peers.keys.toList(growable: false)) {
        try {
          await _send(
            peerId: peerId,
            type: 'unshareScreen',
            payload: null,
            roomType: _screenRoomType,
          );
        } on CallMediaException {
          // Nothing to do: their subscription ends with the track.
        }
      }
    }
    for (final share in _shares.values.toList(growable: false)) {
      try {
        await _send(
          peerId: share.peerId,
          type: 'unshareScreen',
          payload: null,
          via: share,
        );
      } on CallMediaException {
        // Nothing to do: the connection closes below regardless.
      }
      await share.connection?.close();
    }
    _shares.clear();
    final screen = _screen;
    _screen = null;
    await screen?.dispose();
  }

  /// A participant started sharing their screen: a receive-only connection of
  /// its own, answered on the sharer's sid. A second offer on a known screen
  /// (the sharer's ICE restart, or a new share) renegotiates it in place.
  Future<void> _receiveScreenOffer({
    required String senderId,
    required SignalingOpaquePayload? payload,
    required String? sid,
    required List<CallIceServer> iceServers,
  }) async {
    final sdp = _readSdp(payload, expectedType: 'offer');
    if (sdp == null) {
      return;
    }
    var screen = _screens[senderId];
    debugPrint(
      '[call] screen offer ← $senderId sid=$sid known=${screen != null} '
      'lines=${_mediaLines(sdp.sdp)}',
    );
    if (screen == null) {
      screen = _MediaPeer(senderId, roomType: _screenRoomType);
      _screens[senderId] = screen;
      final opened = screen;
      try {
        final connection = await _engine.createPeerConnection(
          iceServers: iceServers,
          audio: null,
          onIceCandidate: (candidate) =>
              unawaited(_enqueue(() => _sendCandidate(opened, candidate))),
          onConnectionState: (state) => unawaited(
            _enqueue(() async {
              if (identical(_screens[senderId], opened)) {
                opened.state = state;
                _publish();
              }
            }),
          ),
          onRemoteVideo: (video) =>
              unawaited(_enqueue(() => _recordScreenVideo(opened, video))),
        );
        if (_disposed || !identical(_screens[senderId], opened)) {
          await connection.close();
          return;
        }
        opened.connection = connection;
      } on CallMediaException {
        await _closeScreen(senderId);
        return;
      }
    }
    if (sid != null && sid.isNotEmpty) {
      screen.sid = sid;
    }
    final connection = screen.connection;
    if (connection == null) {
      return;
    }
    try {
      await connection.setRemoteDescription(sdp);
      screen.remoteDescriptionSet = true;
      await _drainRemoteCandidates(screen);
      final answer = await connection.createAnswer();
      await connection.setLocalDescription(answer);
      debugPrint(
        '[call] screen answer → $senderId sid=${screen.sid} '
        'lines=${_mediaLines(answer.sdp)}',
      );
      await _send(
        peerId: senderId,
        type: 'answer',
        payload: _sdpPayload(answer),
        via: screen,
      );
    } on CallMediaException {
      await _closeScreen(senderId);
    }
  }

  Future<void> _recordScreenVideo(
    _MediaPeer screen,
    CallRemoteVideo? video,
  ) async {
    if (_disposed || !identical(_screens[screen.peerId], screen)) {
      await video?.dispose();
      return;
    }
    final previous = screen.video;
    screen.video = video;
    await previous?.dispose();
    _publish();
  }

  Future<void> _closeScreen(String senderId) async {
    final screen = _screens.remove(senderId);
    if (screen == null) {
      return;
    }
    await screen.video?.dispose();
    screen.video = null;
    await screen.connection?.close();
    if (!_disposed) {
      _publish();
    }
  }

  Future<void> _receiveOffer({
    required String senderId,
    required String localPeerId,
    required SignalingOpaquePayload? payload,
    required String? sid,
    required List<CallIceServer> iceServers,
  }) async {
    final sdp = _readSdp(payload, expectedType: 'offer');
    if (sdp == null) {
      return;
    }
    var peer = _peers[senderId];
    debugPrint(
      '[call] offer ← $senderId sid=$sid known=${peer != null} '
      'pending=${peer?.localOfferPending} lines=${_mediaLines(sdp.sdp)}',
    );
    if (peer != null && sid != null && sid.isNotEmpty) {
      peer.sid = sid;
    }
    // Our own offer is still unanswered: only one side of a pair offers, so an
    // offer arriving here would be a role collision. Answering it as well
    // would leave both sides waiting.
    if (peer != null && peer.localOfferPending) {
      return;
    }
    if (peer != null && peer.connection == null) {
      // A subscriber the MCU is now offering: the connection is built for
      // the offer, and the request timer has done its job.
      _offerRequests.remove(senderId)?.cancel();
      if (await _createConnection(peer, iceServers) == null) {
        return;
      }
    }
    if (peer == null) {
      // The server relays a peer message only from a current participant, so a
      // sender we have not listed yet is one whose participant event has not
      // arrived; building the connection now is what avoids losing the offer.
      peer = _MediaPeer(senderId);
      if (sid != null && sid.isNotEmpty) {
        peer.sid = sid;
      }
      _peers[senderId] = peer;
      if (await _createConnection(peer, iceServers) == null) {
        return;
      }
      final video = _video;
      if (video != null) {
        // A camera already on rides in the answer, on the offered video line.
        try {
          await peer.connection?.setLocalVideo(video);
        } on CallMediaException {
          // This peer simply does not get our video.
        }
      }
      await _announceMedia(senderId);
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
      debugPrint(
        '[call] answer → $senderId sid=${peer.sid} lines=${_mediaLines(answer.sdp)}',
      );
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
  }) => _receiveAnswerOn(_peers[senderId], payload);

  Future<void> _receiveAnswerOn(
    _MediaPeer? peer,
    SignalingOpaquePayload? payload,
  ) async {
    final connection = peer?.connection;
    if (peer == null || connection == null || !peer.localOfferPending) {
      return;
    }
    final senderId = peer.peerId;
    final sdp = _readSdp(payload, expectedType: 'answer');
    if (sdp == null) {
      return;
    }
    debugPrint(
      '[call] answer ← $senderId sid=${peer.sid} lines=${_mediaLines(sdp.sdp)}',
    );
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
  }) => _receiveCandidateFor(_peers[senderId], payload);

  Future<void> _receiveCandidateFor(
    _MediaPeer? peer,
    SignalingOpaquePayload? payload,
  ) async {
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
    final peer = _peers[peerId];
    if (_disposed || peer == null) {
      return;
    }
    await _sendCandidate(peer, candidate);
  }

  Future<void> _sendCandidate(
    _MediaPeer via,
    CallIceCandidate candidate,
  ) async {
    if (_disposed) {
      return;
    }
    await _send(
      peerId: via.peerId,
      type: 'candidate',
      payload: <String, Object?>{
        'candidate': <String, Object?>{
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      },
      via: via,
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
    await _announceMediaToAll();
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
      await _announceMediaToAll();
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
      // The toggle speaks for itself; a picked route no longer does.
      _audioRoute = null;
      await audio.setSpeakerphone(on);
      _publish();
    });
  }

  /// Sends the call's audio to one of the outputs in
  /// [CallMediaState.audioRoutes] — the way to reach a Bluetooth headset or
  /// wired headphones, which the speaker toggle cannot name.
  Future<void> selectAudioRoute(CallAudioRoute route) {
    return _enqueue(() async {
      final audio = _audio;
      if (_disposed || audio == null) {
        return;
      }
      await audio.selectRoute(route);
      _audioRoute = route;
      _speakerphone = route.kind == CallAudioRouteKind.speaker;
      _publish();
    });
  }

  /// Asks the platform for its outputs again; a headset that was just
  /// plugged in shows up, one that was unplugged goes away, and a picked
  /// route that is gone is forgotten.
  Future<void> _refreshAudioRoutes() async {
    final audio = _audio;
    if (_disposed || audio == null) {
      return;
    }
    _audioRoutes = await audio.routes();
    debugPrint(
      '[call] audio routes: '
      '${_audioRoutes.map((route) => '${route.kind.name}:${route.id}').join(', ')}',
    );
    final picked = _audioRoute;
    if (picked != null && !_audioRoutes.any((route) => route.id == picked.id)) {
      _audioRoute = null;
    }
    _publish();
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

  Future<void> _recordConnectionState(
    String peerId,
    CallMediaConnectionState state,
  ) async {
    final peer = _peers[peerId];
    if (peer == null) {
      return;
    }
    final previous = peer.state;
    peer.state = state;
    _publish();
    // The transport died — measured on 5 September 2026 with ten seconds of
    // airplane mode during a connected call: ICE went disconnected → failed
    // and nothing offered again, so the call sat in "connecting" for good.
    // An ICE restart on the same connection (same sid, new credentials) is
    // what the web client answers; each new failure earns one more attempt.
    if (state == CallMediaConnectionState.failed &&
        previous != CallMediaConnectionState.failed &&
        peer.connection != null) {
      await _offer(peer, iceRestart: true);
    }
  }

  /// Sends to the peer's call connection, or — with [via] — on that
  /// connection's own room type and sid (a screen share).
  Future<void> _send({
    required String peerId,
    required String type,
    required Map<String, Object?>? payload,
    _MediaPeer? via,
    String? roomType,
  }) async {
    if (_disposed) {
      return;
    }
    final target = roomType == null ? via ?? _peers[peerId] : null;
    final SignalingPeerMessage message;
    try {
      message = SignalingPeerMessage(
        type: type,
        roomType: roomType ?? target?.roomType ?? _roomType,
        sid: target?.sid,
        // Every message of an outgoing share says whose screen it is, on
        // both transports: the mesh peer reads it to tell a remote screen
        // from a request to share its own, and talk-web sends it to an MCU
        // too (captured from its socket on 5 September 2026).
        broadcaster: target != null && target.ownScreen ? _localPeerId : null,
        recipient: SignalingPeerId.parse(peerId),
        sender: null,
        payload: payload == null
            ? null
            : SignalingOpaquePayload.fromJson(payload),
      );
    } on TalkProtocolException {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
    if (!await _sendMessage(message)) {
      debugPrint('[call] send refused: $type → $peerId (${message.roomType})');
    }
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
    final video = _video;
    _video = null;
    await video?.dispose();
    final audio = _audio;
    _audio = null;
    await audio?.dispose();
  }

  Future<void> _closeAllPeers() async {
    await _stopSharing();
    for (final peerId in _peers.keys.toList(growable: false)) {
      await _closePeer(peerId);
    }
    final publisher = _publisher;
    _publisher = null;
    await publisher?.connection?.close();
  }

  Future<void> _closePeer(String peerId) async {
    _offerRequests.remove(peerId)?.cancel();
    await _closeScreen(peerId);
    final share = _shares.remove(peerId);
    await share?.connection?.close();
    final peer = _peers.remove(peerId);
    _raisedHands.remove(peerId);
    _peerAudioMuted.remove(peerId);
    await peer?.video?.dispose();
    peer?.video = null;
    await peer?.connection?.close();
  }

  /// A renderer that arrives for a peer already gone is disposed on the
  /// spot; otherwise it replaces the previous one and the UI is told.
  Future<void> _recordRemoteVideo(
    _MediaPeer peer,
    CallRemoteVideo? video,
  ) async {
    if (_disposed || !identical(_peers[peer.peerId], peer)) {
      await video?.dispose();
      return;
    }
    final previous = peer.video;
    peer.video = video;
    await previous?.dispose();
    _publish();
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

  /// Tells one peer whether this side's audio and video are on.
  ///
  /// The web client shows a participant's microphone as muted and their
  /// camera as off until a `unmute`/`mute` message with `{name}` says
  /// otherwise (measured on 5 September 2026: our tile carried the crossed
  /// microphone with audio flowing, and a camera turned on stayed an avatar
  /// until this message was sent). Sent when a peer appears and on every
  /// change; a system interruption counts as muted, like the track it closes.
  Future<void> _announceMedia(String peerId) async {
    for (final (name, on) in [
      ('audio', !(_userMuted || _interrupted)),
      ('video', _video != null),
    ]) {
      try {
        await _send(
          peerId: peerId,
          type: on ? 'unmute' : 'mute',
          payload: <String, Object?>{'name': name},
        );
      } on CallMediaException {
        // The state rides along with the next change instead.
      }
    }
  }

  Future<void> _announceMediaToAll() async {
    for (final peerId in _peers.keys.toList(growable: false)) {
      await _announceMedia(peerId);
    }
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
        cameraOn: _video != null,
        localVideo: _video,
        screenSharing: _screen != null,
        audioRoutes: _audioRoutes,
        audioRoute: _audioRoute,
        participants: [
          for (final peer in _peers.values)
            CallPeerState(
              peerId: peer.peerId,
              actorType: _participantsByPeer[peer.peerId]?.actorType ?? '',
              actorId: _participantsByPeer[peer.peerId]?.actorId ?? '',
              connected: peer.state == CallMediaConnectionState.connected,
              handRaised: _raisedHands.contains(peer.peerId),
              since: peer.openedAt,
              video: peer.video,
              screen: _screens[peer.peerId]?.video,
              audioMuted: _peerAudioMuted.contains(peer.peerId),
            ),
        ],
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
  _MediaPeer(
    this.peerId, {
    this.roomType = CallMediaSession._roomType,
    this.ownScreen = false,
    this.publisher = false,
  });

  /// The connection that carries this side's media to an MCU.
  final bool publisher;

  final String peerId;

  /// `video` for the call itself, `screen` for a shared screen.
  final String roomType;

  /// A screen connection carrying THIS side's screen out, as opposed to one
  /// bringing a participant's screen in.
  final bool ownScreen;
  final DateTime openedAt = DateTime.now();

  /// The web client pairs every message with a peer connection by `sid`: an
  /// offer whose `sid` matches no known one creates a NEW connection, and a
  /// later message is dropped when its `sid` differs. So this side echoes the
  /// `sid` of the offer it received, or names one of its own when it offers
  /// first, and puts it on every message to the peer (measured on 5 September
  /// 2026: a camera renegotiation with `sid: null` went to a fresh connection
  /// the web never showed).
  String sid = _nextSid();

  /// Unique per connection, not merely per moment: a share and the call
  /// itself are two connections to the same peer opened in the same
  /// microsecond, and the web client tells them apart by sid alone.
  static int _sidCounter = 0;
  static String _nextSid() =>
      '${DateTime.now().microsecondsSinceEpoch}${_sidCounter++}';
  CallPeerConnection? connection;
  CallRemoteVideo? video;
  bool localOfferPending = false;
  bool remoteDescriptionSet = false;
  CallMediaConnectionState state = CallMediaConnectionState.connecting;
  final List<CallIceCandidate> pendingRemoteCandidates = [];
}

/// The media lines and their directions, the only part of an SDP worth a log
/// line: `audio:sendrecv,video:recvonly`.
String _mediaLines(String sdp) {
  final out = <String>[];
  String? kind;
  String? direction;
  var msid = false;
  void flush() {
    if (kind != null && direction != null) {
      out.add('$kind:$direction${msid ? '+msid' : ''}');
    }
    kind = null;
    direction = null;
    msid = false;
  }

  for (final raw in sdp.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('m=')) {
      flush();
      kind = line.substring(2).split(' ').first;
    } else if (line.startsWith('a=msid:')) {
      // Whether the line names a stream: a track without one reaches the web
      // client as a track nobody attaches to a participant.
      msid = true;
    } else if (line == 'a=sendrecv' ||
        line == 'a=sendonly' ||
        line == 'a=recvonly' ||
        line == 'a=inactive') {
      direction = line.substring(2);
    }
  }
  flush();
  return out.join(',');
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
