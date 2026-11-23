part of 'chat_service.dart';

extension _ChatServiceFetch on ChatService {
  Future<ChatSynchronizationResult> _syncRoom({
    required String accountId,
    required String roomToken,
    int? threadId,
    required bool joinExisting,
    bool automatic = false,
    bool Function()? readerIsActive,
  }) {
    final key =
        '${_scopeSyncKey(accountId, roomToken, threadId)}/${automatic ? 'automatic' : 'explicit'}';
    final existing = _syncInFlight[key];
    if (joinExisting && existing != null) {
      return existing;
    }
    final read = _ChatReadAdmission(
      this,
      accountId,
      roomToken,
      readerIsActive ??
          (automatic
              ? () => _hasActiveReader(accountId, roomToken)
              : () => true),
      requiresActiveOwner: readerIsActive != null,
    );
    late final Future<ChatSynchronizationResult> operation;
    operation = _serializeRoom<ChatSynchronizationResult>(
      _roomKey(accountId, roomToken),
      () async {
        return _withRoomErrorPersistence(accountId, roomToken, () async {
          try {
            return await read.run(() async {
              final prepared = await _prepare(
                accountId,
                roomToken,
                threadId: threadId,
                abortTrigger: read.abortTrigger,
              );
              return (await _resolveAndSynchronizePrepared(
                prepared,
                abortTrigger: read.abortTrigger,
                probe: read,
              )).result;
            });
          } on _ChatReadDeferred {
            return ChatSynchronizationResult.deferred;
          } on _ChatSynchronizationStale {
            return ChatSynchronizationResult.incomplete;
          }
        }, threadId: threadId);
      },
    );
    if (joinExisting) _syncInFlight[key] = operation;
    operation.whenComplete(() {
      read.close();
      if (identical(_syncInFlight[key], operation)) {
        _syncInFlight.remove(key);
      }
    }).ignore();
    return operation;
  }

