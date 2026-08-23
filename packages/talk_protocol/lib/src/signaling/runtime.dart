import '../identifiers.dart';
import '../protocol_exception.dart';
import 'effects.dart';
import 'hpb.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';
import 'response.dart';
import 'state.dart';

const int hpbWelcomeTimeoutMicros = 1000000;
const int hpbResumeWindowMicros = 30000000;

enum SignalingRuntimeOutcome {
  accountAdded,
  settingsFetching,
  settingsConfigured,
  connecting,
  awaitingWelcome,
  helloSending,
  roomJoining,
  signalingReady,
  internalPolling,
  internalBatchSending,
  internalBatchAccepted,
  peerFrameSending,
  messagesReceived,
  controlsReceived,
  frameAccepted,
  resumed,
  reconnectScheduled,
  roomSessionRefreshRequired,
  reauthenticationRequired,
  settingsRefreshRequired,
  terminated,
  renegotiationRequired,
  restartRecovered,
  authorityRefreshed,
  unsupported,
  ignored,
  unchanged,
  rejected,
}

enum SignalingTransportBodyState { notSent, possiblySent }

final class SignalingRuntimePlan {
  SignalingRuntimePlan._(this._source, this._candidate);

  final SignalingRuntimeSnapshot _source;
  final SignalingRuntimeSnapshot _candidate;
  bool _consumed = false;

  SignalingRuntimeSnapshot commit(SignalingRuntimeSnapshot current) {
    _consume(current);
    return _candidate;
  }

  SignalingRuntimeSnapshot discard(SignalingRuntimeSnapshot current) {
    _consume(current);
    return current;
  }

  void _consume(SignalingRuntimeSnapshot current) {
    if (_consumed || !identical(current, _source)) {
      _runtimeFailure(r'$.runtimePlan');
    }
    _consumed = true;
  }

  @override
  String toString() => 'SignalingRuntimePlan()';
}

final class SignalingRuntimeResult {
  SignalingRuntimeResult._({
    required this.outcome,
    required this.request,
    required Iterable<SignalingEffect> effects,
    required Iterable<SignalingPeerMessage> messages,
    required Iterable<HpbControlMessage> controls,
    required this.plan,
  }) : effects = List<SignalingEffect>.unmodifiable(effects),
       messages = List<SignalingPeerMessage>.unmodifiable(messages),
       controls = List<HpbControlMessage>.unmodifiable(controls);

  final SignalingRuntimeOutcome outcome;
  final SignalingHttpRequest? request;
  final List<SignalingEffect> effects;
  final List<SignalingPeerMessage> messages;
  final List<HpbControlMessage> controls;
  final SignalingRuntimePlan? plan;

  bool get canCommit => plan != null;

  @override
  String toString() =>
      'SignalingRuntimeResult(outcome: ${outcome.name}, '
      'hasRequest: ${request != null}, effects: ${effects.length}, '
      'messages: ${messages.length}, controls: ${controls.length})';
}

