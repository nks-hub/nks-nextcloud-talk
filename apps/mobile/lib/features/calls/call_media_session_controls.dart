part of 'call_media_session.dart';

extension _CallMediaSessionControls on CallMediaSession {
  /// Turns this side's camera on or off for everyone in the call.
  ///
  /// The video line of every connection swaps its track and direction, then a
  /// new offer goes out: a track added after the first negotiation is not on
  /// the wire until the peer has answered again. A camera that cannot be
  /// opened leaves the call as it was — audio only.
  Future<void> _setCameraEnabled(bool enabled) {
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
  Future<void> _setMicrophoneMuted(bool muted) {
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
  Future<void> _setSpeakerphone(bool on) {
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
  Future<void> _selectAudioRoute(CallAudioRoute route) {
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

  /// Raises or lowers this participant's hand for everyone in the call.
  ///
  /// Talk's wire form, as the web client sends and reads it: a `raiseHand`
  /// message per recipient with `{"state": bool, "timestamp": ms}` as the
  /// payload. There is no acknowledgement and nothing to renegotiate.
  Future<void> _setHandRaised(bool raised) {
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
  ///
  /// The SAME fact also goes out as `audioOn`/`audioOff`/`videoOn`/`videoOff`
  /// on Talk's `status` data channel — the peer-to-peer side channel the web
  /// client keeps beside this very signalling message (confirmed from its
  /// `LocalStateBroadcaster`, which fires both from the same mute/unmute and
  /// camera on/off events). Both paths carry the same two facts; sending on
  /// both is what upstream itself does; sending on only one is the way a
  /// participant that never toggles anything again stays a muted avatar to a
  /// peer that missed, or does not read, the other one.
  Future<void> _announceMedia(String peerId) async {
    // Talk's status channel lives on the publisher under an MCU (which fans
    // the frame out to every subscriber) and on the peer's own connection in
    // the mesh; sending it once per recipient re-sends the same MCU frame,
    // which is harmless — every subscriber reads the same state either way.
    final statusConnection = (_mcu ? _publisher : _peers[peerId])?.connection;
    for (final (name, on) in [
      ('audio', !(_userMuted || _interrupted)),
      ('video', _video != null),
    ]) {
      statusConnection?.sendStatus('$name${on ? 'On' : 'Off'}');
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

  /// A peer's frame arriving on Talk's status data channel: exactly the six
  /// messages a live two-Chrome capture on 7 September 2026 ever saw the web
  /// client send on it, and nothing else (confirmed against
  /// `LocalStateBroadcaster.ts`/`webrtc.js` — raised hands and reactions
  /// arrive over the signalling connection instead, which this side already
  /// reads).
  ///
  /// `audioOn`/`audioOff` are the same fact the `mute`/`unmute` signalling
  /// message already carries, so both fold into [_peerAudioMuted].
  /// `speaking`/`stoppedSpeaking` have no other source in this app at all —
  /// folded into [_speakingPeers], read by [CallPeerState.speaking]; no
  /// widget shows it yet, which is as far as this stops.
  /// `videoOn`/`videoOff` have nothing further to update: this side already
  /// shows a peer's camera from the track itself (`onRemoteVideo`) rather
  /// than from a hint, so there is no separate "camera off" flag for it to
  /// feed.
  void _receiveStatus(String peerId, String type, Object? payload) {
    if (!_peers.containsKey(peerId)) {
      return;
    }
    final bool changed;
    switch (type) {
      case 'audioOn':
        changed = _peerAudioMuted.remove(peerId);
      case 'audioOff':
        changed = _peerAudioMuted.add(peerId);
      case 'speaking':
        changed = _speakingPeers.add(peerId);
      case 'stoppedSpeaking':
        changed = _speakingPeers.remove(peerId);
      default:
        return;
    }
    if (changed) {
      _publish();
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
  Future<void> _sendReaction(String emoji) {
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
}
