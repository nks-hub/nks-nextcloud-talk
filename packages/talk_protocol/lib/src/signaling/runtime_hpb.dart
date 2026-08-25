part of 'runtime.dart';

const int hpbWelcomeTimeoutMicros = 1000000;
const int hpbResumeWindowMicros = 30000000;

SignalingRuntimeResult planSignalingConnect(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required int nowMicros,
  required SignalingEffectId effectId,
  ScheduleSignalingDeadlineEffect? completedDeadline,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      account.settings is! ExternalSignalingSettings ||
      account.activeSocket ||
      account.pendingSocketOpen != null ||
      account.pendingHpbFrame != null ||
      !<SignalingAccountPhase>{
        SignalingAccountPhase.idle,
        SignalingAccountPhase.reconnectWaiting,
      }.contains(account.phase)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  if (account.phase == SignalingAccountPhase.reconnectWaiting) {
    if (completedDeadline == null ||
        !identical(account.pendingDeadline, completedDeadline) ||
        !<SignalingDeadlineKind>{
          SignalingDeadlineKind.reconnect,
          SignalingDeadlineKind.backoff,
        }.contains(completedDeadline.kind) ||
        nowMicros < completedDeadline.deadlineMicros) {
      return _result(SignalingRuntimeOutcome.rejected);
    }
  } else if (completedDeadline != null) {
    return _result(SignalingRuntimeOutcome.rejected);
  }

  var prepared = account;
  if (prepared.resumeDeadlineMicros != null &&
      nowMicros >= prepared.resumeDeadlineMicros!) {
    prepared = prepared.copyWith(
      hpbSessionId: null,
      hpbResumeId: null,
      resumeDeadlineMicros: null,
      roomConfirmed: false,
      participants: const <SignalingPeerId, SignalingParticipant>{},
      renegotiationRequired: true,
    );
  }
  final nextEpoch = prepared.connectionEpoch + 1;
  final context = _effectContext(
    prepared,
    effectId,
    connectionEpoch: nextEpoch,
  );
  final effect = OpenHpbSocketEffect(
    context: context,
    endpoint: (prepared.settings! as ExternalSignalingSettings).endpoint,
  );
  return _replaceAccount(
    snapshot,
    prepared.copyWith(
      phase: SignalingAccountPhase.hpbConnecting,
      connectionEpoch: nextEpoch,
      activeSocket: false,
      pendingSocketOpen: effect,
      pendingDeadline: null,
      pendingHpbFrame: null,
      awaitingHpbResponse: null,
    ),
    SignalingRuntimeOutcome.connecting,
    effects: <SignalingEffect>[effect],
  );
}

SignalingRuntimeResult completeHpbSocketOpen(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required OpenHpbSocketEffect effect,
  required SignalingEffectId deadlineEffectId,
  required int nowMicros,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      account.phase != SignalingAccountPhase.hpbConnecting ||
      !identical(account.pendingSocketOpen, effect) ||
      !_effectMatches(account, effect.context)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final deadline = ScheduleSignalingDeadlineEffect(
    context: _effectContext(account, deadlineEffectId),
    kind: SignalingDeadlineKind.welcome,
    deadlineMicros: nowMicros + hpbWelcomeTimeoutMicros,
  );
  return _replaceAccount(
    snapshot,
    account.copyWith(
      phase: SignalingAccountPhase.hpbAwaitingWelcome,
      activeSocket: true,
      pendingSocketOpen: null,
      pendingDeadline: deadline,
    ),
    SignalingRuntimeOutcome.awaitingWelcome,
    effects: <SignalingEffect>[deadline],
  );
}

SignalingRuntimeResult handleHpbWelcomeTimeout(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required ScheduleSignalingDeadlineEffect effect,
  required int nowMicros,
  required SignalingRequestId requestId,
  required SignalingEffectId sendEffectId,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      account.phase != SignalingAccountPhase.hpbAwaitingWelcome ||
      !identical(account.pendingDeadline, effect) ||
      effect.kind != SignalingDeadlineKind.welcome ||
      nowMicros < effect.deadlineMicros ||
      !_effectMatches(account, effect.context)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return _planHello(
    snapshot,
    account.copyWith(pendingDeadline: null),
    nowMicros: nowMicros,
    requestId: requestId,
    effectId: sendEffectId,
    features: HpbServerFeatures.empty,
  );
}

