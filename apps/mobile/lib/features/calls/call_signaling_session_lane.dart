// ignore_for_file: prefer_initializing_formals

part of 'call_signaling_session.dart';

final class _CallSignalingLane {
  _CallSignalingLane({
    required SignalingRuntimeSnapshot snapshot,
    required this.authority,
    required this.loginName,
    required this.appPassword,
    required this.sessions,
    required this.api,
    required this.socketConnector,
    required this.scheduler,
    required this.refreshConversationSession,
    required this.uuid,
    required this.nowMicros,
    required this.reconnectJitterUnit,
    required this.onReleased,
  }) : _snapshot = snapshot {
    _current = _project(SignalingRuntimeOutcome.unchanged);
    handle = CallSignalingSession._(this);
  }

  SignalingRuntimeSnapshot _snapshot;
  SignalingAuthority authority;
  final String loginName;
  final String appPassword;
  final CallSessionRepository sessions;
  final HttpNextcloudApi api;
  final HpbSocketConnector socketConnector;
  final SignalingScheduler scheduler;
  final ConversationSessionRefresh refreshConversationSession;
  final Uuid uuid;
  final int Function() nowMicros;
  final int Function() reconnectJitterUnit;
  final void Function() onReleased;
  final StreamController<CallSignalingUpdate> _updates =
      StreamController<CallSignalingUpdate>.broadcast(sync: true);
  final Map<String, Completer<void>> _httpAborts = {};
  final List<SignalingPeerMessage> _peerMessageQueue = [];

  late final CallSignalingSession handle;
  late CallSignalingUpdate _current;
  Future<void> _serial = Future<void>.value();
  HpbSocketConnection? _socket;
  StreamSubscription<String>? _socketSubscription;
  int? _socketEpoch;
  int? _handledDisconnectEpoch;
  bool _peerFramePossiblySent = false;
  ScheduleSignalingDeadlineEffect? _scheduledDeadline;
  SignalingScheduledTask? _deadlineTask;
  SignalingScheduledTask? _settingsRetryTask;
  SignalingScheduledTask? _internalRetryTask;
  int _settingsRetryAttempt = 0;
  int _internalRetryAttempt = 0;
  bool _roomRefreshInFlight = false;
  bool _disposed = false;
  bool _failed = false;

  /// How many callers hold this lane. The typing indicator and the chat relay
  /// share one signalling session per room, so the socket may only be torn
  /// down once the last of them lets go.
  int _leases = 1;

  CallSignalingKey get key => (
    accountId: authority.accountId.value,
    roomToken: authority.roomToken.value,
  );

  CallSignalingUpdate get current => _current;

  Stream<CallSignalingUpdate> get updates => _updates.stream;

  SignalingAccountState get _state => _snapshot.accounts[authority.accountId]!;

  void launch() {
    unawaited(_enqueue(_fetchSettings));
  }

  Future<bool> sendPeerMessage(SignalingPeerMessage message) {
    return sendPeerMessages(<SignalingPeerMessage>[message]);
  }

  Future<bool> sendPeerMessages(Iterable<SignalingPeerMessage> messages) {
    final queued = messages.toList(growable: false);
    return _enqueue(() async {
      final renegotiationBlocksBatch =
          _state.renegotiationRequired && !_canSendDuringRenegotiation(queued);
      if (_disposed ||
          _failed ||
          !_state.signalingReady ||
          queued.isEmpty ||
          queued.any((message) => message.recipient == null) ||
          renegotiationBlocksBatch ||
          _peerMessageQueue.length + queued.length >
              maximumSignalingParticipants) {
        return false;
      }
      _peerMessageQueue.addAll(queued);
      return _flushPeerMessages();
    });
  }