SignalingRuntimeResult addSignalingAccount(
  SignalingRuntimeSnapshot snapshot, {
  required SignalingAuthority authority,
}) {
  if (snapshot.accounts.containsKey(authority.accountId)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final accounts = Map<AccountId, SignalingAccountState>.of(snapshot.accounts)
    ..[authority.accountId] = SignalingAccountState.initial(
      authority: authority,
    );
  return _candidate(
    snapshot,
    SignalingRuntimeSnapshot(accounts: accounts),
    SignalingRuntimeOutcome.accountAdded,
  );
}

SignalingRuntimeResult planSignalingSettingsFetch(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required SignalingRequestId requestId,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      !account.profile.enabled ||
      account.pendingSettingsRequest != null ||
      !<SignalingAccountPhase>{
        SignalingAccountPhase.idle,
        SignalingAccountPhase.settingsRefreshRequired,
      }.contains(account.phase)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final request = SignalingSettingsRequest(
    context: _requestContext(account, requestId),
  );
  return _replaceAccount(
    snapshot,
    account.copyWith(
      phase: SignalingAccountPhase.fetchingSettings,
      pendingSettingsRequest: request,
    ),
    SignalingRuntimeOutcome.settingsFetching,
    request: request,
  );
}

SignalingRuntimeResult applySignalingSettingsResponse(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required SignalingSettingsResponse response,
  SignalingEffectId? refreshEffectId,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      account.phase != SignalingAccountPhase.fetchingSettings ||
      !identical(account.pendingSettingsRequest, response.request) ||
      !_requestMatches(account, response.request.context)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  switch (response.classification) {
    case SignalingSettingsClassification.confirmed:
      final settings = response.settings;
      if (settings == null) {
        return _result(SignalingRuntimeOutcome.rejected);
      }
      final internal = settings is InternalSignalingSettings;
      return _replaceAccount(
        snapshot,
        account.copyWith(
          phase: internal
              ? SignalingAccountPhase.internalReady
              : SignalingAccountPhase.idle,
          settings: settings,
          connectionEpoch: internal && account.connectionEpoch == 0
              ? 1
              : account.connectionEpoch,
          topology: settings.initialTopology,
          roomConfirmed: internal,
          pendingSettingsRequest: null,
        ),
        SignalingRuntimeOutcome.settingsConfigured,
      );
    case SignalingSettingsClassification.reauthenticationRequired:
      return _replaceAccount(
        snapshot,
        _clearTransient(
          account,
          phase: SignalingAccountPhase.reauthenticationRequired,
        ).copyWith(pendingSettingsRequest: null),
        SignalingRuntimeOutcome.reauthenticationRequired,
      );
    case SignalingSettingsClassification.roomRefreshRequired:
      return _roomRefresh(
        snapshot,
        account,
        effectId: _required(refreshEffectId, r'$.refreshEffectId'),
      );
    case SignalingSettingsClassification.serverError:
      return _replaceAccount(
        snapshot,
        account.copyWith(
          phase: SignalingAccountPhase.settingsRefreshRequired,
          pendingSettingsRequest: null,
        ),
        SignalingRuntimeOutcome.settingsRefreshRequired,
      );
  }
}

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

SignalingRuntimeResult planInternalSignalingPull(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required SignalingRequestId requestId,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      account.settings is! InternalSignalingSettings ||
      account.pendingInternalPull != null ||
      !<SignalingAccountPhase>{
        SignalingAccountPhase.internalReady,
        SignalingAccountPhase.internalPolling,
      }.contains(account.phase)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final request = InternalSignalingPullRequest(
    context: _requestContext(account, requestId),
    nextcloudSessionId: account.nextcloudSessionId,
  );
  return _replaceAccount(
    snapshot,
    account.copyWith(
      phase: SignalingAccountPhase.internalPolling,
      pendingInternalPull: request,
    ),
    SignalingRuntimeOutcome.internalPolling,
    request: request,
  );
}

SignalingRuntimeResult applyInternalSignalingPullResponse(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required InternalSignalingPullResponse response,
  SignalingEffectId? refreshEffectId,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      !identical(account.pendingInternalPull, response.request) ||
      !_requestMatches(account, response.request.context)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return switch (response.classification) {
    InternalSignalingClassification.confirmed => _replaceAccount(
      snapshot,
      account.copyWith(
        phase: SignalingAccountPhase.internalReady,
        pendingInternalPull: null,
        participants: _participantMap(response.participants),
        roomConfirmed: true,
      ),
      response.messages.isEmpty
          ? SignalingRuntimeOutcome.signalingReady
          : SignalingRuntimeOutcome.messagesReceived,
      messages: response.messages,
    ),
    InternalSignalingClassification.profileRefreshRequired => _settingsRefresh(
      snapshot,
      account,
    ),
    InternalSignalingClassification.reauthenticationRequired =>
      _reauthentication(snapshot, account),
    InternalSignalingClassification.roomRefreshRequired => _roomRefresh(
      snapshot,
      account.copyWith(pendingInternalPull: null),
      effectId: refreshEffectId,
    ),
    InternalSignalingClassification.sessionTerminated => _terminate(
      snapshot,
      account.copyWith(pendingInternalPull: null),
    ),
    InternalSignalingClassification.serverError => _replaceAccount(
      snapshot,
      account.copyWith(
        phase: SignalingAccountPhase.internalReady,
        pendingInternalPull: null,
      ),
      SignalingRuntimeOutcome.unchanged,
    ),
  };
}

SignalingRuntimeResult planInternalSignalingBatch(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required SignalingRequestId requestId,
  required Iterable<SignalingPeerMessage> messages,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      account.settings is! InternalSignalingSettings ||
      !account.signalingReady ||
      account.pendingInternalBatch != null) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final request = InternalSignalingBatchRequest(
    context: _requestContext(account, requestId),
    nextcloudSessionId: account.nextcloudSessionId,
    messages: messages,
  );
  return _replaceAccount(
    snapshot,
    account.copyWith(pendingInternalBatch: request),
    SignalingRuntimeOutcome.internalBatchSending,
    request: request,
  );
}

