part of 'runtime.dart';

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
  chatRelayReceived,
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
    required this.chatRelay,
    required this.plan,
  }) : effects = List<SignalingEffect>.unmodifiable(effects),
       messages = List<SignalingPeerMessage>.unmodifiable(messages),
       controls = List<HpbControlMessage>.unmodifiable(controls);

  final SignalingRuntimeOutcome outcome;
  final SignalingHttpRequest? request;
  final List<SignalingEffect> effects;
  final List<SignalingPeerMessage> messages;
  final List<HpbControlMessage> controls;

  /// The raw `data.chat` object relayed by the HPB for this account's room,
  /// or null when the transition carried no chat relay payload. It is
  /// transient like [messages]: nothing about it is kept in the snapshot.
  final Map<String, Object?>? chatRelay;
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
    InternalSignalingClassification.serverError => _renegotiateByRoomEpoch(
      snapshot,
      account,
    ),
  };
}

/// The internal transport's answer to a batch whose delivery is unknown.
///
/// A body that may have reached the server leaves the peers in a state this
/// side cannot know, and the old answer was the sticky flag — which stopped
/// media dead and, as it was never cleared, kept every later call from
/// negotiating until a fresh authority arrived. A NEW ROOM EPOCH IS THE
/// RENEGOTIATION: the media session tears every peer connection down when it
/// sees one and offers again, so nothing inconsistent survives and the flag
/// has nothing to protect. The pending pull belongs to the old epoch (its
/// context would not match any more) and is released here so the lane can
/// plan a fresh one; the flag itself is left alone for the HPB and restart
/// paths that still use it.
SignalingRuntimeResult _renegotiateByRoomEpoch(
  SignalingRuntimeSnapshot snapshot,
  SignalingAccountState account,
) => _replaceAccount(
  snapshot,
  account.copyWith(
    pendingInternalBatch: null,
    pendingInternalPull: null,
    roomEpoch: account.roomEpoch + 1,
  ),
  SignalingRuntimeOutcome.renegotiationRequired,
);

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
    if (bodyState == SignalingTransportBodyState.possiblySent) {
      return _renegotiateByRoomEpoch(snapshot, account);
    }
    return _replaceAccount(
      snapshot,
      account.copyWith(pendingInternalBatch: null),
      SignalingRuntimeOutcome.unchanged,
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
        // A NEW ROOM EPOCH IS THE RENEGOTIATION. The flag records that the peer
        // state may be inconsistent — a batch whose delivery is unknown, or a
        // process that restarted — and it is honoured by refusing to carry
        // anything but typing, which stops media dead. Bumping the room epoch
        // tears every peer connection down by construction (the media session
        // closes them all when it sees a new epoch), so there is no
        // inconsistent peer state left for the flag to protect. Carrying it
        // across a fresh authority made it permanent: once set it survived
        // every restart, and a call joined afterwards reported a lost
        // signalling before it ever offered anything. Confirming a room WITHIN
        // an epoch still preserves it — that is a different thing and has its
        // own test.
        renegotiationRequired: false,
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
  Map<String, Object?>? chatRelay,
}) => SignalingRuntimeResult._(
  outcome: outcome,
  request: request,
  effects: effects,
  messages: messages,
  controls: controls,
  chatRelay: chatRelay,
  plan: SignalingRuntimePlan._(source, candidate),
);

SignalingRuntimeResult _result(SignalingRuntimeOutcome outcome) =>
    SignalingRuntimeResult._(
      outcome: outcome,
      request: null,
      effects: const <SignalingEffect>[],
      messages: const <SignalingPeerMessage>[],
      controls: const <HpbControlMessage>[],
      chatRelay: null,
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
