part of 'chat_service.dart';

extension _ChatServiceFetch on ChatService {
  Future<_PreparedChat> _resolveAndSynchronizePrepared(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
  }) async {
    var resolved = prepared;
    if (resolved.threadId != null &&
        resolved.namedThread == null &&
        resolved.networkThreadId == null) {
      resolved = await _hydrateUnknownThreadFromRoot(
        resolved,
        abortTrigger: abortTrigger,
      );
    }
    try {
      await _synchronizePrepared(resolved, abortTrigger: abortTrigger);
    } on _UnknownThreadNotFound {
      resolved = await _hydrateUnknownThreadFromRoot(
        resolved,
        abortTrigger: abortTrigger,
      );
      await _synchronizePrepared(resolved, abortTrigger: abortTrigger);
    }
    if (resolved.threadId != null && resolved.namedThread == null) {
      resolved = resolved.asNamedThread();
    }
    return resolved;
  }

  Future<_PreparedChat> _hydrateUnknownThreadFromRoot(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
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

  Future<void> _synchronizePrepared(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
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
      );
    }
    await _catchUpFuture(prepared, abortTrigger: abortTrigger);
    await _processPending(prepared);
    scope = (await _chat.getNetworkScope(
      accountId: prepared.account.id,
      roomToken: prepared.conversation.token,
      threadId: prepared.networkThreadId,
    ))!;
    if (!scope.futureConverged) {
      await _catchUpFuture(prepared, abortTrigger: abortTrigger);
    }
  }

  Future<void> _fetchHistoryPage(
    _PreparedChat prepared, {
    required bool includeLastKnown,
    Future<void>? abortTrigger,
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

  Future<void> _catchUpFuture(
    _PreparedChat prepared, {
    Future<void>? abortTrigger,
  }) async {
    for (var page = 0; page < ChatService._maximumCatchUpPages; page++) {
      await _ensurePreparedContextCurrent(prepared);
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
      if (response.classification == ChatGetClassification.notModified ||
          response.classification == ChatGetClassification.commonReadOnly) {
        return;
      }
    }
  }
}
