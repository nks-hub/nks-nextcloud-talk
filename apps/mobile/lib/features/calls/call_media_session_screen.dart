part of 'call_media_session.dart';

extension _CallMediaSessionScreen on CallMediaSession {
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
  Future<void> _setScreenSharing(bool sharing, {CallScreenSource? source}) {
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
        screen = await _engine.openScreen(source: source);
      } on CallMediaException catch (error) {
        debugPrint('[call] screen share refused: ${error.code.name}');
        rethrow;
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
      roomType: CallMediaSession._screenRoomType,
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
        roomType: CallMediaSession._screenRoomType,
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
            roomType: CallMediaSession._screenRoomType,
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
      screen = _MediaPeer(senderId, roomType: CallMediaSession._screenRoomType);
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
}