SignalingRuntimeResult completeHpbFrameSend(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required SendHpbFrameEffect effect,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      !account.activeSocket ||
      !identical(account.pendingHpbFrame, effect) ||
      !_effectMatches(account, effect.context)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final awaitsResponse =
      effect.frame is HpbHelloClientFrame ||
      effect.frame is HpbRoomClientFrame ||
      effect.frame is HpbByeClientFrame;
  final candidate = account.copyWith(
    pendingHpbFrame: null,
    awaitingHpbResponse: awaitsResponse ? effect.frame : null,
  );
  return _replaceAccount(
    snapshot,
    candidate,
    effect.frame is HpbMessageClientFrame ||
            effect.frame is HpbControlClientFrame
        ? SignalingRuntimeOutcome.frameAccepted
        : SignalingRuntimeOutcome.unchanged,
  );
}

SignalingRuntimeResult applyHpbServerFrame(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required int connectionEpoch,
  required int roomEpoch,
  required HpbServerFrame frame,
  required int nowMicros,
  SignalingRequestId? nextRequestId,
  SignalingEffectId? sendEffectId,
  SignalingEffectId? deadlineEffectId,
  SignalingEffectId? refreshEffectId,
  SignalingEffectId? closeEffectId,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      connectionEpoch != account.connectionEpoch ||
      roomEpoch != account.roomEpoch ||
      !account.activeSocket ||
      account.pendingHpbFrame != null) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return switch (frame) {
    final HpbWelcomeServerFrame value => _applyWelcome(
      snapshot,
      account,
      value,
      nowMicros: nowMicros,
      requestId: _required(nextRequestId, r'$.nextRequestId'),
      effectId: _required(sendEffectId, r'$.sendEffectId'),
    ),
    final HpbHelloServerFrame value => _applyHello(
      snapshot,
      account,
      value,
      nowMicros: nowMicros,
      nextRequestId: nextRequestId,
      sendEffectId: sendEffectId,
    ),
    final HpbRoomServerFrame value => _applyRoom(snapshot, account, value),
    final HpbErrorServerFrame value => _applyHpbError(
      snapshot,
      account,
      value,
      nowMicros: nowMicros,
      nextRequestId: nextRequestId,
      sendEffectId: sendEffectId,
      deadlineEffectId: deadlineEffectId,
      refreshEffectId: refreshEffectId,
      closeEffectId: closeEffectId,
    ),
    final HpbEventServerFrame value => _applyHpbEvent(snapshot, account, value),
    final HpbMessageServerFrame value => _receiveHpbMessage(
      snapshot,
      account,
      value,
    ),
    final HpbControlServerFrame value => _receiveHpbControl(
      snapshot,
      account,
      value,
    ),
    final HpbByeServerFrame value => _applyHpbBye(
      snapshot,
      account,
      value,
      closeEffectId: closeEffectId,
    ),
    HpbUnsupportedServerFrame() => _result(SignalingRuntimeOutcome.ignored),
  };
}

SignalingRuntimeResult planHpbPeerFrame(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required SignalingRequestId requestId,
  required SignalingEffectId effectId,
  required SignalingPeerMessage message,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      account.phase != SignalingAccountPhase.signalingReady ||
      !account.activeSocket ||
      !account.roomConfirmed ||
      account.federationInterrupted ||
      account.pendingHpbFrame != null ||
      account.awaitingHpbResponse != null ||
      message.recipient == null) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final frame = HpbMessageClientFrame(requestId: requestId, message: message);
  return _sendHpbFrame(
    snapshot,
    account,
    frame,
    effectId,
    SignalingRuntimeOutcome.peerFrameSending,
  );
}

SignalingRuntimeResult planHpbControlFrame(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required SignalingRequestId requestId,
  required SignalingEffectId effectId,
  required HpbControlMessage control,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      account.phase != SignalingAccountPhase.signalingReady ||
      !account.activeSocket ||
      !account.roomConfirmed ||
      account.federationInterrupted ||
      account.pendingHpbFrame != null ||
      account.awaitingHpbResponse != null ||
      control.recipient == null ||
      control.sender != null) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return _sendHpbFrame(
    snapshot,
    account,
    HpbControlClientFrame(requestId: requestId, control: control),
    effectId,
    SignalingRuntimeOutcome.peerFrameSending,
  );
}