  Future<bool> _flushPeerMessages() async {
    final renegotiationBlocksQueue =
        _state.renegotiationRequired &&
        !_canSendDuringRenegotiation(_peerMessageQueue);
    if (_disposed ||
        _failed ||
        _peerMessageQueue.isEmpty ||
        !_state.signalingReady ||
        renegotiationBlocksQueue) {
      if (_disposed || _failed || renegotiationBlocksQueue) {
        _peerMessageQueue.clear();
      }
      return !_disposed && !_failed && !renegotiationBlocksQueue;
    }

    final SignalingRuntimeResult result;
    final int messageCount;
    switch (_state.transport) {
      case SignalingTransportKind.internal:
        if (_state.pendingInternalBatch != null) {
          return true;
        }
        // The protocol request constructor enforces the same 64-message cap.
        messageCount = _peerMessageQueue.length > 64
            ? 64
            : _peerMessageQueue.length;
        result = planInternalSignalingBatch(
          _snapshot,
          accountId: authority.accountId,
          authority: authority,
          requestId: _requestId(),
          messages: _peerMessageQueue.take(messageCount),
        );
      case SignalingTransportKind.externalHpb:
        if (_state.pendingHpbFrame != null ||
            _state.awaitingHpbResponse != null) {
          return true;
        }
        messageCount = 1;
        result = planHpbPeerFrame(
          _snapshot,
          accountId: authority.accountId,
          authority: authority,
          requestId: _requestId(),
          effectId: _effectId(),
          message: _peerMessageQueue.first,
        );
      case null:
        return true;
    }
    if (!result.canCommit) {
      _peerMessageQueue.clear();
      return false;
    }
    if (!await _commit(result)) {
      _peerMessageQueue.clear();
      return false;
    }
    _peerMessageQueue.removeRange(0, messageCount);
    final request = result.request;
    if (request is InternalSignalingBatchRequest) {
      _dispatchInternalBatch(request);
    }
    return true;
  }

  bool _canSendDuringRenegotiation(Iterable<SignalingPeerMessage> messages) =>
      _state.transport == SignalingTransportKind.externalHpb &&
      messages.isNotEmpty &&
      messages.every(_isPayloadFreeTypingPeerMessage);

  bool _isPayloadFreeTypingPeerMessage(SignalingPeerMessage message) =>
      (message.type == 'startedTyping' || message.type == 'stoppedTyping') &&
      message.roomType.isEmpty &&
      message.sid == null &&
      message.sender == null &&
      message.recipient != null &&
      message.payload == null;

  Future<bool> sendControl(HpbControlMessage control) {
    return _enqueue(() async {
      if (_disposed ||
          _failed ||
          _state.transport != SignalingTransportKind.externalHpb) {
        return false;
      }
      final result = planHpbControlFrame(
        _snapshot,
        accountId: authority.accountId,
        authority: authority,
        requestId: _requestId(),
        effectId: _effectId(),
        control: control,
      );
      if (!result.canCommit) {
        return false;
      }
      return _commit(result);
    });
  }

  void retain() => _leases++;

  Future<void> release() {
    return _enqueue(() async {
      if (--_leases > 0) {
        return;
      }
      await _shutdownNow(deleteDurableState: true);
      onReleased();
    });
  }

  Future<void> _fetchSettings() async {
    if (_disposed ||
        _failed ||
        !<SignalingAccountPhase>{
          SignalingAccountPhase.idle,
          SignalingAccountPhase.settingsRefreshRequired,
        }.contains(_state.phase)) {
      return;
    }
    final result = planSignalingSettingsFetch(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      requestId: _requestId(),
    );
    if (!result.canCommit) {
      return;
    }
    if (!await _commit(result)) {
      return;
    }
    _dispatchSettings(result.request! as SignalingSettingsRequest);
  }

  void _dispatchSettings(SignalingSettingsRequest request) {
    final abort = _registerAbort(request.requestId);
    unawaited(
      api
          .getSignalingSettings(
            settingsRequest: request,
            loginName: loginName,
            appPassword: appPassword,
            abortTrigger: abort.future,
          )
          .then((response) {
            _removeAbort(request.requestId, abort);
            return _enqueue(() => _applySettings(response));
          })
          .catchError((Object error, StackTrace stackTrace) {
            _removeAbort(request.requestId, abort);
            return _enqueue(
              () => _handleHttpFailure(
                request,
                error,
                SignalingTransportBodyState.notSent,
              ),
            );
          }),
    );
  }

