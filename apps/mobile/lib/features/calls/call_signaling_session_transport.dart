part of 'call_signaling_session.dart';

extension _CallSignalingLaneTransport on _CallSignalingLane {
  void _executeEffect(SignalingEffect effect) {
    switch (effect) {
      case final OpenHpbSocketEffect open:
        _dispatchSocketOpen(open);
      case final SendHpbFrameEffect send:
        _dispatchSocketSend(send);
      case final CloseHpbSocketEffect close:
        _dispatchSocketClose(close);
      case ScheduleSignalingDeadlineEffect():
        return;
      case final RefreshConversationSessionEffect refresh:
        _dispatchRoomRefresh(refresh);
    }
  }

  void _dispatchSocketOpen(OpenHpbSocketEffect effect) {
    unawaited(
      socketConnector
          .connect(effect.endpoint)
          .then((socket) {
            return _enqueue(() => _completeSocketOpen(effect, socket));
          })
          .catchError((Object _, StackTrace _) {
            return _enqueue(
              () => _recordSocketDisconnect(
                effect.context.connectionEpoch,
                outboundPossiblySent: false,
              ),
            );
          }),
    );
  }

  Future<void> _completeSocketOpen(
    OpenHpbSocketEffect effect,
    HpbSocketConnection socket,
  ) async {
    if (_disposed || _failed || !identical(_state.pendingSocketOpen, effect)) {
      await socket.close(HpbCloseReason.staleConnection);
      return;
    }
    await _socketSubscription?.cancel();
    _socket = socket;
    _socketEpoch = effect.context.connectionEpoch;
    _handledDisconnectEpoch = null;
    _peerFramePossiblySent = false;
    _socketSubscription = socket.frames.listen(
      (frame) => unawaited(
        _enqueue(
          () => _applySocketFrame(effect.context.connectionEpoch, frame),
        ),
      ),
      onError: (_, _) => unawaited(
        _enqueue(
          () => _recordSocketDisconnect(
            effect.context.connectionEpoch,
            outboundPossiblySent: _peerFramePossiblySent,
          ),
        ),
      ),
      onDone: () => unawaited(
        _enqueue(
          () => _recordSocketDisconnect(
            effect.context.connectionEpoch,
            outboundPossiblySent: _peerFramePossiblySent,
          ),
        ),
      ),
      cancelOnError: false,
    );
    final result = completeHpbSocketOpen(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      effect: effect,
      deadlineEffectId: _effectId(),
      nowMicros: nowMicros(),
    );
    if (result.canCommit) {
      await _commit(result);
    }
  }

  void _dispatchSocketSend(SendHpbFrameEffect effect) {
    final socket = _socket;
    if (socket == null || _socketEpoch != effect.context.connectionEpoch) {
      unawaited(
        _enqueue(
          () => _recordSocketDisconnect(
            effect.context.connectionEpoch,
            outboundPossiblySent: false,
          ),
        ),
      );
      return;
    }
    final peerFrame =
        effect.frame is HpbMessageClientFrame ||
        effect.frame is HpbControlClientFrame;
    unawaited(() async {
      try {
        await socket.send(effect.frame.encode());
      } on Object {
        await _enqueue(
          () => _recordSocketDisconnect(
            effect.context.connectionEpoch,
            outboundPossiblySent: peerFrame,
          ),
        );
        return;
      }
      await _enqueue(() async {
        if (peerFrame) {
          _peerFramePossiblySent = true;
        }
        final result = completeHpbFrameSend(
          _snapshot,
          accountId: authority.accountId,
          authority: authority,
          effect: effect,
        );
        if (result.canCommit) {
          await _commit(result);
        }
      });
    }());
  }

  void _dispatchSocketClose(CloseHpbSocketEffect effect) {
    final socket = _socket;
    if (socket == null || _socketEpoch != effect.context.connectionEpoch) {
      return;
    }
    _socket = null;
    _socketEpoch = null;
    unawaited(_socketSubscription?.cancel());
    _socketSubscription = null;
    unawaited(socket.close(effect.reason));
  }