SignalingRuntimeResult recordHpbDisconnect(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required int connectionEpoch,
  required int nowMicros,
  required int jitterUnit,
  required SignalingEffectId deadlineEffectId,
  bool outboundPossiblySent = false,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      connectionEpoch != account.connectionEpoch ||
      (!account.activeSocket && account.pendingSocketOpen == null)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final attempt = account.reconnectAttempt + 1;
  final reconnectAt =
      nowMicros +
      computeSignalingReconnectDelayMicros(
        attempt: attempt,
        jitterUnit: jitterUnit,
      );
  final deadline = ScheduleSignalingDeadlineEffect(
    context: _effectContext(account, deadlineEffectId),
    kind: SignalingDeadlineKind.reconnect,
    deadlineMicros: reconnectAt,
  );
  final hasResume = account.hpbSessionId != null && account.hpbResumeId != null;
  final candidate = account.copyWith(
    phase: SignalingAccountPhase.reconnectWaiting,
    activeSocket: false,
    pendingSocketOpen: null,
    pendingHpbFrame: null,
    awaitingHpbResponse: null,
    pendingDeadline: deadline,
    reconnectAtMicros: reconnectAt,
    reconnectAttempt: attempt,
    resumeDeadlineMicros: hasResume
        ? account.resumeDeadlineMicros ?? nowMicros + hpbResumeWindowMicros
        : null,
    renegotiationRequired:
        account.renegotiationRequired || outboundPossiblySent,
  );
  return _replaceAccount(
    snapshot,
    candidate,
    outboundPossiblySent
        ? SignalingRuntimeOutcome.renegotiationRequired
        : SignalingRuntimeOutcome.reconnectScheduled,
    effects: <SignalingEffect>[deadline],
  );
}

int computeSignalingReconnectDelayMicros({
  required int attempt,
  required int jitterUnit,
}) {
  if (attempt < 1 || jitterUnit < 0 || jitterUnit > 1000000) {
    _runtimeFailure(r'$.reconnect');
  }
  final exponent = attempt - 1 > 4 ? 4 : attempt - 1;
  final base = (1 << exponent) * 1000000;
  final jitter = (base * jitterUnit) ~/ 4000000;
  return base + jitter;
}

SignalingRuntimeResult _applyWelcome(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbWelcomeServerFrame frame, {
  required int nowMicros,
  required SignalingRequestId requestId,
  required SignalingEffectId effectId,
}) {
  if (account.phase != SignalingAccountPhase.hpbAwaitingWelcome ||
      account.awaitingHpbResponse != null) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return _planHello(
    snapshot,
    account.copyWith(
      pendingDeadline: null,
      serverFeatures: frame.features,
      topology: frame.features.topology,
    ),
    nowMicros: nowMicros,
    requestId: requestId,
    effectId: effectId,
    features: frame.features,
  );
}

SignalingRuntimeResult _planHello(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account, {
  required int nowMicros,
  required SignalingRequestId requestId,
  required SignalingEffectId effectId,
  required HpbServerFeatures features,
  bool forceFull = false,
}) {
  final settings = account.settings;
  if (settings is! ExternalSignalingSettings || !account.activeSocket) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final canResume =
      !forceFull &&
      account.hpbResumeId != null &&
      account.hpbSessionId != null &&
      account.helloVersion != null &&
      account.resumeDeadlineMicros != null &&
      nowMicros < account.resumeDeadlineMicros!;
  HpbHelloClientFrame frame;
  if (canResume) {
    frame = HpbHelloClientFrame.resume(
      requestId: requestId,
      version: account.helloVersion!,
      resumeId: account.hpbResumeId!,
    );
  } else if (features.supports('hello-v2') &&
      settings.v2Authentication != null) {
    frame = HpbHelloClientFrame.fullV2(
      requestId: requestId,
      server: account.server,
      authentication: settings.v2Authentication!,
    );
  } else if (settings.v1Authentication != null) {
    frame = HpbHelloClientFrame.fullV1(
      requestId: requestId,
      server: account.server,
      authentication: settings.v1Authentication!,
    );
  } else {
    return _replaceAccount(
      snapshot,
      _clearTransient(account, phase: SignalingAccountPhase.unsupported),
      SignalingRuntimeOutcome.unsupported,
    );
  }
  final prepared = canResume
      ? account
      : account.copyWith(
          hpbSessionId: null,
          hpbResumeId: null,
          resumeDeadlineMicros: null,
          roomConfirmed: false,
          participants: const <SignalingPeerId, SignalingParticipant>{},
          renegotiationRequired:
              account.roomConfirmed || account.renegotiationRequired,
        );
  return _sendHpbFrame(
    snapshot,
    prepared.copyWith(phase: SignalingAccountPhase.hpbHelloPending),
    frame,
    effectId,
    SignalingRuntimeOutcome.helloSending,
  );
}

