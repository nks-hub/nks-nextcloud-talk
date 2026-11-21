part of 'chat_repository.dart';

extension _ChatRepositoryProjection on ChatRepository {
  Future<void> _projectRootNetworkStateToViewsInCurrentTransaction({
    required String accountId,
    required String roomToken,
    required Set<int> preservedViewThreadIds,
  }) async {
    final networkScope = await _networkScope(
      accountId: accountId,
      roomToken: roomToken,
      threadId: null,
    );
    if (networkScope == null) {
      throw StateError('Root chat scope projection is missing');
    }
    final rootView = await _rootScope(
      accountId: accountId,
      roomToken: roomToken,
    );
    final changedScopes = <ChatScopesCompanion>[];
    final changedRoot = _networkBackedViewScopeCompanion(
      networkScope: networkScope,
      viewThreadId: null,
      viewScope: rootView,
    );
    if (changedRoot != null) {
      changedScopes.add(changedRoot);
    }
    final viewScopes =
        await (_database.select(_database.chatScopes)..where(
              (scope) =>
                  scope.accountId.equals(accountId) &
                  scope.roomToken.equals(roomToken) &
                  scope.threadId.isNotNull(),
            ))
            .get();
    final validViewScopes = viewScopes
        .where((scope) => scope.scopeKey == _scopeKey(scope.threadId!))
        .toList(growable: false);
    final ordinaryUnpreservedRoots = await _cachedOrdinaryRootIds(
      accountId: accountId,
      roomToken: roomToken,
      messageIds: validViewScopes
          .map((scope) => scope.threadId!)
          .where((threadId) => !preservedViewThreadIds.contains(threadId)),
    );
    for (final viewScope in validViewScopes) {
      final viewThreadId = viewScope.threadId!;
      if (!preservedViewThreadIds.contains(viewThreadId) &&
          !ordinaryUnpreservedRoots.contains(viewThreadId)) {
        continue;
      }
      final changedView = _networkBackedViewScopeCompanion(
        networkScope: networkScope,
        viewThreadId: viewThreadId,
        viewScope: viewScope,
      );
      if (changedView != null) {
        changedScopes.add(changedView);
      }
    }
    if (changedScopes.isNotEmpty) {
      await _database.batch(
        (batch) => batch.insertAllOnConflictUpdate(
          _database.chatScopes,
          changedScopes,
        ),
      );
    }
  }

  Future<Set<int>> _rootBackedViewThreadIdsInCurrentTransaction({
    required String accountId,
    required String roomToken,
  }) async {
    final viewScopes =
        await (_database.select(_database.chatScopes)..where(
              (scope) =>
                  scope.accountId.equals(accountId) &
                  scope.roomToken.equals(roomToken) &
                  scope.threadId.isNotNull(),
            ))
            .get();
    final validThreadIds = viewScopes
        .where((scope) => scope.scopeKey == _scopeKey(scope.threadId!))
        .map((scope) => scope.threadId!)
        .toList(growable: false);
    final rootKinds = await _cachedRootKinds(
      accountId: accountId,
      roomToken: roomToken,
      messageIds: validThreadIds,
    );
    return validThreadIds
        .where((threadId) => rootKinds[threadId] != true)
        .toSet();
  }