  Future<({_PreparedChat prepared, ChatSynchronizationResult result})>
  _resolveAndSynchronizePrepared(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
    _ChatReadGuard? probe,
  }) async {
    var resolved = prepared;
    if (resolved.threadId != null &&
        resolved.namedThread == null &&
        resolved.networkThreadId == null) {
      resolved = await _hydrateUnknownThreadFromRoot(
        resolved,
        abortTrigger: abortTrigger,
        probe: probe,
      );
    }
    late ChatSynchronizationResult result;
    try {
      result = await _synchronizePrepared(
        resolved,
        abortTrigger: abortTrigger,
        probe: probe,
      );
    } on _UnknownThreadNotFound {
      resolved = await _hydrateUnknownThreadFromRoot(
        resolved,
        abortTrigger: abortTrigger,
        probe: probe,
      );
      result = await _synchronizePrepared(
        resolved,
        abortTrigger: abortTrigger,
        probe: probe,
      );
    }
    if (resolved.threadId != null && resolved.namedThread == null) {
      resolved = resolved.asNamedThread();
    }
    return (prepared: resolved, result: result);
  }

  Future<_PreparedChat> _hydrateUnknownThreadFromRoot(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
    _ChatReadGuard? probe,
  }) async {
    final threadId = prepared.threadId;
    if (threadId == null) {
      return prepared;
    }
    await _chat.ensureRootScope(
      account: prepared.account,
      conversation: prepared.conversation,
    );
    final rootPrepared = prepared.asRootBackedView();
    for (var page = 0; page < ChatService._maximumCatchUpPages; page++) {
      final classification = await _validatedCachedRootIsNamedThread(
        accountId: prepared.account.id,
        roomToken: prepared.conversation.token,
        threadId: threadId,
      );
      if (classification != null) {
        break;
      }
      final scope = (await _chat.getRootScope(
        accountId: prepared.account.id,
        roomToken: prepared.conversation.token,
      ))!;
      if (!scope.hasHistory) {
        break;
      }
      await _fetchHistoryPage(
        rootPrepared,
        includeLastKnown: scope.lastSyncedAtMillis == null,
        abortTrigger: abortTrigger,
        probe: probe,
      );
    }
    final classification = await _validatedCachedRootIsNamedThread(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: threadId,
    );
    if (classification == false) {
      return rootPrepared;
    }
    if (classification == true && !prepared.profile.threadFetch) {
      throw const ChatServiceException(ChatServiceError.chatUnsupported);
    }
    throw const ChatServiceException(ChatServiceError.invalidResponse);
  }

  Future<ChatSynchronizationResult> _synchronizePrepared(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
    _ChatReadGuard? probe,
  }) async {
    await _recoverInterruptedSends(prepared.account.id);
    var scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    if (scope.lastSyncedAtMillis == null) {
      await _fetchHistoryPage(
        prepared,
        includeLastKnown: true,
        abortTrigger: abortTrigger,
        probe: probe,
      );
    }
    var result = await _catchUpFuture(
      prepared,
      abortTrigger: abortTrigger,
      probe: probe,
    );
    probe?.ensureActive();
    await _processPending(prepared);
    scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    if (!scope.futureConverged) {
      result = await _catchUpFuture(
        prepared,
        abortTrigger: abortTrigger,
        probe: probe,
      );
    }
    await _armAbsenceVerification(prepared);
    return result;
  }

  Future<void> _fetchHistoryPage(
    _PreparedChat prepared, {
    required bool includeLastKnown,
    Future<void>? abortTrigger,
    _ChatReadGuard? probe,
  }) async {
    await _ensurePreparedContextCurrent(prepared);
    final scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    if (!scope.hasHistory) {
      return;
    }
    probe?.ensureFetchAllowed(prepared);
    final request = ChatFetchRequest(
      accountId: AccountId.parse(prepared.account.id),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: prepared.authority.server,
      roomToken: prepared.room.token,
      profile: prepared.profile,
      direction: ChatFetchDirection.history,
      cursor: ChatCursor.parse(scope.historyCursor),
      lastCommonRead: ChatCursor.parse(scope.lastCommonRead),
      limit: ChatService._pageSize,
      includeLastKnown: includeLastKnown,
      timeoutSeconds: 0,
      interactive: !prepared.profile.backgroundCatchUp,
      threadId: prepared.networkThreadId,
      futureConverged: scope.futureConverged,
    );
    final response = await _api.getChat(
      chatRequest: request,
      loginName: prepared.account.loginName,
      appPassword: prepared.appPassword,
      abortTrigger: abortTrigger,
    );
    await _ensurePreparedContextCurrent(prepared);
    await _applyGetResponse(prepared, response);
  }

  /// Fetches the messages around [messageId] for the prepared scope.
  Future<ChatIslandFetch> _fetchContext(
    _PreparedChat prepared,
    int messageId, {
    Future<void>? abortTrigger,
    _ChatReadGuard? probe,
  }) async {
    await _ensurePreparedContextCurrent(prepared);
    probe?.ensureFetchAllowed(prepared);
    final response = await _api.getChatContext(
      contextRequest: ChatContextRequest(
        accountId: AccountId.parse(prepared.account.id),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: prepared.authority.server,
        roomToken: prepared.room.token,
        profile: prepared.profile,
        messageId: messageId,
        limit: ChatService._pageSize,
        threadId: prepared.networkThreadId,
      ),
      loginName: prepared.account.loginName,
      appPassword: prepared.appPassword,
      abortTrigger: abortTrigger,
    );
    await _ensurePreparedContextCurrent(prepared);
    probe?.ensureActive();
    return _islandResult(
      response.classification,
      await _chat.applyChatContextResponse(response),
      fallback: null,
    );
  }

  /// Fetches a page from one edge of [island] with the ordinary chat read:
  /// older from its oldest message, newer from its newest. The newer page
  /// does not wait for new messages; an island that has caught up gets an
  /// empty answer at once.
  Future<ChatIslandFetch> _fetchIslandPage(
    _PreparedChat prepared,
    ChatBlock island, {
    required bool older,
    Future<void>? abortTrigger,
    _ChatReadGuard? probe,
  }) async {
    await _ensurePreparedContextCurrent(prepared);
    final scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    probe?.ensureFetchAllowed(prepared);
    final response = await _api.getChat(
      chatRequest: ChatFetchRequest(
        accountId: AccountId.parse(prepared.account.id),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: prepared.authority.server,
        roomToken: prepared.room.token,
        profile: prepared.profile,
        direction: older
            ? ChatFetchDirection.history
            : ChatFetchDirection.future,
        cursor: older ? island.start : island.end,
        lastCommonRead: ChatCursor.parse(scope.lastCommonRead),
        limit: ChatService._pageSize,
        includeLastKnown: false,
        timeoutSeconds: 0,
        interactive: !prepared.profile.backgroundCatchUp,
        threadId: prepared.networkThreadId,
        futureConverged: scope.futureConverged,
      ),
      loginName: prepared.account.loginName,
      appPassword: prepared.appPassword,
      abortTrigger: abortTrigger,
    );
    await _ensurePreparedContextCurrent(prepared);
    probe?.ensureActive();
    return _islandResult(
      response.classification,
      await _chat.applyChatIslandPage(response, island),
      fallback: island,
    );
  }

  ChatIslandFetch _islandResult(
    ChatGetClassification classification,
    ChatIslandApplied applied, {
    required ChatBlock? fallback,
  }) {
    switch (classification) {
      case ChatGetClassification.reauthenticationRequired:
        throw const ChatServiceException(
          ChatServiceError.reauthenticationRequired,
        );
      case ChatGetClassification.transientError:
        throw const ChatServiceException(ChatServiceError.serviceUnavailable);
      case ChatGetClassification.ocsError:
      case ChatGetClassification.commonReadOnly:
        throw const ChatServiceException(ChatServiceError.invalidResponse);
      // A thread the server no longer knows holds no message to show; the
      // jump says so itself, without a broken-room error on top.
      case ChatGetClassification.threadNotFound:
      case ChatGetClassification.lobby:
        return (
          outcome: ChatFetchOutcome.done,
          island: fallback,
          joined: false,
          atEnd: false,
        );
      case ChatGetClassification.notModified:
        return (
          outcome: ChatFetchOutcome.done,
          island: fallback,
          joined: false,
          atEnd: true,
        );
      case ChatGetClassification.messages:
      case ChatGetClassification.invisibleCursorAdvance:
        if (applied.outcome == ChatMergeOutcome.rejected) {
          throw const ChatServiceException(ChatServiceError.invalidResponse);
        }
        if (applied.outcome == ChatMergeOutcome.stale) {
          return _islandNothing;
        }
        return (
          outcome: ChatFetchOutcome.done,
          island: applied.island ?? fallback,
          joined: applied.joined,
          atEnd: false,
        );
    }
  }

  Future<ChatSynchronizationResult> _catchUpFuture(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
    _ChatReadGuard? probe,
  }) async {
    for (var page = 0; page < ChatService._maximumCatchUpPages; page++) {
      await _ensurePreparedContextCurrent(prepared);
      final scope = (await _chat.getNetworkScope(
        accountId: prepared.account.id,
        roomToken: prepared.conversation.token,
        threadId: prepared.networkThreadId,
      ))!;
      probe?.ensureFetchAllowed(prepared);
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
        timeoutSeconds: 0,
        interactive: !prepared.profile.backgroundCatchUp,
        threadId: prepared.networkThreadId,
        futureConverged: scope.futureConverged,
      );
      final readStartedAt = _nowSeconds();
      final response = await _api.getChat(
        chatRequest: request,
        loginName: prepared.account.loginName,
        appPassword: prepared.appPassword,
        abortTrigger: abortTrigger,
      );
      await _ensurePreparedContextCurrent(prepared);
      final outcome = await _applyGetResponse(prepared, response);
      if (outcome == ChatMergeOutcome.converged) {
        await _resendVerifiedAbsent(prepared, readStartedAt);
      }
      if (outcome == ChatMergeOutcome.stale ||
          response.classification == ChatGetClassification.notModified ||
          response.classification == ChatGetClassification.commonReadOnly ||
          response.classification == ChatGetClassification.lobby) {
        return _chatReadResult(outcome);
      }
    }
    return ChatSynchronizationResult.incomplete;
  }
}