  Future<void> _applySettings(SignalingSettingsResponse response) async {
    if (_disposed || _failed) {
      return;
    }
    final result = applySignalingSettingsResponse(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      response: response,
      refreshEffectId: _effectId(),
    );
    if (!result.canCommit) {
      return;
    }
    if (!await _commit(result)) {
      return;
    }
    switch (result.outcome) {
      case SignalingRuntimeOutcome.settingsConfigured:
        _settingsRetryAttempt = 0;
        _settingsRetryTask?.cancel();
        _settingsRetryTask = null;
        if (_state.transport == SignalingTransportKind.internal) {
          await _planInternalPull();
        } else {
          await _planExternalConnect();
        }
      case SignalingRuntimeOutcome.settingsRefreshRequired:
        _scheduleSettingsRetry();
      case SignalingRuntimeOutcome.reauthenticationRequired ||
          SignalingRuntimeOutcome.roomSessionRefreshRequired ||
          SignalingRuntimeOutcome.unsupported:
        return;
      default:
        return;
    }
  }

  Future<void> _planInternalPull() async {
    if (_disposed ||
        _failed ||
        _state.settings is! InternalSignalingSettings ||
        _state.pendingInternalPull != null) {
      return;
    }
    final result = planInternalSignalingPull(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      requestId: _requestId(),
    );
    if (!result.canCommit) {
      return;
    }
    if (!await _commit(result)) {
      return;
    }
    _dispatchInternalPull(result.request! as InternalSignalingPullRequest);
  }

  void _dispatchInternalPull(InternalSignalingPullRequest request) {
    final abort = _registerAbort(request.requestId);
    unawaited(
      api
          .pullInternalSignaling(
            pullRequest: request,
            loginName: loginName,
            appPassword: appPassword,
            abortTrigger: abort.future,
          )
          .then((response) {
            _removeAbort(request.requestId, abort);
            return _enqueue(() => _applyInternalPull(response));
          })
          .catchError((Object error, StackTrace stackTrace) {
            _removeAbort(request.requestId, abort);
            return _enqueue(
              () => _handleHttpFailure(
                request,
                error,
                SignalingTransportBodyState.notSent,
              ),
            );
          }),
    );
  }

  Future<void> _applyInternalPull(
    InternalSignalingPullResponse response,
  ) async {
    if (_disposed || _failed) {
      return;
    }
    final result = applyInternalSignalingPullResponse(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      response: response,
      refreshEffectId: _effectId(),
    );
    if (!result.canCommit) {
      return;
    }
    if (!await _commit(result)) {
      return;
    }
    if (response.classification == InternalSignalingClassification.confirmed) {
      _internalRetryAttempt = 0;
      await _planInternalPull();
    } else if (response.classification ==
        InternalSignalingClassification.serverError) {
      _scheduleInternalRetry();
    } else if (result.outcome ==
        SignalingRuntimeOutcome.settingsRefreshRequired) {
      _scheduleSettingsRetry();
    }
  }

  void _dispatchInternalBatch(InternalSignalingBatchRequest request) {
    final abort = _registerAbort(request.requestId);
    unawaited(
      api
          .sendInternalSignalingBatch(
            batchRequest: request,
            loginName: loginName,
            appPassword: appPassword,
            abortTrigger: abort.future,
          )
          .then((response) {
            _removeAbort(request.requestId, abort);
            return _enqueue(() => _applyInternalBatch(response));
          })
          .catchError((Object error, StackTrace stackTrace) {
            _removeAbort(request.requestId, abort);
            return _enqueue(
              () => _handleHttpFailure(
                request,
                error,
                SignalingTransportBodyState.possiblySent,
              ),
            );
          }),
    );
  }