SignalingRuntimeResult _applyHello(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbHelloServerFrame response, {
  required int nowMicros,
  required SignalingRequestId? nextRequestId,
  required SignalingEffectId? sendEffectId,
}) {
  final expected = account.awaitingHpbResponse;
  if (account.phase != SignalingAccountPhase.hpbHelloPending ||
      expected is! HpbHelloClientFrame ||
      response.requestId != expected.requestId ||
      response.version != expected.version) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  if (expected.isResume) {
    if (account.hpbSessionId != response.sessionId) {
      return _result(SignalingRuntimeOutcome.rejected);
    }
    return _replaceAccount(
      snapshot,
      account.copyWith(
        phase: SignalingAccountPhase.signalingReady,
        awaitingHpbResponse: null,
        resumeDeadlineMicros: null,
        reconnectAtMicros: null,
        reconnectAttempt: 0,
        roomConfirmed: true,
      ),
      SignalingRuntimeOutcome.resumed,
    );
  }
  final resumeId = response.resumeId;
  if (resumeId == null) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final features = account.serverFeatures.values.isEmpty
      ? response.serverFeatures
      : account.serverFeatures;
  final prepared = account.copyWith(
    helloVersion: response.version,
    hpbSessionId: response.sessionId,
    hpbResumeId: resumeId,
    resumeDeadlineMicros: null,
    reconnectAtMicros: null,
    reconnectAttempt: 0,
    serverFeatures: features,
    topology: features.topology,
    roomEpoch: account.roomEpoch + 1,
    roomConfirmed: false,
    participants: const <SignalingPeerId, SignalingParticipant>{},
    awaitingHpbResponse: null,
  );
  return _planRoomJoin(
    snapshot,
    prepared,
    requestId: _required(nextRequestId, r'$.nextRequestId'),
    effectId: _required(sendEffectId, r'$.sendEffectId'),
  );
}

SignalingRuntimeResult _planRoomJoin(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account, {
  required SignalingRequestId requestId,
  required SignalingEffectId effectId,
}) {
  final settings = account.settings! as ExternalSignalingSettings;
  if (settings.federation != null &&
      !account.serverFeatures.supports('federation')) {
    return _replaceAccount(
      snapshot,
      _clearTransient(account, phase: SignalingAccountPhase.unsupported),
      SignalingRuntimeOutcome.unsupported,
    );
  }
  final frame = HpbRoomClientFrame.join(
    requestId: requestId,
    roomToken: account.roomToken,
    nextcloudSessionId: account.nextcloudSessionId,
    federation: settings.federation,
  );
  return _sendHpbFrame(
    snapshot,
    account.copyWith(phase: SignalingAccountPhase.hpbRoomPending),
    frame,
    effectId,
    SignalingRuntimeOutcome.roomJoining,
  );
}

SignalingRuntimeResult _applyRoom(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbRoomServerFrame response,
) {
  final expected = account.awaitingHpbResponse;
  if (account.phase != SignalingAccountPhase.hpbRoomPending ||
      expected is! HpbRoomClientFrame ||
      response.requestId != expected.requestId ||
      response.roomToken != expected.roomToken) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  if (expected.isLeave) {
    return _terminate(snapshot, account.copyWith(awaitingHpbResponse: null));
  }
  return _replaceAccount(
    snapshot,
    account.copyWith(
      phase: SignalingAccountPhase.signalingReady,
      roomConfirmed: true,
      awaitingHpbResponse: null,
      federationInterrupted: false,
    ),
    SignalingRuntimeOutcome.signalingReady,
  );
}

