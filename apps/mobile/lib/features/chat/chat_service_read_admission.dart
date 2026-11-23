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
    bool Function()? readerIsActive, {
    required bool growIsland,
  }) async {
    final read = _ChatReadAdmission(
      this,
      accountId,
      roomToken,
      readerIsActive ?? () => true,
      requiresActiveOwner: readerIsActive != null,
    );
    // One turn on the room lane per request, so a live round can land
    // between growing the island and paging the cursor.
    Future<void> inRoomLane(
      Future<void> Function(_PreparedChat prepared) step,
    ) => _serializeRoom<void>(
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
          if (prepared.threadId != null &&
              prepared.namedThread == null &&
              prepared.networkThreadId == null) {
            prepared = await _hydrateUnknownThreadFromRoot(
              prepared,
              abortTrigger: read.abortTrigger,
              probe: read,
            );
          }
          await step(prepared);
        }),
        threadId: threadId,
      ),
    );
    try {
      if (growIsland && threadId == null) {
        await inRoomLane((prepared) => _growOldestIsland(prepared, read));
      }
      await inRoomLane((prepared) async {
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
    } finally {
      read.close();
    }
  }

  Future<ChatFetchOutcome> _loadMessageContext(
    String accountId,
    String roomToken,
    int? threadId,
    int messageId,
    bool Function()? readerIsActive,
  ) async {
    final read = _ChatReadAdmission(
      this,
      accountId,
      roomToken,
      readerIsActive ?? () => true,
      requiresActiveOwner: readerIsActive != null,
    );
    try {
      return await _serializeRoom<ChatFetchOutcome>(
        _roomKey(accountId, roomToken),
        () => _withRoomErrorPersistence(
          accountId,
          roomToken,
          () => read.run(() async {
            final prepared = await _prepare(
              accountId,
              roomToken,
              threadId: threadId,
              abortTrigger: read.abortTrigger,
            );
            if (!_canFetchContext(prepared)) {
              return ChatFetchOutcome.unsupported;
            }
            try {
              await _fetchContext(
                prepared,
                messageId,
                abortTrigger: read.abortTrigger,
                probe: read,
              );
            } on TalkProtocolException {
              // An answer outside the documented shape (a threadId ignored,
              // no X-Chat-Last-Given) says nothing about the message itself;
              // paging still reaches it.
              return ChatFetchOutcome.unsupported;
            }
            return ChatFetchOutcome.done;
          }),
          threadId: threadId,
        ),
      );
    } on _ChatReadDeferred {
      return ChatFetchOutcome.deferred;
    } on _ChatSynchronizationStale {
      return ChatFetchOutcome.deferred;
    } finally {
      read.close();
    }
  }

  /// When the oldest block of the root view is an island below the network's
  /// history cursor, older messages are missing in two places: right under
  /// the island, where the reader who asked is, and under the cursor. This
  /// grows the island; the caller still pages the cursor, so the gap between
  /// them keeps closing. A failure here costs only the growth: the cursor
  /// page does not depend on it.
  Future<void> _growOldestIsland(
    _PreparedChat prepared,
    _ChatReadAdmission read,
  ) async {
    if (!_canFetchContext(prepared)) {
      return;
    }
    final view = await _chat.getScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: null,
    );
    final network = await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: null,
    );
    final islandStart = int.tryParse(view?.historyCursor ?? '') ?? 0;
    final cursor = int.tryParse(network?.historyCursor ?? '') ?? 0;
    final island =
        '${_roomKey(prepared.account.id, prepared.conversation.token)}'
        '/$islandStart';
    if (islandStart < 1 ||
        islandStart >= cursor ||
        _islandsAtRoomStart.contains(island)) {
      return;
    }
    try {
      final oldest = await _fetchContext(
        prepared,
        islandStart,
        abortTrigger: read.abortTrigger,
        probe: read,
      );
      if (oldest != null && oldest >= islandStart) {
        _islandsAtRoomStart.add(island);
      }
    } on ChatServiceException {
      return;
    } on NextcloudApiException {
      return;
    } on TalkProtocolException {
      return;
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