  Future<void> _applyInternalBatch(
    InternalSignalingBatchResponse response,
  ) async {
    if (_disposed || _failed) {
      return;
    }
    final stalePull = _state.pendingInternalPull;
    final result = applyInternalSignalingBatchResponse(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      response: response,
      refreshEffectId: _effectId(),
    );
    if (!result.canCommit) {
      return;
    }
    if (!await _commit(result)) {
      return;
    }
    if (result.outcome == SignalingRuntimeOutcome.settingsRefreshRequired) {
      _scheduleSettingsRetry();
    } else if (result.outcome ==
        SignalingRuntimeOutcome.renegotiationRequired) {
      await _restartInternalPull(stalePull);
    }
  }

  /// The runtime answered an ambiguous batch with a new room epoch, which
  /// orphans the pull in flight: its context names the old epoch, so its
  /// response would be rejected and nothing would plan the next one — polling
  /// would stop while the room looked ready. Abort it and start over.
  Future<void> _restartInternalPull(
    InternalSignalingPullRequest? stalePull,
  ) async {
    if (stalePull != null) {
      final abort = _httpAborts.remove(stalePull.requestId.value);
      if (abort != null && !abort.isCompleted) {
        abort.complete();
      }
    }
    await _planInternalPull();
  }

  Future<void> _handleHttpFailure(
    SignalingHttpRequest request,
    Object error,
    SignalingTransportBodyState bodyState,
  ) async {
    if (_disposed || _failed) {
      return;
    }
    if (error is! NextcloudApiException) {
      // The one line that names the frame a batch died on; without it a
      // rejected peer message is indistinguishable from a dead server.
      debugPrint('[call] signalling protocol failure: $error');
      await _fail(CallSignalingFailure.protocol);
      return;
    }
    if (error.code == NextcloudApiError.cancelled) {
      return;
    }
    final stalePull = _state.pendingInternalPull;
    final result = recordSignalingHttpTransportFailure(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      request: request,
      bodyState: bodyState,
    );
    if (!result.canCommit) {
      return;
    }
    if (!await _commit(result)) {
      return;
    }
    if (request is SignalingSettingsRequest) {
      _scheduleSettingsRetry();
    } else if (request is InternalSignalingPullRequest) {
      _scheduleInternalRetry();
    } else if (result.outcome ==
        SignalingRuntimeOutcome.renegotiationRequired) {
      await _restartInternalPull(stalePull);
    }
  }

  Future<void> _planExternalConnect({
    ScheduleSignalingDeadlineEffect? completedDeadline,
  }) async {
    final result = planSignalingConnect(
      _snapshot,
      accountId: authority.accountId,
      authority: authority,
      nowMicros: nowMicros(),
      effectId: _effectId(),
      completedDeadline: completedDeadline,
    );
    if (result.canCommit) {
      await _commit(result);
    }
  }

  Future<bool> _commit(SignalingRuntimeResult result) async {
    final before = _snapshot;
    final next = result.plan!.commit(before);
    try {
      if (!identical(before, next)) {
        await sessions.persist(next.accounts[authority.accountId]!);
      }
    } on Object {
      await _fail(CallSignalingFailure.persistence);
      return false;
    }
    _snapshot = next;
    _publish(result);
    _syncDeadline();
    for (final effect in result.effects) {
      _executeEffect(effect);
    }
    await _flushPeerMessages();
    return true;
  }

  void _scheduleSettingsRetry() {
    if (_settingsRetryTask?.isActive ?? false) {
      return;
    }
    final seconds =
        1 << (_settingsRetryAttempt > 4 ? 4 : _settingsRetryAttempt);
    _settingsRetryAttempt++;
    _settingsRetryTask = scheduler.schedule(Duration(seconds: seconds), () {
      _settingsRetryTask = null;
      unawaited(_enqueue(_fetchSettings));
    });
  }

