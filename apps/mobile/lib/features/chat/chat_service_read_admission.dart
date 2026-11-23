part of 'chat_service.dart';

final class _ChatReadDeferred implements Exception {
  const _ChatReadDeferred();
}

abstract interface class _ChatReadGuard {
  void ensureActive();
  void ensureFetchAllowed(_PreparedChat prepared);
}

final class _ChatReadAdmission implements _ChatReadGuard {
  _ChatReadAdmission(
    this.service,
    this.accountId,
    this.roomToken,
    this.readerIsActive, {
    this.requiresActiveOwner = false,
  }) {
    service._readAdmissions.add(this);
  }

  final ChatService service;
  final String accountId;
  final String roomToken;
  final bool Function() readerIsActive;
  final bool requiresActiveOwner;
  final _abort = Completer<void>();
  bool? _passive;
  bool _deferred = false;

  Future<void> get abortTrigger => _abort.future;

  Future<T> run<T>(Future<T> Function() action) async {
    ensureActive();
    try {
      return await action();
    } on Object {
      ensureActive();
      rethrow;
    }
  }

  void readerChanged() {
    if ((requiresActiveOwner || _passive == false) && !readerIsActive()) {
      _deferred = true;
      if (!_abort.isCompleted) _abort.complete();
    }
  }

  @override
  void ensureActive() {
    service._ensureAccountActive(accountId);
    readerChanged();
    if (_deferred) throw const _ChatReadDeferred();
  }

  @override
  void ensureFetchAllowed(_PreparedChat prepared) {
    _passive = prepared.profile.backgroundCatchUp;
    readerChanged();
    ensureActive();
  }

  void close() {
    service._readAdmissions.remove(this);
    if (!_abort.isCompleted) _abort.complete();
  }
}

extension _ChatReadAdmissionService on ChatService {
  Future<ChatFetchOutcome> _loadOlder(
    String accountId,
    String roomToken,
    int? threadId,
    bool Function()? readerIsActive,
  ) async {
    try {
      await _readInRoomLane(accountId, roomToken, threadId, readerIsActive, (
        prepared,
        read,
      ) async {
        try {
          await _fetchHistoryPage(
            prepared,
            includeLastKnown: false,
            abortTrigger: read.abortTrigger,
            probe: read,
          );
        } on _UnknownThreadNotFound {
          await _hydrateUnknownThreadFromRoot(
            prepared,
            abortTrigger: read.abortTrigger,
            probe: read,
          );
        }
      });
      return ChatFetchOutcome.done;
    } on _ChatReadDeferred {
      return ChatFetchOutcome.deferred;
    } on _ChatSynchronizationStale {
      return ChatFetchOutcome.deferred;
    }
  }

  Future<ChatIslandFetch> _loadMessageContext(
    String accountId,
    String roomToken,
    int? threadId,
    int messageId,
    bool Function()? readerIsActive,
  ) async {
    try {
      return await _readInRoomLane(
        accountId,
        roomToken,
        threadId,
        readerIsActive,
        (prepared, read) async {
          if (!_canFetchContext(prepared)) {
            return (
              outcome: ChatFetchOutcome.unsupported,
              island: null,
              joined: false,
              atEnd: false,
            );
          }
          try {
            return await _fetchContext(
              prepared,
              messageId,
              abortTrigger: read.abortTrigger,
              probe: read,
            );
          } on TalkProtocolException {
            // An answer outside the documented shape (a threadId ignored,
            // no X-Chat-Last-Given) says nothing about the message itself;
            // paging still reaches it.
            return (
              outcome: ChatFetchOutcome.unsupported,
              island: null,
              joined: false,
              atEnd: false,
            );
          }
        },
        resolveUnknownThread: false,
      );
    } on _ChatReadDeferred {
      return _islandDeferred;
    } on _ChatSynchronizationStale {
      return _islandDeferred;
    }
  }

  Future<ChatIslandFetch> _loadIslandPage(
    String accountId,
    String roomToken,
    int? threadId,
    ChatBlock island,
    bool older,
    bool Function()? readerIsActive,
  ) async {
    try {
      return await _readInRoomLane(
        accountId,
        roomToken,
        threadId,
        readerIsActive,
        (prepared, read) => _fetchIslandPage(
          prepared,
          island,
          older: older,
          abortTrigger: read.abortTrigger,
          probe: read,
        ),
        resolveUnknownThread: false,
      );
    } on _ChatReadDeferred {
      return _islandDeferred;
    } on _ChatSynchronizationStale {
      return _islandDeferred;
    }
  }

