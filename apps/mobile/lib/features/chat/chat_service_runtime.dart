// ignore_for_file: prefer_initializing_formals

part of 'chat_service.dart';

extension _ChatServiceLiveRuntime on ChatService {
  /// Returns `true` when an in-flight live poll for the scope completed in
  /// time, so its merge already applied whatever the server had.
  Future<bool> _awaitLiveNetworkPoll(
    String accountId,
    String roomToken,
    int? threadId,
  ) async {
    final classification = threadId == null
        ? null
        : await _validatedCachedRootIsNamedThread(
            accountId: accountId,
            roomToken: roomToken,
            threadId: threadId,
          );
    final candidates = threadId == null || classification == false
        ? <int?>[null]
        : classification == true
        ? <int?>[threadId]
        : <int?>[threadId, null];
    for (final networkThreadId in candidates) {
      final poll =
          _liveNetworkPolls[_networkScopeKey(
            accountId,
            roomToken,
            networkThreadId,
          )];
      if (poll == null ||
          poll.cancelled ||
          poll.completed ||
          poll.abort.isCompleted) {
        continue;
      }
      try {
        await poll.operation.timeout(ChatService._livePollJoinTimeout);
      } on Object {
        return false;
      }
      return !poll.cancelled;
    }
    return false;
  }

  Future<void> _synchronizeLiveBinding(
    ChatLiveRoomBinding binding,
    _LiveSynchronizationCancellation cancellation,
  ) async {
    final probe = _ChatSynchronizationProbe(
      binding: binding,
      generation: binding._generation,
      cancellation: cancellation,
    );
    try {
      final prepared = binding._prepared;
      if (prepared == null) {
        await _initializeLiveBinding(binding, probe);
      } else {
        await _pollLiveBinding(binding, prepared, probe);
      }
    } on _ChatSynchronizationCancelled {
      // Lifecycle cancellation is an expected control-flow event.
    } on _ChatSynchronizationStale {
      binding._prepared = null;
    }
  }

  Future<void> _initializeLiveBinding(
    ChatLiveRoomBinding binding,
    _ChatSynchronizationProbe probe,
  ) async {
    late _PreparedChat prepared;
    await _withRoomErrorPersistence(
      binding.accountId,
      binding.roomToken,
      () async {
        prepared = await _prepare(
          binding.accountId,
          binding.roomToken,
          threadId: binding.threadId,
          abortTrigger: probe.abortTrigger,
          forceCapabilityNetworkRead: binding._requiresCapabilityNetworkRead,
        );
        probe.ensureActive();
        prepared = await _initializePreparedLiveBinding(
          binding,
          prepared,
          probe,
        );
      },
      threadId: binding.threadId,
    );
    probe.ensureActive();
    binding._prepared = prepared;
    binding._requiresCapabilityNetworkRead = false;
  }

  Future<_PreparedChat> _initializePreparedLiveBinding(
    ChatLiveRoomBinding binding,
    _PreparedChat prepared,
    _ChatSynchronizationProbe probe,
  ) {
    return _serializeRoom<_PreparedChat>(
      _roomKey(binding.accountId, binding.roomToken),
      () async {
        probe.ensureActive();
        final resolved = await _resolveAndSynchronizePrepared(
          prepared,
          abortTrigger: probe.abortTrigger,
        );
        probe.ensureActive();
        return resolved;
      },
    );
  }

  Future<void> _pollLiveBinding(
    ChatLiveRoomBinding binding,
    _PreparedChat prepared,
    _ChatSynchronizationProbe probe,
  ) async {
    _SharedLivePoll? poll;
    try {
      await _withRoomErrorPersistence(
        binding.accountId,
        binding.roomToken,
        () async {
          await _ensureLiveContextCurrent(binding, prepared, probe);
          poll = _joinLiveNetworkPoll(binding, prepared);
          final completed = await Future.any<bool>([
            poll!.operation.then((_) => true),
            probe.cancellation.then((_) => false),
          ]);
          if (!completed) {
            throw const _ChatSynchronizationCancelled();
          }
          probe.ensureActive();
          await _ensureLiveContextCurrent(binding, prepared, probe);
        },
        threadId: binding.threadId,
      );
    } finally {
      final joinedPoll = poll;
      if (joinedPoll != null) {
        _leaveLiveNetworkPoll(binding, joinedPoll);
      }
    }
  }