SignalingRuntimeResult applyInternalSignalingBatchResponse(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required InternalSignalingBatchResponse response,
  SignalingEffectId? refreshEffectId,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      !identical(account.pendingInternalBatch, response.request) ||
      !_requestMatches(account, response.request.context)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  return switch (response.classification) {
    InternalSignalingClassification.confirmed => _replaceAccount(
      snapshot,
      account.copyWith(pendingInternalBatch: null),
      SignalingRuntimeOutcome.internalBatchAccepted,
    ),
    InternalSignalingClassification.profileRefreshRequired => _settingsRefresh(
      snapshot,
      account,
    ),
    InternalSignalingClassification.reauthenticationRequired =>
      _reauthentication(snapshot, account),
    InternalSignalingClassification.roomRefreshRequired => _roomRefresh(
      snapshot,
      account.copyWith(pendingInternalBatch: null),
      effectId: refreshEffectId,
    ),
    InternalSignalingClassification.sessionTerminated => _terminate(
      snapshot,
      account.copyWith(pendingInternalBatch: null),
    ),
    InternalSignalingClassification.serverError => _replaceAccount(
      snapshot,
      account.copyWith(pendingInternalBatch: null, renegotiationRequired: true),
      SignalingRuntimeOutcome.renegotiationRequired,
    ),
  };
}

SignalingRuntimeResult recordSignalingHttpTransportFailure(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required SignalingAuthority authority,
  required SignalingHttpRequest request,
  required SignalingTransportBodyState bodyState,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      !_authorityMatches(account, authority) ||
      !_requestMatches(account, request.context)) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  if (request is SignalingSettingsRequest &&
      identical(account.pendingSettingsRequest, request) &&
      account.phase == SignalingAccountPhase.fetchingSettings) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        phase: SignalingAccountPhase.settingsRefreshRequired,
        pendingSettingsRequest: null,
      ),
      SignalingRuntimeOutcome.settingsRefreshRequired,
    );
  }
  if (request is InternalSignalingPullRequest &&
      identical(account.pendingInternalPull, request)) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        phase: SignalingAccountPhase.internalReady,
        pendingInternalPull: null,
        renegotiationRequired: account.renegotiationRequired,
      ),
      SignalingRuntimeOutcome.unchanged,
    );
  }
  if (request is InternalSignalingBatchRequest &&
      identical(account.pendingInternalBatch, request)) {
    return _replaceAccount(
      snapshot,
      account.copyWith(
        pendingInternalBatch: null,
        renegotiationRequired:
            account.renegotiationRequired ||
            bodyState == SignalingTransportBodyState.possiblySent,
      ),
      bodyState == SignalingTransportBodyState.possiblySent
          ? SignalingRuntimeOutcome.renegotiationRequired
          : SignalingRuntimeOutcome.unchanged,
    );
  }
  return _result(SignalingRuntimeOutcome.rejected);
}

