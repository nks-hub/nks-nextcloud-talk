part of 'chat_service.dart';

extension _ChatServiceFetch on ChatService {
  Future<({_PreparedChat prepared, ChatSynchronizationResult result})>
  _resolveAndSynchronizePrepared(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
    _ChatSynchronizationProbe? probe,
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
    _ChatSynchronizationProbe? probe,
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
    _ChatSynchronizationProbe? probe,
  }) async {
    await _chat.recoverInterruptedTextSends(prepared.account.id);
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
    return result;
  }

  Future<void> _fetchHistoryPage(
    _PreparedChat prepared, {
    required bool includeLastKnown,
    Future<void>? abortTrigger,
    _ChatSynchronizationProbe? probe,
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

  Future<ChatSynchronizationResult> _catchUpFuture(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
    _ChatSynchronizationProbe? probe,
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
      final response = await _api.getChat(
        chatRequest: request,
        loginName: prepared.account.loginName,
        appPassword: prepared.appPassword,
        abortTrigger: abortTrigger,
      );
      await _ensurePreparedContextCurrent(prepared);
      final outcome = await _applyGetResponse(prepared, response);
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
