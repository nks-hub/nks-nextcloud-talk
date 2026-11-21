part of 'call_media_session.dart';

const int _screenShareConnectionConcurrency = 4;

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
          await _runPeerTasks(_peers.keys, _announceShare);
        }
      } else {
        await _openShares(_peers.keys);
      }
      _publish();
    });
  }

  Future<void> _openShares(Iterable<String> peerIds) async {
    final pending = peerIds.toList(growable: false);
    var nextPeer = 0;
    Future<void> openNext() async {
      while (!_disposed && nextPeer < pending.length) {
        await _openShare(pending[nextPeer++]);
      }
    }

    final workerCount = pending.length < _screenShareConnectionConcurrency
        ? pending.length
        : _screenShareConnectionConcurrency;
    await Future.wait(List.generate(workerCount, (_) => openNext()));
  }

  /// One outgoing screen connection.
  ///
  /// Through an MCU there is exactly one, offered to this side's own session
  /// id the way the publisher is — the media server fans it out. In the mesh
  /// there is one per participant. [peerId] is the recipient either way.
  Future<void> _openShare(String peerId) async {
    final screen = _screen;
    if (_disposed || screen == null || _shares.containsKey(peerId)) {
      return;
    }
    final share = _MediaPeer(
      peerId,
      roomEpoch: _boundRoomEpoch!,
      roomType: CallMediaSession._screenRoomType,
      ownScreen: true,
    );
    _shares[peerId] = share;
    try {
      final connection = await _engine.createPeerConnection(
        iceServers: _iceServers,
        audio: null,
        video: screen,
        onIceCandidate: (candidate) => unawaited(
          _enqueue(() async {
            if (identical(_shares[peerId], share)) {
              await _sendCandidate(share, candidate);
            }
          }),
        ),
        onConnectionState: (state) => unawaited(
          _enqueue(() async {
            if (identical(_shares[peerId], share)) {
              share.state = state;
            }
          }),
        ),
        onRemoteVideo: (video) => unawaited(video?.dispose()),
      );
      if (!identical(_shares[peerId], share)) {
        await connection.close();
        return;
      }
      share.connection = connection;
      if (_disposed) return;
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

  /// A peer that misses the stop notification still sees the track end.
  Future<void> _stopSharing([CallResourceCleanup? cleanup]) async {
    final resources = cleanup ?? CallResourceCleanup();
    // Through an MCU the only share is the publish to this side's own
    // session, which tells the SERVER to drop the publisher; the other
    // participants hear nothing from it, so they are told separately.
    if (_mcu) {
      await _runPeerTasks(
        _peers.keys,
        (peerId) => _notifyUnshare(peerId, resources),
      );
    }
    final shares = _shares.values.toList(growable: false);
    _shares.clear();
    final screen = _screen;
    _screen = null;
    await _closeShares(shares, resources);
    await resources.run(screen?.dispose, label: 'screen capture');
  }

  Future<void> _notifyUnshare(
    String peerId,
    CallResourceCleanup cleanup, {
    _MediaPeer? share,
  }) => cleanup.run(
    () => _send(
      peerId: peerId,
      type: 'unshareScreen',
      payload: null,
      via: share,
      roomType: share == null ? CallMediaSession._screenRoomType : null,
    ),
    label: 'screen share notification',
  );

  Future<void> _closeShares(
    List<_MediaPeer> shares,
    CallResourceCleanup cleanup,
  ) async {
    var nextShare = 0;
    Future<void> closeNext() async {
      while (nextShare < shares.length) {
        final share = shares[nextShare++];
        await _notifyUnshare(share.peerId, cleanup, share: share);
        await cleanup.run(
          share.connection?.close,
          label: 'outgoing screen peer',
        );
      }
    }

    final workerCount = shares.length < _screenShareConnectionConcurrency
        ? shares.length
        : _screenShareConnectionConcurrency;
    await Future.wait(List.generate(workerCount, (_) => closeNext()));
  }

  Future<void> _closeShare(String peerId, CallResourceCleanup cleanup) =>
      cleanup.run(
        _shares.remove(peerId)?.connection?.close,
        label: 'outgoing screen peer',
      );

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
      screen = _MediaPeer(
        senderId,
        roomEpoch: _boundRoomEpoch!,
        roomType: CallMediaSession._screenRoomType,
      );
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
        if (!identical(_screens[senderId], opened)) {
          await connection.close();
          return;
        }
        opened.connection = connection;
        if (_disposed) return;
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

  Future<void> _closeScreen(
    String senderId, [
    CallResourceCleanup? cleanup,
  ]) async {
    final screen = _screens.remove(senderId);
    if (screen == null) {
      return;
    }
    await _closeMediaPeer(
      'incoming screen peer',
      screen,
      cleanup ?? CallResourceCleanup(),
    );
    if (!_disposed) {
      _publish();
    }
  }
}