  void _scheduleInternalRetry() {
    if (_internalRetryTask?.isActive ?? false) {
      return;
    }
    final seconds =
        1 << (_internalRetryAttempt > 4 ? 4 : _internalRetryAttempt);
    _internalRetryAttempt++;
    _internalRetryTask = scheduler.schedule(Duration(seconds: seconds), () {
      _internalRetryTask = null;
      unawaited(_enqueue(_planInternalPull));
    });
  }

  Completer<void> _registerAbort(SignalingRequestId requestId) {
    final abort = Completer<void>();
    _httpAborts[requestId.value] = abort;
    return abort;
  }

  void _removeAbort(SignalingRequestId requestId, Completer<void> abort) {
    if (identical(_httpAborts[requestId.value], abort)) {
      _httpAborts.remove(requestId.value);
    }
  }

  SignalingRequestId _requestId() => SignalingRequestId.parse(uuid.v4());

  SignalingEffectId _effectId() => SignalingEffectId.parse(uuid.v4());

  CallSignalingUpdate _project(
    SignalingRuntimeOutcome outcome, {
    Iterable<SignalingPeerMessage> messages = const [],
    Iterable<HpbControlMessage> controls = const [],
    Map<String, Object?>? chatRelay,
    CallSignalingFailure? failure,
  }) {
    final state = _state;
    return CallSignalingUpdate(
      key: key,
      outcome: outcome,
      phase: state.phase,
      transport: state.transport,
      topology: state.topology,
      participants: state.participants.values,
      roomConfirmed: state.roomConfirmed,
      federationInterrupted: state.federationInterrupted,
      renegotiationRequired: state.renegotiationRequired,
      messages: messages,
      controls: controls,
      chatRelay: chatRelay,
      roomEpoch: state.roomEpoch,
      chatRelaySupported: state.serverFeatures.supports('chat-relay'),
      localPeerId: _localPeerId(state),
      iceServers: <IceServerConfiguration>[
        ...?state.settings?.stunServers,
        ...?state.settings?.turnServers,
      ],
      failure: failure,
    );
  }

  /// The peer id this client is known by inside [SignalingAccountState.participants].
  static SignalingPeerId? _localPeerId(SignalingAccountState state) {
    return switch (state.transport) {
      SignalingTransportKind.externalHpb =>
        state.hpbSessionId == null
            ? null
            : SignalingPeerId.parse(state.hpbSessionId!.value),
      SignalingTransportKind.internal => SignalingPeerId.parse(
        state.nextcloudSessionId.value,
      ),
      null => null,
    };
  }

  void _publish(SignalingRuntimeResult result) {
    _current = _project(
      result.outcome,
      messages: result.messages,
      controls: result.controls,
      chatRelay: result.chatRelay,
    );
    if (!_updates.isClosed) {
      _updates.add(_current);
    }
  }

  void _publishFailure(CallSignalingFailure failure) {
    _current = _project(SignalingRuntimeOutcome.unchanged, failure: failure);
    if (!_updates.isClosed) {
      _updates.add(_current);
    }
  }

  Future<void> _fail(CallSignalingFailure failure) async {
    if (_failed || _disposed) {
      return;
    }
    _failed = true;
    _publishFailure(failure);
    await _stopIo();
  }

  Future<void> shutdown({required bool deleteDurableState}) {
    return _enqueue(() => _shutdownNow(deleteDurableState: deleteDurableState));
  }

  Future<void> _shutdownNow({required bool deleteDurableState}) async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _stopIo();
    if (deleteDurableState) {
      await sessions.delete(accountId: key.accountId, roomToken: key.roomToken);
    }
    await _updates.close();
  }

  Future<void> _stopIo() async {
    _deadlineTask?.cancel();
    _settingsRetryTask?.cancel();
    _internalRetryTask?.cancel();
    for (final abort in _httpAborts.values) {
      if (!abort.isCompleted) {
        abort.complete();
      }
    }
    _httpAborts.clear();
    _peerMessageQueue.clear();
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    final socket = _socket;
    _socket = null;
    _socketEpoch = null;
    if (socket != null) {
      await socket.close(HpbCloseReason.release);
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