  _SharedLivePoll _joinLiveNetworkPoll(
    ChatLiveRoomBinding binding,
    _PreparedChat prepared,
  ) {
    final key = _networkScopeKey(
      prepared.account.id,
      prepared.conversation.token,
      prepared.networkThreadId,
    );
    var poll = _liveNetworkPolls[key];
    if (poll != null &&
        (poll.cancelled || poll.completed || poll.abort.isCompleted)) {
      if (identical(_liveNetworkPolls[key], poll)) {
        _liveNetworkPolls.remove(key);
      }
      poll = null;
    }
    if (poll == null) {
      final abort = Completer<void>();
      final created = _SharedLivePoll(key: key, abort: abort);
      final operation = _runLiveNetworkPoll(prepared, created);
      created.operation = operation;
      _liveNetworkPolls[key] = created;
      operation.whenComplete(() {
        created.completed = true;
        if (identical(_liveNetworkPolls[key], created)) {
          _liveNetworkPolls.remove(key);
        }
      }).ignore();
      poll = created;
    }
    poll.bindings.add(binding);
    return poll;
  }

  void _leaveLiveNetworkPoll(
    ChatLiveRoomBinding binding,
    _SharedLivePoll poll,
  ) {
    poll.bindings.remove(binding);
    if (poll.bindings.isEmpty && !poll.completed && !poll.abort.isCompleted) {
      poll.cancelled = true;
      if (identical(_liveNetworkPolls[poll.key], poll)) {
        _liveNetworkPolls.remove(poll.key);
      }
      poll.abort.complete();
    }
  }

  Future<void> _runLiveNetworkPoll(
    _PreparedChat prepared,
    _SharedLivePoll poll,
  ) async {
    final scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    final request = ChatFetchRequest(
      accountId: AccountId.parse(prepared.account.id),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: prepared.authority.server,
      roomToken: prepared.room.token,
      profile: prepared.profile,
      direction: ChatFetchDirection.future,
      cursor: ChatCursor.parse(scope.futureCursor),
      lastCommonRead: ChatCursor.parse(scope.lastCommonRead),
      limit: ChatService._pageSize,
      includeLastKnown: false,
      timeoutSeconds: scope.futureConverged ? 30 : 0,
      interactive: !prepared.profile.backgroundCatchUp,
      threadId: prepared.networkThreadId,
      futureConverged: scope.futureConverged,
    );

    // The network wait deliberately stays outside the room mutation tail.
    final response = await _api.getChat(
      chatRequest: request,
      loginName: prepared.account.loginName,
      appPassword: prepared.appPassword,
      abortTrigger: poll.abort.future,
    );
    await _serializeRoom<void>(
      _roomKey(prepared.account.id, prepared.conversation.token),
      () async {
        if (poll.cancelled || !identical(_liveNetworkPolls[poll.key], poll)) {
          throw const _ChatSynchronizationCancelled();
        }
        if (!await _preparedContextIsCurrent(prepared)) {
          throw const _ChatSynchronizationStale();
        }
        await _applyGetResponse(prepared, response);
      },
    );
  }

  Future<void> _ensureLiveContextCurrent(
    ChatLiveRoomBinding binding,
    _PreparedChat prepared,
    _ChatSynchronizationProbe probe,
  ) async {
    probe.ensureActive();
    final current =
        binding.accountId == prepared.account.id &&
        binding.roomToken == prepared.conversation.token &&
        binding.threadId == prepared.threadId &&
        await _preparedContextIsCurrent(prepared);
    probe.ensureActive();
    if (!current) {
      throw const _ChatSynchronizationStale();
    }
  }

  Future<void> _ensurePreparedContextCurrent(_PreparedChat prepared) async {
    if (!await _preparedContextIsCurrent(prepared)) {
      throw const _ChatSynchronizationStale();
    }
  }

  Future<bool> _preparedContextIsCurrent(_PreparedChat prepared) async {
    if (_suspendedAccounts.contains(prepared.account.id)) {
      return false;
    }
    final account = await _accounts.getAccount(prepared.account.id);
    final conversation = await _chat.getConversation(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
    );
    final capabilityCurrent = await _chat.isCapabilityGenerationCurrent(
      accountId: prepared.account.id,
      generation: prepared.authority.capabilityGeneration,
    );
    final conversationProfileCurrent = conversation == null
        ? false
        : _conversationIsFederated(conversation) == prepared.room.isFederated;
    final namedThread = prepared.threadId == null
        ? null
        : await _validatedCachedRootIsNamedThread(
            accountId: prepared.account.id,
            roomToken: prepared.conversation.token,
            threadId: prepared.threadId!,
          );
    final threadClassificationCurrent = switch (prepared.namedThread) {
      null when prepared.networkThreadId == null => namedThread != true,
      null => namedThread != false,
      false => namedThread != true,
      true => namedThread != false,
    };
    if (account == null || conversation == null) {
      return false;
    }
    return account.id == prepared.account.id &&
        account.serverUrl == prepared.account.serverUrl &&
        account.loginName == prepared.account.loginName &&
        account.talkFeaturesJson == prepared.capabilityFingerprint &&
        conversation.accountId == prepared.conversation.accountId &&
        conversation.token == prepared.conversation.token &&
        conversationProfileCurrent &&
        threadClassificationCurrent &&
        capabilityCurrent;
  }
}