SignalingRuntimeResult _applyHpbError(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbErrorServerFrame error, {
  required int nowMicros,
  required SignalingRequestId? nextRequestId,
  required SignalingEffectId? sendEffectId,
  required SignalingEffectId? deadlineEffectId,
  required SignalingEffectId? refreshEffectId,
  required SignalingEffectId? closeEffectId,
}) {
  final expected = account.awaitingHpbResponse;
  if (expected == null || error.requestId != expected.requestId) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  if (expected is HpbHelloClientFrame) {
    if (error.code == 'no_such_session' && expected.isResume) {
      return _planHello(
        snapshot,
        account.copyWith(
          awaitingHpbResponse: null,
          hpbSessionId: null,
          hpbResumeId: null,
          resumeDeadlineMicros: null,
          roomConfirmed: false,
          participants: const <SignalingPeerId, SignalingParticipant>{},
          renegotiationRequired: true,
        ),
        nowMicros: nowMicros,
        requestId: _required(nextRequestId, r'$.nextRequestId'),
        effectId: _required(sendEffectId, r'$.sendEffectId'),
        features: account.serverFeatures,
        forceFull: true,
      );
    }
    if (error.code == 'too_many_requests') {
      return _scheduleHpbBackoff(
        snapshot,
        account.copyWith(awaitingHpbResponse: null),
        nowMicros: nowMicros,
        deadlineEffectId: _required(deadlineEffectId, r'$.deadlineEffectId'),
        closeEffectId: _required(closeEffectId, r'$.closeEffectId'),
      );
    }
    if (<String>{
      'invalid_token',
      'token_not_valid_yet',
      'token_expired',
      'invalid_ticket',
      'auth_failed',
    }.contains(error.code)) {
      return _settingsRefresh(
        snapshot,
        account.copyWith(awaitingHpbResponse: null),
        closeEffectId: _required(closeEffectId, r'$.closeEffectId'),
      );
    }
    return _terminate(
      snapshot,
      account.copyWith(awaitingHpbResponse: null),
      closeEffectId: _required(closeEffectId, r'$.closeEffectId'),
    );
  }
  if (expected is HpbRoomClientFrame) {
    if (error.code == 'already_joined' &&
        error.roomToken == expected.roomToken) {
      return _replaceAccount(
        snapshot,
        account.copyWith(
          phase: SignalingAccountPhase.signalingReady,
          awaitingHpbResponse: null,
          roomConfirmed: true,
          federationInterrupted: false,
        ),
        SignalingRuntimeOutcome.signalingReady,
      );
    }
    if (error.code == 'no_such_room') {
      return _roomRefresh(
        snapshot,
        account.copyWith(awaitingHpbResponse: null),
        effectId: _required(refreshEffectId, r'$.refreshEffectId'),
        closeEffectId: _required(closeEffectId, r'$.closeEffectId'),
      );
    }
    return _terminate(
      snapshot,
      account.copyWith(awaitingHpbResponse: null),
      closeEffectId: _required(closeEffectId, r'$.closeEffectId'),
    );
  }
  return _result(SignalingRuntimeOutcome.rejected);
}

SignalingRuntimeResult _applyHpbEvent(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbEventServerFrame event,
) {
  if (account.phase != SignalingAccountPhase.signalingReady ||
      !account.roomConfirmed) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  if (event.roomToken != null && event.roomToken != account.roomToken) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  if (event.target == 'room' &&
      (event.eventType == 'join' || event.eventType == 'change')) {
    final participants = Map<SignalingPeerId, SignalingParticipant>.of(
      account.participants,
    );
    for (final participant in event.participants) {
      participants[participant.peerId] = participant;
    }
    return _replaceAccount(
      snapshot,
      account.copyWith(participants: participants),
      SignalingRuntimeOutcome.frameAccepted,
    );
  }
  if (event.target == 'room' && event.eventType == 'leave') {
    final participants = Map<SignalingPeerId, SignalingParticipant>.of(
      account.participants,
    );
    for (final peerId in event.leavingPeerIds) {
      participants.remove(peerId);
    }
    return _replaceAccount(
      snapshot,
      account.copyWith(participants: participants),
      SignalingRuntimeOutcome.frameAccepted,
    );
  }
  if (event.target == 'participants' && event.eventType == 'update') {
    final participants = Map<SignalingPeerId, SignalingParticipant>.of(
      account.participants,
    );
    final allParticipantsInCall = event.allParticipantsInCall;
    if (allParticipantsInCall != null) {
      for (final entry in participants.entries.toList(growable: false)) {
        participants[entry.key] = entry.value.withInCall(allParticipantsInCall);
      }
    } else {
      for (final participant in event.participants) {
        participants[participant.peerId] = participant;
      }
    }
    return _replaceAccount(
      snapshot,
      account.copyWith(participants: participants),
      SignalingRuntimeOutcome.frameAccepted,
    );
  }
  if (event.target == 'room' && event.eventType == 'federation_interrupted') {
    return _replaceAccount(
      snapshot,
      account.copyWith(federationInterrupted: true),
      SignalingRuntimeOutcome.frameAccepted,
    );
  }
  if (event.target == 'room' && event.eventType == 'federation_resumed') {
    final resumed = event.federationResumed!;
    final participants = resumed
        ? account.participants
        : Map<SignalingPeerId, SignalingParticipant>.fromEntries(
            account.participants.entries.where(
              (entry) => !entry.value.federated,
            ),
          );
    return _replaceAccount(
      snapshot,
      account.copyWith(
        federationInterrupted: false,
        federatedPeerEpoch: resumed
            ? account.federatedPeerEpoch
            : account.federatedPeerEpoch + 1,
        participants: participants,
        renegotiationRequired: !resumed || account.renegotiationRequired,
      ),
      resumed
          ? SignalingRuntimeOutcome.frameAccepted
          : SignalingRuntimeOutcome.renegotiationRequired,
    );
  }
  return _result(SignalingRuntimeOutcome.ignored);
}

