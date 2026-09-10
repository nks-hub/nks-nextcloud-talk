// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:talk_protocol/talk_protocol.dart';

import 'call_audio_interruptions.dart';
import 'call_media_engine.dart';
import 'call_signaling_session.dart';

part 'call_media_session_signaling.dart';
part 'call_media_session_screen.dart';
part 'call_media_session_controls.dart';
part 'call_media_session_state.dart';

/// Owns a room's media and serializes changes against its signalling epoch.
/// Mesh calls connect directly to peers; MCU calls use a publisher and
/// separate subscriptions. Both reuse the room's existing signalling transport.
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

    /// Called once the signalling has come back as a new session and every
    /// peer has been rebuilt against it. What the caller does with that is
    /// the caller's business — see the room epoch branch for why anything
    /// has to happen at all.
    void Function()? onSignalingRebuilt,
    this.reactionDisplay = const Duration(seconds: 4),
    this.renegotiationHold = const Duration(seconds: 45),
  }) : _initial = initial,
       _onSignalingRebuilt = onSignalingRebuilt,
       _updates = updates,
       _sendMessage = sendMessage,
       _sendControl = sendControl,
       _engine = engine,
       _interruptions = interruptions;

  final void Function()? _onSignalingRebuilt;

  /// How long an incoming reaction stays in the state before it clears.
  final Duration reactionDisplay;

  /// How long a call waits for the signalling to come back with a fresh
  /// authority before it gives up. Long enough to cover a lift, a tunnel or a
  /// hand-over between Wi-Fi and mobile data; short enough that a call which
  /// is really gone does not pretend otherwise.
  final Duration renegotiationHold;

  Timer? _renegotiationHold;

  /// Talk labels an audio/video peer connection `video` and a screen share
  /// `screen`; an audio-only call is still the `video` kind.
  static const _roomType = 'video';

  /// Screen connections use a separate room type and sid from camera/audio.
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
  final Map<String, Set<String>> _retiredSubscriberSids = {};
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

  /// Peers whose status channel currently says they are talking.
  final Set<String> _speakingPeers = <String>{};
  CallReaction? _reaction;
  Timer? _reactionTimer;
  CallLocalVideo? _video;
  final Map<String, SignalingParticipant> _participantsByPeer = {};
  CallMediaState _state = CallMediaState.idle;
  Future<void> _serial = Future<void>.value();
  int? _boundRoomEpoch;
  String? _boundLocalPeerId;
  bool _started = false;
  bool _disposed = false;
  Future<void>? _disposal;

  CallMediaState get state => _state;

  Stream<CallMediaState> get states => _states.stream;

  Future<void> setCameraEnabled(bool enabled) => _setCameraEnabled(enabled);

  Future<void> setScreenSharing(bool sharing, {CallScreenSource? source}) =>
      _setScreenSharing(sharing, source: source);

  Future<void> setMicrophoneMuted(bool muted) => _setMicrophoneMuted(muted);

  Future<void> setSpeakerphone(bool on) => _setSpeakerphone(on);

  Future<void> selectAudioRoute(CallAudioRoute route) =>
      _selectAudioRoute(route);

  Future<void> setHandRaised(bool raised) => _setHandRaised(raised);

  Future<void> sendReaction(String emoji) => _sendReaction(emoji);

  /// Opens the microphone and starts negotiating with everyone the server
  /// already reports as being in the call. Completes once the microphone
  /// question is settled, not once a peer is connected.
  Future<void> start() {
    return _enqueue(() async {
      if (_disposed || _started) {
        return;
      }
      _started = true;
      if (_initial.isTerminal || _initial.failure != null) {
        _emit(
          const CallMediaState(
            phase: CallMediaPhase.failed,
            error: CallMediaError.signalingLost,
          ),
        );
        return;
      }
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
    final disposal = _disposal;
    if (disposal != null) {
      return disposal;
    }
    // Pending capture must see Leave before its queued cleanup can run.
    _disposed = true;
    return _disposal = _enqueue(() async {
      await _routeChanges?.cancel();
      _routeChanges = null;
      _reactionTimer?.cancel();
      _renegotiationHold?.cancel();
      _renegotiationHold = null;
      await _subscription?.cancel();
      _subscription = null;
      await _stopMedia();
      _emit(CallMediaState.idle);
      await _states.close();
    });
  }

  /// Drops what the old session built and waits for the new one.
  ///
  /// Bounded, because waiting forever would be its own kind of lie: a
  /// signalling connection that never comes back means the call really is
  /// gone, and after [renegotiationHold] it says so exactly as it did before.
  Future<void> _holdForRenegotiation() async {
    await _closeAllPeers();
    _emit(const CallMediaState(phase: CallMediaPhase.preparing));
    _renegotiationHold ??= Timer(renegotiationHold, () {
      unawaited(
        _enqueue(() async {
          _renegotiationHold = null;
          await _failAndStop(CallMediaError.signalingLost);
        }),
      );
    });
  }

  Future<void> _apply(CallSignalingUpdate update) async {
    if (_disposed || _state.phase == CallMediaPhase.failed) {
      return;
    }
    if (update.failure != null || update.isTerminal) {
      await _failAndStop(CallMediaError.signalingLost);
      return;
    }
    // The runtime sets this when a reconnect, or a batch whose delivery was
    // unknown, left the peer state unreliable; while it is set the lane
    // refuses to carry SDP, so everything built against the old session is
    // worthless. It used to end the call here — measured on 6 September 2026
    // against the reference instance, eighteen seconds of airplane mode in an
    // MCU call cost the call, with "the call signalling ended" and a Join
    // button where the call had been.
    // It does not have to. A full hello opens a NEW room epoch, clears this
    // flag and carries no participants over, and the code below already
    // rebuilds every peer when the epoch changes. So this waits for that
    // instead: the peers go, the call says it is connecting, and the rebuild
    // happens when the fresh authority arrives.
    if (update.renegotiationRequired) {
      await _holdForRenegotiation();
      return;
    }
    if (update.topology == SignalingTopology.externalMcu &&
        _sendControl == null) {
      await _failAndStop(CallMediaError.topologyUnsupported);
      return;
    }
    _mcu = update.topology == SignalingTopology.externalMcu;
    if (!update.signalingReady || !update.roomConfirmed) {
      // The peers stay. A socket that is reconnecting keeps its room epoch
      // and this side's peer id, so nothing below would rebuild them — and
      // the other side saw no interruption at all, so it will not offer
      // again. Tearing them down here left a mesh call where this side is
      // not the offerer waiting for an offer that never comes, stuck in
      // "connecting" until the far end's ICE gave up. A drop that really
      // invalidates them arrives as a new epoch or as renegotiationRequired,
      // and both are handled above and below.
      _emit(const CallMediaState(phase: CallMediaPhase.preparing));
      return;
    }
    // Cancelled only once the signalling is actually usable again. A hello
    // clears `renegotiationRequired` before the room is confirmed, and
    // cancelling on that alone left a call with no deadline at all: if the
    // room join was then never confirmed it sat in "preparing" forever
    // instead of saying so after the hold's 45 seconds.
    _renegotiationHold?.cancel();
    _renegotiationHold = null;
    final localPeerId = update.localPeerId;
    _localPeerId = localPeerId?.value;
    if (localPeerId == null) {
      _emit(const CallMediaState(phase: CallMediaPhase.preparing));
      return;
    }
    // REST join can precede the first HPB room admission. Reasserting flags
    // after admission broadcasts call membership to that signaling identity.
    final bindingChanged =
        _boundRoomEpoch != update.roomEpoch ||
        _boundLocalPeerId != localPeerId.value;
    final rebuilt = _boundRoomEpoch != null && bindingChanged;
    if (rebuilt) {
      await _closeAllPeers();
    }
    _boundRoomEpoch = update.roomEpoch;
    _boundLocalPeerId = localPeerId.value;

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
    _retiredSubscriberSids.removeWhere(
      (peerId, _) => !expected.contains(peerId),
    );
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

    if (rebuilt ||
        (bindingChanged &&
            update.transport == SignalingTransportKind.externalHpb)) {
      _onSignalingRebuilt?.call();
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
          _enqueue(() async {
            if (identical(_peers[peer.peerId], peer)) {
              await _sendLocalCandidate(peer.peerId, candidate);
            }
          }),
        ),
        onConnectionState: (state) => unawaited(
          _enqueue(() async => _recordConnectionState(peer, state)),
        ),
        onRemoteVideo: (video) =>
            unawaited(_enqueue(() => _recordRemoteVideo(peer, video))),
        onStatusMessage: (type, payload) => unawaited(
          _enqueue(() async {
            if (identical(_peers[peer.peerId], peer)) {
              _receiveStatus(peer.peerId, type, payload);
            }
          }),
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
    _retiredSubscriberSids.clear();
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
    _speakingPeers.remove(peerId);
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
              speaking: _speakingPeers.contains(peer.peerId),
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