  Future<void> _applySocketFrame(int connectionEpoch, String encoded) async {
    if (_disposed ||
        _failed ||
        _socketEpoch != connectionEpoch ||
        _state.connectionEpoch != connectionEpoch) {
      return;
    }
    final HpbServerFrame frame;
    try {
      frame = HpbServerFrame.decode(encoded);
    } on TalkProtocolException catch (error) {
      // Ignored, not fatal. The signalling protocol grows: a standalone
      // server with an MCU sends frames this client has no use for, and
      // closing the socket over one of them took the whole call down —
      // measured against the reference cloud on 5 September 2026, where the
      // server logged `websocket: close 1002 (protocol error)` from this
      // client seconds after it published, and every later message was
      // refused because the lost session raised the renegotiation flag.
      debugPrint(
        '[call] ignoring an undecodable frame: ${error.code.name} '
        '${_frameSummary(encoded)}',
      );
      return;
    }
    final result = applyHpbServerFrame(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      connectionEpoch: connectionEpoch,
      roomEpoch: _state.roomEpoch,
      frame: frame,
      nowMicros: nowMicros(),
      nextRequestId: _requestId(),
      sendEffectId: _effectId(),
      deadlineEffectId: _effectId(),
      refreshEffectId: _effectId(),
      closeEffectId: _effectId(),
    );
    if (!result.canCommit) {
      if (result.outcome == SignalingRuntimeOutcome.rejected) {
        // Same reasoning as above: a frame this state cannot use (a message
        // from a session that is not a participant, an event for a room this
        // account has left) is dropped, not answered with a disconnect.
        debugPrint(
          '[call] ignoring a rejected frame: ${_frameSummary(encoded)} '
          'sender=${_shortSender(encoded)} '
          'own=${_short(_state.hpbSessionId?.value)} '
          'ready=${_state.signalingReady} room=${_state.roomConfirmed}',
        );
      }
      return;
    }
    if (!await _commit(result)) {
      return;
    }
    // Who the server says is in the room, every time it says it. This is the
    // one thing a call cannot reconstruct afterwards: on 6 September 2026 a
    // client that reconnected after a network drop ended up with an empty
    // participant list and the other side heard nothing at all, and the two
    // could only be told apart by whether a frame had arrived and been
    // dropped or had never come. Neither had been logged, so the run had to
    // be repeated. Room and participant events are rare enough to keep.
    final announcement = _participantAnnouncement(encoded);
    if (announcement != null) {
      debugPrint('[call] $announcement');
    }
    if (result.outcome == SignalingRuntimeOutcome.settingsRefreshRequired) {
      _scheduleSettingsRetry();
    }
  }

  /// The sessions an event names, with their call flag when it carries one.
  /// A leave carries bare session ids, a join and an update carry objects.
  static String _sessions(Object? value) {
    if (value is! List) {
      return '';
    }
    return value
        .map((entry) {
          if (entry is String) {
            return _short(entry);
          }
          if (entry is Map<String, Object?>) {
            final session = entry['sessionId'] ?? entry['sessionid'];
            final inCall = entry['inCall'];
            return inCall == null
                ? _short(session as String?)
                : '${_short(session as String?)}:$inCall';
          }
          return '?';
        })
        .join(' ');
  }