  Future<void> _projectNamedNetworkStateToViewInCurrentTransaction({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) async {
    final networkScope = await _networkScope(
      accountId: accountId,
      roomToken: roomToken,
      threadId: threadId,
    );
    if (networkScope == null) {
      throw StateError('Named thread network scope projection is missing');
    }
    final viewScope = await _scope(
      accountId: accountId,
      roomToken: roomToken,
      threadId: threadId,
    );
    await _writeNetworkBackedViewScope(
      networkScope: networkScope,
      viewThreadId: threadId,
      viewScope: viewScope,
    );
  }

  Future<void> _appendConfirmedMessageToViewInCurrentTransaction({
    required String accountId,
    required TextSendOutboxOperation operation,
    required ChatMessage message,
  }) async {
    if (operation.replyToToken != null ||
        (operation.parentRoomToken != null &&
            operation.parentRoomToken != operation.roomToken)) {
      return;
    }
    await _appendPostedMessageToViewInCurrentTransaction(
      accountId: accountId,
      roomToken: operation.roomToken,
      replyTo: operation.replyTo,
      namedThreadId: operation.threadId,
      message: message,
    );
  }

  /// Puts a message the server returned for a POST into the view it was
  /// posted to, so it is on screen before the next read brings it.
  Future<void> _appendPostedMessageToViewInCurrentTransaction({
    required String accountId,
    required ConversationToken roomToken,
    required int? replyTo,
    required int? namedThreadId,
    required ChatMessage message,
  }) async {
    if (replyTo != null && namedThreadId != null) {
      return;
    }
    final viewThreadId = namedThreadId ?? replyTo;
    if (message.roomToken != roomToken) {
      return;
    }
    if (viewThreadId == null) {
      if (message.threadId != null && message.threadId != message.messageId) {
        return;
      }
    } else if (message.threadId != viewThreadId) {
      return;
    }
    if (replyTo != null) {
      final parent = _matchingThreadParent(message);
      if (parent == null || parent.messageId != replyTo) {
        return;
      }
    }
    final viewScope = await _scope(
      accountId: accountId,
      roomToken: roomToken.value,
      threadId: viewThreadId,
    );
    final networkScope = await _networkScope(
      accountId: accountId,
      roomToken: roomToken.value,
      threadId: namedThreadId,
    );
    final projectionSource = networkScope ?? viewScope;
    if (projectionSource == null) {
      return;
    }
    final messageCursor = ChatCursor.parse(message.messageId.toString());
    await _writeNetworkBackedViewScope(
      networkScope: projectionSource,
      viewThreadId: viewThreadId,
      viewScope: viewScope,
      extraBlocks: <ChatBlock>[
        if (viewThreadId != null)
          ChatBlock(
            start: ChatCursor.parse(viewThreadId.toString()),
            end: ChatCursor.parse(viewThreadId.toString()),
          ),
        ChatBlock(start: messageCursor, end: messageCursor),
      ],
    );
  }

  Future<void> _writeNetworkBackedViewScope({
    required StoredChatScope networkScope,
    required int? viewThreadId,
    required StoredChatScope? viewScope,
    Iterable<ChatBlock> extraBlocks = const <ChatBlock>[],
  }) async {
    final companion = _networkBackedViewScopeCompanion(
      networkScope: networkScope,
      viewThreadId: viewThreadId,
      viewScope: viewScope,
      extraBlocks: extraBlocks,
    );
    if (companion == null) {
      return;
    }
    await _database
        .into(_database.chatScopes)
        .insertOnConflictUpdate(companion);
  }

  ChatScopesCompanion? _networkBackedViewScopeCompanion({
    required StoredChatScope networkScope,
    required int? viewThreadId,
    required StoredChatScope? viewScope,
    Iterable<ChatBlock> extraBlocks = const <ChatBlock>[],
  }) {
    final blocks = mergeChatBlocks(<ChatBlock>[
      ..._decodeBlocks(networkScope.blocksJson),
      if (viewScope != null) ..._decodeBlocks(viewScope.blocksJson),
      ...extraBlocks,
    ]);
    final companion = ChatScopesCompanion.insert(
      accountId: networkScope.accountId,
      roomToken: networkScope.roomToken,
      scopeKey: _scopeKey(viewThreadId),
      threadId: Value(viewThreadId),
      historyCursor: blocks.first.start.value,
      futureCursor: blocks.last.end.value,
      lastCommonRead: networkScope.lastCommonRead,
      lastReadMessage: networkScope.lastReadMessage,
      unreadMessages: networkScope.unreadMessages,
      hasHistory: networkScope.hasHistory,
      futureConverged: networkScope.futureConverged,
      blocksJson: _encodeBlocks(blocks),
      lastSyncedAtMillis: Value(networkScope.lastSyncedAtMillis),
      lastSyncError: Value(networkScope.lastSyncError),
    );
    // An identical upsert would still wake every watcher of the table.
    if (viewScope?.toCompanion(false) == companion) {
      return null;
    }
    return companion;
  }

  Future<Map<int, bool>> _cachedRootKinds({
    required String accountId,
    required String roomToken,
    required Iterable<int> messageIds,
  }) async {
    final ids = messageIds.toSet().toList(growable: false);
    for (final id in ids) {
      if (id < 1) {
        throw ArgumentError.value(id, 'threadId');
      }
    }
    final result = <int, bool>{};
    const chunkSize = 500;
    for (var offset = 0; offset < ids.length; offset += chunkSize) {
      final end = offset + chunkSize < ids.length
          ? offset + chunkSize
          : ids.length;
      final chunk = ids.sublist(offset, end);
      final rows =
          await (_database.select(_database.cachedChatMessages)..where(
                (message) =>
                    message.accountId.equals(accountId) &
                    message.roomToken.equals(roomToken) &
                    message.messageId.isIn(chunk),
              ))
              .get();
      for (final row in rows) {
        try {
          result[row.messageId] = _classifyCachedRootAsNamedThread(
            row,
            accountId: accountId,
            roomToken: roomToken,
            threadId: row.messageId,
          );
        } on InvalidCachedThreadRootException {
          continue;
        }
      }
    }
    return result;
  }

  Future<Set<int>> _cachedOrdinaryRootIds({
    required String accountId,
    required String roomToken,
    required Iterable<int> messageIds,
  }) async {
    final ids = messageIds.toSet().toList(growable: false);
    final result = <int>{};
    const chunkSize = 500;
    for (var offset = 0; offset < ids.length; offset += chunkSize) {
      final end = offset + chunkSize < ids.length
          ? offset + chunkSize
          : ids.length;
      final chunk = ids.sublist(offset, end);
      final rows =
          await (_database.select(_database.cachedChatMessages)..where(
                (message) =>
                    message.accountId.equals(accountId) &
                    message.roomToken.equals(roomToken) &
                    message.messageId.isIn(chunk),
              ))
              .get();
      for (final row in rows) {
        try {
          final message = ChatMessage.fromJson(jsonDecode(row.rawJson));
          if (message.messageId == row.messageId &&
              message.roomToken.value == roomToken &&
              message.isThread != true) {
            result.add(row.messageId);
          }
        } on Object {
          continue;
        }
      }
    }
    return result;
  }

  Future<ChatRuntimeSnapshot> _loadRuntime(String accountId) async {
    final account = await (_database.select(
      _database.accounts,
    )..where((row) => row.id.equals(accountId))).getSingleOrNull();
    final capability = await (_database.select(
      _database.chatCapabilities,
    )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();
    if (account == null || capability == null) {
      throw StateError('Chat account is not prepared');
    }
    final scopeRows = await (_database.select(
      _database.chatScopes,
    )..where((row) => row.accountId.equals(accountId))).get();
    final cached = _database.cachedChatMessages;
    final messageIdsByScope =
        <({String roomToken, int? threadId}), List<int>>{};
    void addMessage(String roomToken, int? threadId, int messageId) {
      messageIdsByScope
          .putIfAbsent((
            roomToken: roomToken,
            threadId: threadId,
          ), () => <int>[])
          .add(messageId);
    }

    {
      final storedMessages =
          await (_database.selectOnly(cached)
                ..addColumns([
                  cached.roomToken,
                  cached.threadId,
                  cached.messageId,
                ])
                ..where(cached.accountId.equals(accountId)))
              .get();
      for (final row in storedMessages) {
        final roomToken = row.read(cached.roomToken)!;
        final threadId = row.read(cached.threadId);
        final messageId = row.read(cached.messageId)!;
        if (threadId == null || threadId == messageId) {
          addMessage(roomToken, null, messageId);
        }
        if (threadId != null) {
          addMessage(roomToken, threadId, messageId);
        }
      }
    }
    for (final messageIds in messageIdsByScope.values) {
      messageIds.sort();
    }
    final operationRows = await (_database.select(
      _database.textSendOperations,
    )..where((row) => row.accountId.equals(accountId))).get();

    final scopes = <ChatScopeKey, ChatScopeState>{};
    final roomsWithNetworkRoot = scopeRows
        .where((row) => row.scopeKey == _networkRootScopeKey)
        .map((row) => row.roomToken)
        .toSet();
    for (final row in scopeRows) {
      final int? networkThreadId;
      if (row.scopeKey == _networkRootScopeKey && row.threadId == null) {
        networkThreadId = null;
      } else if (row.scopeKey == _rootScopeKey &&
          row.threadId == null &&
          !roomsWithNetworkRoot.contains(row.roomToken)) {
        // Upgrade compatibility: before network/view separation the root row
        // carried both roles. The first persist writes a network-root copy.
        networkThreadId = null;
      } else if (row.threadId != null &&
          row.scopeKey == _networkScopeKey(row.threadId)) {
        networkThreadId = row.threadId;
      } else if (row.scopeKey == _scopeKey(row.threadId)) {
        continue;
      } else {
        throw StateError('Stored chat scope key is invalid');
      }
      final key = ChatScopeKey(
        roomToken: ConversationToken.parse(
          row.roomToken,
          path: r'$.chatScopes.roomToken',
        ),
        threadId: networkThreadId,
      );
      final blocks = _decodeBlocks(row.blocksJson);
      final messageIds =
          (messageIdsByScope[(
                    roomToken: row.roomToken,
                    threadId: networkThreadId,
                  )] ??
                  const <int>[])
              .where((messageId) {
                final cursor = ChatCursor.parse(messageId.toString());
                return blocks.any((block) => block.contains(cursor));
              })
              .toList(growable: false);
      scopes[key] = ChatScopeState(
        messageIds: messageIds,
        historyCursor: ChatCursor.parse(row.historyCursor),
        futureCursor: ChatCursor.parse(row.futureCursor),
        lastCommonRead: row.lastCommonRead == '0'
            ? null
            : ChatCursor.parse(row.lastCommonRead),
        lastReadMessage: row.lastReadMessage,
        unreadMessages: row.unreadMessages,
        hasHistory: row.hasHistory,
        futureConverged: row.futureConverged,
        blocks: blocks,
      );
    }

    final operations = <ChatOperationId, TextSendOutboxOperation>{};
    for (final row in operationRows) {
      final operationId = ChatOperationId.parse(row.operationId);
      operations[operationId] = TextSendOutboxOperation(
        operationId: operationId,
        roomToken: ConversationToken.parse(
          row.roomToken,
          path: r'$.textSendOperations.roomToken',
        ),
        referenceId: ChatReferenceId.parse(row.referenceId),
        message: row.message,
        replayContractRevision: row.replayContractRevision,
        silent: row.silent,
        enqueueSequence: row.enqueueSequence,
        state: _outboxState(row.outboxState),
        attemptCount: row.attemptCount,
        messageIds: _decodeMessageIds(row.messageIdsJson),
        duplicateRiskAcknowledged: row.duplicateRiskAcknowledged,
        errorClass: row.errorClass,
        nextAttemptAt: row.nextAttemptAt,
        automaticResendCount: row.automaticResendCount,
        replyTo: row.replyTo,
        threadId: row.threadId,
        replyToToken: row.replyToToken == null
            ? null
            : ConversationToken.parse(
                row.replyToToken,
                path: r'$.textSendOperations.replyToToken',
              ),
        parentRoomToken: row.parentRoomToken == null
            ? null
            : ConversationToken.parse(
                row.parentRoomToken,
                path: r'$.textSendOperations.parentRoomToken',
              ),
      );
    }

    final typedAccountId = AccountId.parse(accountId);
    return ChatRuntimeSnapshot(
      accounts: {
        typedAccountId: ChatAccountState(
          accountId: typedAccountId,
          server: ServerBase.parse(account.serverUrl),
          lane: _accountLane(capability.lane),
          credentialGeneration: capability.credentialGeneration,
          capabilityGeneration: capability.generation,
          scopes: scopes,
          operations: operations,
        ),
      },
    );
  }

  Future<void> _persistAccount(
    ChatAccountState account, {
    Iterable<ChatMessage> messages = const [],
    ChatScopeKey? syncedScope,
    bool messagesAreSendResponse = false,
  }) async {
    final accountId = account.accountId.value;
    // Rows that would not change are left alone on purpose: any write, even
    // an identical one, wakes every watcher of the table.
    await (_database.update(_database.chatCapabilities)..where(
          (row) =>
              row.accountId.equals(accountId) &
              (row.generation.equals(account.capabilityGeneration).not() |
                  row.credentialGeneration
                      .equals(account.credentialGeneration)
                      .not() |
                  row.lane.equals(account.lane.name).not()),
        ))
        .write(
          ChatCapabilitiesCompanion(
            generation: Value(account.capabilityGeneration),
            credentialGeneration: Value(account.credentialGeneration),
            lane: Value(account.lane.name),
            updatedAtMillis: Value(
              DateTime.now().toUtc().millisecondsSinceEpoch,
            ),
          ),
        );

    final storedScopes = {
      for (final row in await (_database.select(
        _database.chatScopes,
      )..where((row) => row.accountId.equals(accountId))).get())
        (row.roomToken, row.scopeKey): row,
    };
    final syncedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
    final changedScopes = <ChatScopesCompanion>[];
    for (final entry in account.scopes.entries) {
      final key = entry.key;
      final scope = entry.value;
      final wasSynced = syncedScope == key;
      final scopeKey = _networkScopeKey(key.threadId);
      final companion = ChatScopesCompanion.insert(
        accountId: accountId,
        roomToken: key.roomToken.value,
        scopeKey: scopeKey,
        threadId: Value(key.threadId),
        historyCursor: scope.historyCursor.value,
        futureCursor: scope.futureCursor.value,
        lastCommonRead: scope.lastCommonRead?.value ?? '0',
        lastReadMessage: scope.lastReadMessage,
        unreadMessages: scope.unreadMessages,
        hasHistory: scope.hasHistory,
        futureConverged: scope.futureConverged,
        blocksJson: _encodeBlocks(scope.blocks),
        lastSyncedAtMillis: wasSynced ? Value(syncedAt) : const Value.absent(),
        lastSyncError: wasSynced ? const Value(null) : const Value.absent(),
      );
      final stored = storedScopes[(key.roomToken.value, scopeKey)];
      // Readers only ask whether a scope was ever synced, so one that already
      // is does not need a fresh timestamp.
      final syncSettled =
          !wasSynced ||
          (stored?.lastSyncedAtMillis != null && stored?.lastSyncError == null);
      if (stored != null &&
          syncSettled &&
          stored.toCompanion(false) ==
              companion.copyWith(
                lastSyncedAtMillis: Value(stored.lastSyncedAtMillis),
                lastSyncError: Value(stored.lastSyncError),
              )) {
        continue;
      }
      changedScopes.add(companion);
    }

    final storedOperations = {
      for (final row in await (_database.select(
        _database.textSendOperations,
      )..where((row) => row.accountId.equals(accountId))).get())
        row.operationId: row,
    };
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final changedOperations = <TextSendOperationsCompanion>[];
    for (final operation in account.operations.values) {
      final existing = storedOperations[operation.operationId.value];
      final companion = TextSendOperationsCompanion.insert(
        accountId: accountId,
        operationId: operation.operationId.value,
        roomToken: operation.roomToken.value,
        referenceId: operation.referenceId.value,
        message: operation.message,
        replayContractRevision: operation.replayContractRevision,
        silent: Value(operation.silent),
        enqueueSequence: operation.enqueueSequence,
        outboxState: operation.state.name,
        attemptCount: operation.attemptCount,
        messageIdsJson: jsonEncode(operation.messageIds),
        duplicateRiskAcknowledged: operation.duplicateRiskAcknowledged,
        errorClass: Value(operation.errorClass),
        nextAttemptAt: Value(operation.nextAttemptAt),
        automaticResendCount: Value(operation.automaticResendCount),
        replyTo: Value(operation.replyTo),
        threadId: Value(operation.threadId),
        replyToToken: Value(operation.replyToToken?.value),
        parentRoomToken: Value(operation.parentRoomToken?.value),
        createdAtMillis: existing?.createdAtMillis ?? now,
        updatedAtMillis: now,
      );
      if (existing?.toCompanion(false).copyWith(updatedAtMillis: Value(now)) ==
          companion) {
        continue;
      }
      changedOperations.add(companion);
    }
    if (changedScopes.isNotEmpty || changedOperations.isNotEmpty) {
      await _database.batch((batch) {
        if (changedScopes.isNotEmpty) {
          batch.insertAllOnConflictUpdate(_database.chatScopes, changedScopes);
        }
        if (changedOperations.isNotEmpty) {
          batch.insertAllOnConflictUpdate(
            _database.textSendOperations,
            changedOperations,
          );
        }
      });
    }

    final messageList = messages.toList(growable: false);
    final conversationPreviewTimestamps =
        await _loadConversationPreviewTimestamps(
          accountId: accountId,
          messages: messageList,
        );
    final conversationPreviewUpdates =
        <String, ({int timestamp, String? text})>{};
    final threadReplyAccumulators = await _loadThreadReplyAccumulators(
      account,
      messageList,
    );
    final pendingMessages = <CachedChatMessagesCompanion>[];
    final pendingMessageKeys = <({String roomToken, int messageId})>{};
    for (final message in messageList) {
      final requiredMessage = _requiredPriorCachedMessage(message);
      final mutationProjectsIntoQuotedParents =
          message.systemMessage == 'message_edited' ||
          message.systemMessage == 'message_deleted';
      if (mutationProjectsIntoQuotedParents ||
          (requiredMessage != null &&
              pendingMessageKeys.contains(requiredMessage))) {
        await _flushPendingMessages(pendingMessages);
        pendingMessages.clear();
        pendingMessageKeys.clear();
      }
      await _refreshThreadOriginalFromNamedSend(account, message);
      await _refreshThreadOriginalFromParent(
        account,
        message,
        threadReplyAccumulators,
        adoptContent: !messagesAreSendResponse,
      );
      await _applyReactionsFromNotice(account, message);
      await _applyMutationFromNotice(account, message);
      final prepared = _prepareMessage(account, message);
      pendingMessages.add(prepared.companion);
      pendingMessageKeys.add((
        roomToken: message.roomToken.value,
        messageId: message.messageId,
      ));
      _trackConversationPreview(
        timestamps: conversationPreviewTimestamps,
        updates: conversationPreviewUpdates,
        message: message,
        displayText: prepared.displayText,
      );
    }
    await _flushPendingMessages(pendingMessages);
    await _persistConversationPreviews(
      accountId: accountId,
      updates: conversationPreviewUpdates,
    );
  }

  /// Carries somebody else's reaction over to the message it is about.
  ///
  /// Talk reports a reaction as a system message whose parent is the reacted
  /// message with a fresh `reactions` map. The notice itself is stored like
  /// any other message, but nothing used to touch the parent row, so a bubble
  /// only ever showed the reactions this device had added itself - anyone
  /// else's arrived on the server and never reached the cache, not even after
  /// reopening the conversation.
  Future<void> _applyReactionsFromNotice(
    ChatAccountState account,
    ChatMessage message,
  ) async {
    const notices = <String>{
      'reaction',
      'reaction_deleted',
      'reaction_revoked',
    };
    if (!notices.contains(message.systemMessage)) {
      return;
    }
    final parent = message.parent;
    if (parent is! ChatFullParent || parent.roomToken != message.roomToken) {
      return;
    }
    final accountId = account.accountId.value;
    final row =
        await (_database.select(_database.cachedChatMessages)..where(
              (candidate) =>
                  candidate.accountId.equals(accountId) &
                  candidate.roomToken.equals(message.roomToken.value) &
                  candidate.messageId.equals(parent.messageId),
            ))
            .getSingleOrNull();
    if (row == null) {
      return;
    }
    final ChatMessage cached;
    try {
      cached = ChatMessage.fromJson(jsonDecode(row.rawJson));
    } on Object {
      return;
    }
    if (cached.messageId != parent.messageId ||
        cached.roomToken != parent.roomToken) {
      return;
    }
    // Only the two reaction fields are taken across. The notice's parent is
    // authoritative about who reacted, not about an edit or a deletion that
    // may have landed on the cached row since.
    final wire = Map<String, Object?>.of(cached.wire)
      ..['reactions'] = parent.message.reactions
      ..['reactionsSelf'] = parent.message.reactionsSelf;
    await (_database.update(_database.cachedChatMessages)..where(
          (candidate) =>
              candidate.accountId.equals(accountId) &
              candidate.roomToken.equals(message.roomToken.value) &
              candidate.messageId.equals(parent.messageId),
        ))
        .write(CachedChatMessagesCompanion(rawJson: Value(jsonEncode(wire))));
  }

  /// Somebody else's edit or deletion arrives the same way a reaction does:
  /// as a `message_edited` / `message_deleted` notice whose `parent` is the
  /// message in its new state. The original is never sent again, so without
  /// this the bubble kept its old text (or the deleted file) for as long as
  /// the row lived in the cache — reproduced live 2026-09-03 with three
  /// deleted messages still rendered next to their "deleted a message" lines.
  Future<void> _applyMutationFromNotice(
    ChatAccountState account,
    ChatMessage message,
  ) async {
    const notices = <String>{'message_edited', 'message_deleted'};
    if (!notices.contains(message.systemMessage)) {
      return;
    }
    final parent = message.parent;
    if (parent is! ChatFullParent || parent.roomToken != message.roomToken) {
      return;
    }
    final accountId = account.accountId.value;
    final mutated = parent.message;
    final updated =
        await (_database.update(_database.cachedChatMessages)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.roomToken.equals(message.roomToken.value) &
                  row.messageId.equals(mutated.messageId),
            ))
            .write(
              CachedChatMessagesCompanion(
                actorType: Value(mutated.actorType),
                actorId: Value(mutated.actorId),
                actorDisplayName: Value(mutated.actorDisplayName),
                systemMessage: Value(mutated.systemMessage),
                messageType: Value(mutated.messageType),
                referenceId: Value(mutated.referenceId),
                displayText: Value(_displayText(account.server, mutated)),
                deleted: Value(mutated.deleted),
                rawJson: Value(jsonEncode(mutated.wire)),
              ),
            );
    if (updated == 0) {
      // Not cached here: the message lives outside the loaded blocks and
      // will arrive in its new state when history reaches it.
      return;
    }
    await _projectMutationIntoCachedParents(
      accountId: accountId,
      message: mutated,
    );
  }

  String _displayText(ServerBase server, ChatMessage message) {
    if (message.deleted) {
      return '';
    }
    final displayText = renderRichChatMessage(
      message: message.message,
      markdownEnabled: message.markdown ?? false,
      parameters: message.messageParameters,
      server: server,
    ).root.plainText.trim();
    return normalizeGiphyReferencePreview(displayText);
  }

  ({String roomToken, int messageId})? _requiredPriorCachedMessage(
    ChatMessage message,
  ) {
    final parent = message.parent;
    if (parent is ChatFullParent && parent.roomToken == message.roomToken) {
      return (roomToken: message.roomToken.value, messageId: parent.messageId);
    }
    final threadId = message.threadId;
    if (threadId == null ||
        message.messageId == threadId ||
        message.parent != null ||
        message.threadReplies == null) {
      return null;
    }
    return (roomToken: message.roomToken.value, messageId: threadId);
  }

  ({CachedChatMessagesCompanion companion, String displayText}) _prepareMessage(
    ChatAccountState account,
    ChatMessage message,
  ) {
    final displayText = _displayText(account.server, message);
    return (
      companion: CachedChatMessagesCompanion.insert(
        accountId: account.accountId.value,
        roomToken: message.roomToken.value,
        messageId: message.messageId,
        actorType: message.actorType,
        actorId: message.actorId,
        actorDisplayName: message.actorDisplayName,
        timestamp: message.timestamp,
        systemMessage: message.systemMessage,
        messageType: message.messageType,
        referenceId: message.referenceId,
        displayText: displayText,
        deleted: message.deleted,
        threadId: Value(message.threadId),
        rawJson: jsonEncode(message.wire),
      ),
      displayText: displayText,
    );
  }

  Future<void> _flushPendingMessages(
    List<CachedChatMessagesCompanion> pendingMessages,
  ) async {
    if (pendingMessages.isEmpty) {
      return;
    }
    await _database.batch(
      (batch) => batch.insertAllOnConflictUpdate(
        _database.cachedChatMessages,
        pendingMessages,
      ),
    );
  }

  Future<StoredChatScope?> _rootScope({
    required String accountId,
    required String roomToken,
  }) => _scope(accountId: accountId, roomToken: roomToken, threadId: null);

  Future<StoredChatScope?> _scope({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) {
    return (_database.select(_database.chatScopes)..where(
          (scope) =>
              scope.accountId.equals(accountId) &
              scope.roomToken.equals(roomToken) &
              scope.scopeKey.equals(_scopeKey(threadId)),
        ))
        .getSingleOrNull();
  }

  Future<StoredChatScope?> _networkScope({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) {
    return (_database.select(_database.chatScopes)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.roomToken.equals(roomToken) &
              row.scopeKey.equals(_networkScopeKey(threadId)),
        ))
        .getSingleOrNull();
  }
}
