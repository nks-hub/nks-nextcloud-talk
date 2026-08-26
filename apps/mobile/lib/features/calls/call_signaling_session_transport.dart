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
    } on TalkProtocolException {
      await _protocolDisconnect(connectionEpoch);
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
        await _protocolDisconnect(connectionEpoch);
      }
      return;
    }
    if (!await _commit(result)) {
      return;
    }
    if (result.outcome == SignalingRuntimeOutcome.settingsRefreshRequired) {
      _scheduleSettingsRetry();
    }
  }

  Future<void> _protocolDisconnect(int connectionEpoch) async {
    final socket = _socket;
    if (socket != null && _socketEpoch == connectionEpoch) {
      await socket.close(HpbCloseReason.protocolFailure);
    }
    await _recordSocketDisconnect(
      connectionEpoch,
      outboundPossiblySent: _peerFramePossiblySent,
    );
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