final class ChatLiveRoomBinding {
  ChatLiveRoomBinding._({
    required ChatService service,
    required this.accountId,
    required this.roomToken,
    required this.threadId,
  }) : _service = service;

  final ChatService _service;
  final String accountId;
  final String roomToken;
  final int? threadId;

  _PreparedChat? _prepared;
  Future<void>? _inFlight;
  _LiveSynchronizationCancellation? _activeCancellationCycle;
  Future<void>? _externalCancellation;
  Future<void>? _connectivityWakeInFlight;
  bool _closed = false;
  bool _requiresCapabilityNetworkRead = false;
  int _generation = 0;

  Future<void> synchronize({Future<void>? abortTrigger}) {
    if (_closed) {
      return Future<void>.value();
    }
    _bindExternalCancellation(abortTrigger);
    final existing = _inFlight;
    if (existing != null) {
      return existing;
    }
    final cancellation = _LiveSynchronizationCancellation();
    _activeCancellationCycle = cancellation;
    late final Future<void> operation;
    operation = _service
        ._synchronizeLiveBinding(this, cancellation)
        .whenComplete(() {
          cancellation.release();
          if (identical(_activeCancellationCycle, cancellation)) {
            _activeCancellationCycle = null;
          }
          if (identical(_inFlight, operation)) {
            _inFlight = null;
          }
        });
    _inFlight = operation;
    return operation;
  }

  /// Cancels an idle or active poll and revalidates capabilities before any
  /// queued send can be claimed. Connectivity is only a wake signal: a false
  /// positive still fails the network read and leaves the outbox untouched.
  Future<void> wakeAfterConnectivity() {
    if (_closed) {
      return Future<void>.value();
    }
    final existing = _connectivityWakeInFlight;
    if (existing != null) {
      return existing;
    }
    _requiresCapabilityNetworkRead = true;
    _prepared = null;
    _generation++;
    _activeCancellationCycle?.cancel();

    late final Future<void> operation;
    operation =
        () async {
          final active = _inFlight;
          if (active != null) {
            await active;
          }
          if (_closed) {
            return;
          }
          await synchronize();
        }().whenComplete(() {
          if (identical(_connectivityWakeInFlight, operation)) {
            _connectivityWakeInFlight = null;
          }
        });
    _connectivityWakeInFlight = operation;
    return operation;
  }

  void close() {
    _cancelLifecycle();
  }

  @visibleForTesting
  int get debugActiveCancellationCycleCount =>
      _activeCancellationCycle == null ? 0 : 1;

  void _bindExternalCancellation(Future<void>? cancellation) {
    if (cancellation == null) {
      return;
    }
    final existing = _externalCancellation;
    if (existing != null) {
      if (!identical(existing, cancellation)) {
        throw StateError(
          'A live binding cannot change its cancellation signal',
        );
      }
      return;
    }
    _externalCancellation = cancellation;
    cancellation
        .then<void>(
          (_) => _cancelLifecycle(),
          onError: (Object _, StackTrace _) => _cancelLifecycle(),
        )
        .ignore();
  }

  void _cancelLifecycle() {
    if (_closed) {
      return;
    }
    _closed = true;
    _generation++;
    _activeCancellationCycle?.cancel();
    _service._liveBindings.remove(this);
  }
}

final class _LiveSynchronizationCancellation {
  final Completer<void> _completion = Completer<void>();
  bool _cancelled = false;

  Future<void> get future => _completion.future;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _complete();
  }

  void release() {
    _complete();
  }

  void _complete() {
    if (!_completion.isCompleted) {
      _completion.complete();
    }
  }
}

final class _SharedLivePoll {
  _SharedLivePoll({required this.key, required this.abort});

  final String key;
  final Completer<void> abort;
  late final Future<void> operation;
  final Set<ChatLiveRoomBinding> bindings = {};
  bool cancelled = false;
  bool completed = false;
}

final class _ChatSynchronizationProbe {
  _ChatSynchronizationProbe({
    required this.binding,
    required this.generation,
    required _LiveSynchronizationCancellation cancellation,
  }) : _cancellation = cancellation;

  final ChatLiveRoomBinding binding;
  final int generation;
  final _LiveSynchronizationCancellation _cancellation;

  Future<void> get cancellation => _cancellation.future;

  Future<void> get abortTrigger => _cancellation.future;

  void ensureActive() {
    if (_cancellation.cancelled ||
        binding._closed ||
        binding._generation != generation) {
      throw const _ChatSynchronizationCancelled();
    }
  }
}