SignalingRuntimeResult recoverSignalingAfterProcessRestart(
  SignalingRuntimeSnapshot snapshot, {
  required AccountId accountId,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final recovered =
      _clearTransient(
        account,
        phase: account.profile.enabled
            ? SignalingAccountPhase.idle
            : SignalingAccountPhase.unsupported,
      ).copyWith(
        settings: null,
        connectionEpoch: account.connectionEpoch + 1,
        roomEpoch: account.roomEpoch + 1,
        renegotiationRequired: true,
      );
  return _replaceAccount(
    snapshot,
    recovered,
    SignalingRuntimeOutcome.restartRecovered,
  );
}

SignalingRuntimeResult refreshSignalingAuthority(
  SignalingRuntimeSnapshot snapshot, {
  required SignalingAuthority authority,
  SignalingEffectId? closeEffectId,
}) {
  final account = snapshot.accounts[authority.accountId];
  if (account == null ||
      account.server != authority.server ||
      account.roomToken != authority.roomToken ||
      authority.credentialGeneration < account.credentialGeneration ||
      authority.capabilityGeneration < account.capabilityGeneration) {
    return _result(SignalingRuntimeOutcome.rejected);
  }
  final refreshed =
      _clearTransient(
        account,
        phase: authority.profile.enabled
            ? SignalingAccountPhase.idle
            : SignalingAccountPhase.unsupported,
      ).copyWith(
        credentialGeneration: authority.credentialGeneration,
        capabilityGeneration: authority.capabilityGeneration,
        settingsRevision: authority.settingsRevision,
        profile: authority.profile,
        nextcloudSessionId: authority.nextcloudSessionId,
        settings: null,
        connectionEpoch: account.connectionEpoch + 1,
        roomEpoch: account.roomEpoch + 1,
      );
  return _replaceAccount(
    snapshot,
    refreshed,
    SignalingRuntimeOutcome.authorityRefreshed,
    effects: _closeSocketEffects(
      account,
      effectId: closeEffectId,
      reason: HpbCloseReason.staleConnection,
    ),
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

List<SignalingEffect> _closeSocketEffects(
  SignalingAccountState account, {
  required SignalingEffectId? effectId,
  required HpbCloseReason reason,
}) {
  if (!account.activeSocket && account.pendingSocketOpen == null) {
    return const <SignalingEffect>[];
  }
  return <SignalingEffect>[
    CloseHpbSocketEffect(
      context: _effectContext(account, _required(effectId, r'$.closeEffectId')),
      reason: reason,
    ),
  ];
}

SignalingRuntimeResult _roomRefresh(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account, {
  SignalingEffectId? effectId,
  SignalingEffectId? closeEffectId,
}) {
  final cleared = _clearTransient(
    account,
    phase: SignalingAccountPhase.roomSessionRefreshRequired,
  );
  final effects = <SignalingEffect>[
    ..._closeSocketEffects(
      account,
      effectId: closeEffectId,
      reason: HpbCloseReason.staleConnection,
    ),
    if (effectId != null)
      RefreshConversationSessionEffect(
        context: _effectContext(cleared, effectId),
      ),
  ];
  return _replaceAccount(
    snapshot,
    cleared,
    SignalingRuntimeOutcome.roomSessionRefreshRequired,
    effects: effects,
  );
}

SignalingRuntimeResult _reauthentication(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
) => _replaceAccount(
  snapshot,
  _clearTransient(
    account,
    phase: SignalingAccountPhase.reauthenticationRequired,
  ),
  SignalingRuntimeOutcome.reauthenticationRequired,
);

SignalingRuntimeResult _settingsRefresh(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account, {
  SignalingEffectId? closeEffectId,
}) {
  final cleared = _clearTransient(
    account,
    phase: SignalingAccountPhase.settingsRefreshRequired,
  ).copyWith(settings: null);
  return _replaceAccount(
    snapshot,
    cleared,
    SignalingRuntimeOutcome.settingsRefreshRequired,
    effects: _closeSocketEffects(
      account,
      effectId: closeEffectId,
      reason: HpbCloseReason.staleConnection,
    ),
  );
}

SignalingRuntimeResult _terminate(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account, {
  SignalingEffectId? closeEffectId,
  HpbCloseReason closeReason = HpbCloseReason.protocolFailure,
}) {
  final terminated = _clearTransient(
    account,
    phase: SignalingAccountPhase.terminated,
  );
  return _replaceAccount(
    snapshot,
    terminated,
    SignalingRuntimeOutcome.terminated,
    effects: _closeSocketEffects(
      account,
      effectId: closeEffectId,
      reason: closeReason,
    ),
  );
}

SignalingAccountState _clearTransient(
  SignalingAccountState account, {
  required SignalingAccountPhase phase,
}) => account.copyWith(
  phase: phase,
  helloVersion: null,
  hpbSessionId: null,
  hpbResumeId: null,
  resumeDeadlineMicros: null,
  reconnectAtMicros: null,
  reconnectAttempt: 0,
  serverFeatures: HpbServerFeatures.empty,
  participants: const <SignalingPeerId, SignalingParticipant>{},
  roomConfirmed: false,
  activeSocket: false,
  federationInterrupted: false,
  pendingSettingsRequest: null,
  pendingInternalPull: null,
  pendingInternalBatch: null,
  pendingSocketOpen: null,
  pendingHpbFrame: null,
  awaitingHpbResponse: null,
  pendingDeadline: null,
);

Map<SignalingPeerId, SignalingParticipant> _participantMap(
  Iterable<SignalingParticipant> source,
) {
  final result = <SignalingPeerId, SignalingParticipant>{};
  for (final participant in source) {
    if (result.containsKey(participant.peerId)) {
      _runtimeFailure(r'$.participants');
    }
    result[participant.peerId] = participant;
  }
  return result;
}

bool _authorityMatches(
  SignalingAccountState account,
  SignalingAuthority authority,
) =>
    account.accountId == authority.accountId &&
    account.server == authority.server &&
    account.credentialGeneration == authority.credentialGeneration &&
    account.capabilityGeneration == authority.capabilityGeneration &&
    account.settingsRevision == authority.settingsRevision &&
    account.roomToken == authority.roomToken &&
    account.nextcloudSessionId == authority.nextcloudSessionId &&
    account.profile.enabled == authority.profile.enabled &&
    account.profile.chatRelay == authority.profile.chatRelay;

bool _requestMatches(
  SignalingAccountState account,
  SignalingRequestContext context,
) =>
    context.accountId == account.accountId &&
    context.server == account.server &&
    context.roomToken == account.roomToken &&
    context.credentialGeneration == account.credentialGeneration &&
    context.capabilityGeneration == account.capabilityGeneration &&
    context.settingsRevision == account.settingsRevision &&
    context.connectionEpoch == account.connectionEpoch &&
    context.roomEpoch == account.roomEpoch;

bool _effectMatches(
  SignalingAccountState account,
  SignalingEffectContext context,
) =>
    context.accountId == account.accountId &&
    context.server == account.server &&
    context.roomToken == account.roomToken &&
    context.credentialGeneration == account.credentialGeneration &&
    context.capabilityGeneration == account.capabilityGeneration &&
    context.settingsRevision == account.settingsRevision &&
    context.connectionEpoch == account.connectionEpoch &&
    context.roomEpoch == account.roomEpoch;

SignalingRequestContext _requestContext(
  SignalingAccountState account,
  SignalingRequestId requestId,
) => SignalingRequestContext(
  accountId: account.accountId,
  requestId: requestId,
  server: account.server,
  roomToken: account.roomToken,
  credentialGeneration: account.credentialGeneration,
  capabilityGeneration: account.capabilityGeneration,
  settingsRevision: account.settingsRevision,
  connectionEpoch: account.connectionEpoch,
  roomEpoch: account.roomEpoch,
);

SignalingEffectContext _effectContext(
  SignalingAccountState account,
  SignalingEffectId effectId, {
  int? connectionEpoch,
}) => SignalingEffectContext(
  accountId: account.accountId,
  effectId: effectId,
  server: account.server,
  roomToken: account.roomToken,
  credentialGeneration: account.credentialGeneration,
  capabilityGeneration: account.capabilityGeneration,
  settingsRevision: account.settingsRevision,
  connectionEpoch: connectionEpoch ?? account.connectionEpoch,
  roomEpoch: account.roomEpoch,
);

SignalingRuntimeResult _replaceAccount(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
  SignalingRuntimeOutcome outcome, {
  SignalingHttpRequest? request,
  Iterable<SignalingEffect> effects = const <SignalingEffect>[],
  Iterable<SignalingPeerMessage> messages = const <SignalingPeerMessage>[],
}) {
  final accounts = Map<AccountId, SignalingAccountState>.of(snapshot.accounts)
    ..[account.accountId] = account;
  return _candidate(
    snapshot,
    SignalingRuntimeSnapshot(accounts: accounts),
    outcome,
    request: request,
    effects: effects,
    messages: messages,
  );
}

SignalingRuntimeResult _candidate(
  SignalingRuntimeSnapshot source,
  SignalingRuntimeSnapshot candidate,
  SignalingRuntimeOutcome outcome, {
  SignalingHttpRequest? request,
  Iterable<SignalingEffect> effects = const <SignalingEffect>[],
  Iterable<SignalingPeerMessage> messages = const <SignalingPeerMessage>[],
  Iterable<HpbControlMessage> controls = const <HpbControlMessage>[],
}) => SignalingRuntimeResult._(
  outcome: outcome,
  request: request,
  effects: effects,
  messages: messages,
  controls: controls,
  plan: SignalingRuntimePlan._(source, candidate),
);

SignalingRuntimeResult _result(SignalingRuntimeOutcome outcome) =>
    SignalingRuntimeResult._(
      outcome: outcome,
      request: null,
      effects: const <SignalingEffect>[],
      messages: const <SignalingPeerMessage>[],
      controls: const <HpbControlMessage>[],
      plan: null,
    );

T _required<T>(T? value, String path) {
  if (value == null) {
    _runtimeFailure(path);
  }
  return value;
}

Never _runtimeFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSignalingRuntime, path);