  /// Runs [step] as one read on the room's lane, with the reader's
  /// admission, the room error bookkeeping and, unless told otherwise, a
  /// thread of unknown kind settled first.
  Future<T> _readInRoomLane<T>(
    String accountId,
    String roomToken,
    int? threadId,
    bool Function()? readerIsActive,
    Future<T> Function(_PreparedChat prepared, _ChatReadAdmission read) step, {
    bool resolveUnknownThread = true,
  }) async {
    final read = _ChatReadAdmission(
      this,
      accountId,
      roomToken,
      readerIsActive ?? () => true,
      requiresActiveOwner: readerIsActive != null,
    );
    try {
      return await _serializeRoom<T>(
        _roomKey(accountId, roomToken),
        () => _withRoomErrorPersistence(
          accountId,
          roomToken,
          () => read.run(() async {
            var prepared = await _prepare(
              accountId,
              roomToken,
              threadId: threadId,
              abortTrigger: read.abortTrigger,
            );
            if (resolveUnknownThread &&
                prepared.threadId != null &&
                prepared.namedThread == null &&
                prepared.networkThreadId == null) {
              prepared = await _hydrateUnknownThreadFromRoot(
                prepared,
                abortTrigger: read.abortTrigger,
                probe: read,
              );
            }
            return step(prepared, read);
          }),
          threadId: threadId,
        ),
      );
    } finally {
      read.close();
    }
  }

  /// A thread whose root is not cached yet may still turn out to be a reply
  /// chain; only paging knows how to settle that.
  bool _canFetchContext(_PreparedChat prepared) =>
      prepared.profile.messageContext &&
      (prepared.threadId == null || prepared.namedThread != null);

  Future<bool> _refreshMessage(
    String accountId,
    String roomToken,
    int messageId,
  ) async {
    if (messageId < 1) return false;
    final read = _ChatReadAdmission(
      this,
      accountId,
      roomToken,
      () => _hasActiveReader(accountId, roomToken),
    );
    try {
      return await read.run(() async {
        final prepared = await _prepare(
          accountId,
          roomToken,
          abortTrigger: read.abortTrigger,
        );
        read.ensureFetchAllowed(prepared);
        final before = await _chat.getMessage(
          accountId: accountId,
          roomToken: roomToken,
          messageId: messageId,
        );
        final request = ChatFetchRequest(
          accountId: AccountId.parse(accountId),
          requestId: ChatRequestId.parse(_uuid.v4()),
          server: prepared.authority.server,
          roomToken: prepared.room.token,
          profile: prepared.profile,
          direction: ChatFetchDirection.history,
          cursor: ChatCursor.parse(messageId.toString()),
          lastCommonRead: ChatCursor.parse('0'),
          limit: 1,
          includeLastKnown: true,
          timeoutSeconds: 0,
          interactive: !prepared.profile.backgroundCatchUp,
        );
        final response = await _api.getChat(
          chatRequest: request,
          loginName: prepared.account.loginName,
          appPassword: prepared.appPassword,
          abortTrigger: read.abortTrigger,
        );
        await _ensurePreparedContextCurrent(prepared);
        read.ensureActive();
        if (response.classification != ChatGetClassification.messages) {
          return false;
        }
        for (final message in response.messages) {
          if (message.messageId != messageId) continue;
          return _chat.applyRefreshedMessage(
            accountId: accountId,
            server: prepared.authority.server,
            message: message,
            expectedRawJson: before?.rawJson,
          );
        }
        return false;
      });
    } on _ChatReadDeferred {
      return false;
    } on _ChatSynchronizationStale {
      return false;
    } finally {
      read.close();
    }
  }

  bool _hasActiveReader(String accountId, String roomToken) =>
      _liveBindings.any(
        (reader) =>
            !reader._closed &&
            reader._readerActive &&
            reader.accountId == accountId &&
            reader.roomToken == roomToken,
      );

  void _readerActivityChanged(
    String accountId,
    String roomToken, {
    required bool wake,
  }) {
    if (_closed) return;
    for (final read in _readAdmissions.toList()) {
      if (read.accountId == accountId && read.roomToken == roomToken) {
        read.readerChanged();
      }
    }
    if (wake) {
      for (final relay in _relayBindings.toList()) {
        if (relay.accountId == accountId && relay.roomToken == roomToken) {
          relay._readerBecameActive();
        }
      }
      _readerWakes.add((accountId: accountId, roomToken: roomToken));
    }
  }

  Future<void> _drainWithoutReading(String accountId, String roomToken) =>
      _serializeRoom(
        _roomKey(accountId, roomToken),
        () => _withRoomErrorPersistence(accountId, roomToken, () async {
          final prepared = await _prepare(
            accountId,
            roomToken,
            forceCapabilityNetworkRead: true,
          );
          await _recoverInterruptedSends(accountId);
          await _ensurePreparedContextCurrent(prepared);
          await _processPending(prepared);
        }),
      );
}
