part of 'call_media_session.dart';

/// Both peers choose the offerer from the same session-id namespace.
bool _isOfferer({
  required String localPeerId,
  required String remotePeerId,
}) => remotePeerId.compareTo(localPeerId) < 0;

extension _CallMediaSessionSignaling on CallMediaSession {
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
        // Nothing meaningful arrives on the publish connection itself; this
        // side's own status frames go out on it, to every subscriber, via
        // _announceMedia below.
        onStatusMessage: (type, payload) {},
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
      final own = message.roomType == CallMediaSession._screenRoomType
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
    if (message.roomType == CallMediaSession._screenRoomType) {
      await _receiveScreen(
        senderId: sender.value,
        message: message,
        iceServers: iceServers,
      );
      return;
    }
    if (message.roomType.isNotEmpty &&
        message.roomType != CallMediaSession._roomType) {
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
        roomType: roomType ?? target?.roomType ?? CallMediaSession._roomType,
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
}