  /// A one-line summary of a room or participants event, or null for anything
  /// else — peer messages carry media and are logged where they are used.
  static String? _participantAnnouncement(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, Object?> || decoded['type'] != 'event') {
        return null;
      }
      final event = decoded['event'];
      if (event is! Map<String, Object?>) {
        return null;
      }
      final target = event['target'];
      if (target != 'participants' && target != 'room') {
        return null;
      }
      final kind = event['type'];
      final detail = switch (kind) {
        'join' => _sessions(event['join']),
        'leave' => _sessions(event['leave']),
        'update' => _sessions(
          (event['update'] as Map<String, Object?>?)?['users'],
        ),
        _ => '',
      };
      return 'room event $target/$kind $detail'.trimRight();
    } on Object {
      return null;
    }
  }

  static String _short(String? value) => value == null
      ? '-'
      : value.substring(0, value.length < 8 ? value.length : 8);

  /// Who the server says sent the frame, shortened.
  static String _shortSender(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map<String, Object?>) {
        final body = decoded[decoded['type']];
        if (body is Map<String, Object?>) {
          final sender = body['sender'];
          if (sender is Map<String, Object?>) {
            return '${sender['type']}:${_short(sender['sessionid'] as String?)}';
          }
        }
      }
    } on Object {
      // Not a shape with a sender.
    }
    return '-';
  }

  /// The frame's shape without its content: enough to name what was dropped,
  /// never enough to leak an SDP or a chat message into a log.
  static String _frameSummary(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map<String, Object?>) {
        final type = decoded['type'];
        final body = decoded[type];
        if (body is Map<String, Object?>) {
          if (body['type'] == 'update' || body['type'] == 'join') {
            // The standalone signalling server nests a participants update
            // one level deeper — `event.update.users` — so reading only the
            // top level printed the event with no users at all, which is
            // exactly the detail a reconnect needs.
            final update = body['update'];
            final users =
                body['users'] ??
                body['join'] ??
                (update is Map<String, Object?> ? update['users'] : null);
            final flags = users is List
                ? users
                      .map(
                        (u) => u is Map<String, Object?>
                            ? '${(u['sessionId'] as String? ?? '?').substring(0, 6)}:${u['inCall']}'
                            : '?',
                      )
                      .join(' ')
                : '';
            return 'type=$type/${body['type']} $flags';
          }
          final data = body['data'];
          final inner = data is Map<String, Object?>
              ? ' data=${data['type']}/${data['roomType']} '
                    'keys=${(data.keys.toList()..sort()).join(',')}'
              : '';
          return 'type=$type$inner';
        }
        return 'type=$type';
      }
    } on Object {
      // Not even JSON.
    }
    return 'bytes=${encoded.length}';
  }

  Future<void> _recordSocketDisconnect(
    int connectionEpoch, {
    required bool outboundPossiblySent,
  }) async {
    if (_disposed || _failed || _handledDisconnectEpoch == connectionEpoch) {
      return;
    }
    final result = recordHpbDisconnect(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      connectionEpoch: connectionEpoch,
      nowMicros: nowMicros(),
      jitterUnit: reconnectJitterUnit(),
      deadlineEffectId: _effectId(),
      outboundPossiblySent: outboundPossiblySent,
    );
    if (!result.canCommit) {
      return;
    }
    _handledDisconnectEpoch = connectionEpoch;
    _socket = null;
    _socketEpoch = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _commit(result);
  }

  void _syncDeadline() {
    final deadline = _state.pendingDeadline;
    if (identical(deadline, _scheduledDeadline)) {
      return;
    }
    _deadlineTask?.cancel();
    _deadlineTask = null;
    _scheduledDeadline = deadline;
    if (deadline == null || _disposed || _failed) {
      return;
    }
    final remaining = deadline.deadlineMicros - nowMicros();
    _deadlineTask = scheduler.schedule(
      Duration(microseconds: remaining < 0 ? 0 : remaining),
      () => unawaited(_enqueue(() => _completeDeadline(deadline))),
    );
  }

  Future<void> _completeDeadline(
    ScheduleSignalingDeadlineEffect deadline,
  ) async {
    if (_disposed || _failed || !identical(_state.pendingDeadline, deadline)) {
      return;
    }
    switch (deadline.kind) {
      case SignalingDeadlineKind.welcome:
        final result = handleHpbWelcomeTimeout(
          _snapshot,
          accountId: authority.accountId,
          authority: authority,
          effect: deadline,
          nowMicros: nowMicros(),
          requestId: _requestId(),
          sendEffectId: _effectId(),
        );
        if (result.canCommit) {
          await _commit(result);
        }
      case SignalingDeadlineKind.reconnect || SignalingDeadlineKind.backoff:
        await _planExternalConnect(completedDeadline: deadline);
      case SignalingDeadlineKind.resumeExpiry:
        return;
    }
  }

  void _dispatchRoomRefresh(RefreshConversationSessionEffect effect) {
    if (_roomRefreshInFlight) {
      return;
    }
    _roomRefreshInFlight = true;
    final previousSession = authority.nextcloudSessionId;
    unawaited(
      refreshConversationSession(key.accountId, key.roomToken)
          .then((session) {
            return _enqueue(() async {
              _roomRefreshInFlight = false;
              if (_disposed ||
                  _failed ||
                  _state.phase !=
                      SignalingAccountPhase.roomSessionRefreshRequired ||
                  _state.connectionEpoch != effect.context.connectionEpoch ||
                  _state.roomEpoch != effect.context.roomEpoch ||
                  session == null ||
                  session == previousSession) {
                _publishFailure(CallSignalingFailure.roomRefresh);
                return;
              }
              authority = SignalingAuthority(
                accountId: authority.accountId,
                server: authority.server,
                credentialGeneration: authority.credentialGeneration,
                capabilityGeneration: authority.capabilityGeneration,
                settingsRevision: uuid.v4(),
                profile: authority.profile,
                roomToken: authority.roomToken,
                nextcloudSessionId: session,
              );
              final refreshed = refreshSignalingAuthority(
                _snapshot,
                authority: authority,
              );
              if (!refreshed.canCommit) {
                _publishFailure(CallSignalingFailure.roomRefresh);
                return;
              }
              if (!await _commit(refreshed)) {
                return;
              }
              await _fetchSettings();
            });
          })
          .catchError((Object _, StackTrace _) {
            return _enqueue(() async {
              _roomRefreshInFlight = false;
              _publishFailure(CallSignalingFailure.roomRefresh);
            });
          }),
    );
  }
}