SignalingRuntimeResult _receiveHpbMessage(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbMessageServerFrame frame,
) {
  if (account.phase != SignalingAccountPhase.signalingReady ||
      !account.roomConfirmed ||
      !_acceptsInboundPeer(account, frame.message.sender)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return _candidate(
    snapshot,
    snapshot,
    SignalingRuntimeOutcome.messagesReceived,
    messages: <SignalingPeerMessage>[frame.message],
  );
}

SignalingRuntimeResult _receiveHpbControl(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbControlServerFrame frame,
) {
  if (account.phase != SignalingAccountPhase.signalingReady ||
      !account.roomConfirmed ||
      !_acceptsInboundPeer(account, frame.control.sender)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return _candidate(
    snapshot,
    snapshot,
    SignalingRuntimeOutcome.controlsReceived,
    controls: <HpbControlMessage>[frame.control],
  );
}

bool _acceptsInboundPeer(
  SignalingAccountState account,
  SignalingPeerId? sender,
) {
  if (sender == null) {
    return false;
  }
  final participant = account.participants[sender];
  return participant != null &&
      !(account.federationInterrupted && participant.federated);
}

SignalingRuntimeResult _applyHpbBye(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbByeServerFrame frame, {
  required SignalingEffectId? closeEffectId,
}) {
  final expected = account.awaitingHpbResponse;
  if (frame.requestId != null &&
      (expected is! HpbByeClientFrame ||
          frame.requestId != expected.requestId)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return _terminate(
    snapshot,
    account.copyWith(awaitingHpbResponse: null),
    closeEffectId: _required(closeEffectId, r'$.closeEffectId'),
    closeReason: HpbCloseReason.release,
  );
}

SignalingRuntimeResult _scheduleHpbBackoff(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account, {
  required int nowMicros,
  required SignalingEffectId deadlineEffectId,
  required SignalingEffectId closeEffectId,
}) {
  final reconnectAt = nowMicros + 16000000;
  final deadline = ScheduleSignalingDeadlineEffect(
    context: _effectContext(account, deadlineEffectId),
    kind: SignalingDeadlineKind.backoff,
    deadlineMicros: reconnectAt,
  );
  return _replaceAccount(
    snapshot,
    account.copyWith(
      phase: SignalingAccountPhase.reconnectWaiting,
      activeSocket: false,
      pendingDeadline: deadline,
      reconnectAtMicros: reconnectAt,
      reconnectAttempt: account.reconnectAttempt + 1,
    ),
    SignalingRuntimeOutcome.reconnectScheduled,
    effects: <SignalingEffect>[
      CloseHpbSocketEffect(
        context: _effectContext(account, closeEffectId),
        reason: HpbCloseReason.protocolFailure,
      ),
      deadline,
    ],
  );
}

SignalingRuntimeResult _sendHpbFrame(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  HpbClientFrame frame,
  SignalingEffectId effectId,
  SignalingRuntimeOutcome outcome,
) {
  if (account.pendingHpbFrame != null ||
      account.awaitingHpbResponse != null ||
      !account.activeSocket) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final effect = SendHpbFrameEffect(
    context: _effectContext(account, effectId),
    frame: frame,
  );
  return _replaceAccount(
    snapshot,
    account.copyWith(pendingHpbFrame: effect),
    outcome,
    effects: <SignalingEffect>[effect],
  );
}
