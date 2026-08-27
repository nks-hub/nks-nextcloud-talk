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
    await _writeNetworkBackedViewScope(
      networkScope: networkScope,
      viewThreadId: null,
      viewScope: rootView,
    );
    final viewScopes =
        await (_database.select(_database.chatScopes)..where(
              (scope) =>
                  scope.accountId.equals(accountId) &
                  scope.roomToken.equals(roomToken) &
                  scope.threadId.isNotNull(),
            ))
            .get();
    for (final viewScope in viewScopes) {
      final viewThreadId = viewScope.threadId!;
      if (viewScope.scopeKey != _scopeKey(viewThreadId)) {
        continue;
      }
      if (!preservedViewThreadIds.contains(viewThreadId) &&
          !await _cachedRootIsOrdinary(
            accountId: accountId,
            roomToken: roomToken,
            messageId: viewThreadId,
          )) {
        continue;
      }
      await _writeNetworkBackedViewScope(
        networkScope: networkScope,
        viewThreadId: viewThreadId,
        viewScope: viewScope,
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
    final result = <int>{};
    for (final viewScope in viewScopes) {
      final threadId = viewScope.threadId!;
      if (viewScope.scopeKey != _scopeKey(threadId)) {
        continue;
      }
      final named = await cachedRootIsNamedThread(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
      );
      if (named != true) {
        result.add(threadId);
      }
    }
    return result;
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
    final replyTo = operation.replyTo;
    final namedThreadId = operation.threadId;
    if (replyTo != null && namedThreadId != null) {
      return;
    }
    final viewThreadId = namedThreadId ?? replyTo;
    if (operation.replyToToken != null ||
        (operation.parentRoomToken != null &&
            operation.parentRoomToken != operation.roomToken) ||
        message.roomToken != operation.roomToken) {
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
      roomToken: operation.roomToken.value,
      threadId: viewThreadId,
    );
    final networkScope = await _networkScope(
      accountId: accountId,
      roomToken: operation.roomToken.value,
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
    final blocks = mergeChatBlocks(<ChatBlock>[
      ..._decodeBlocks(networkScope.blocksJson),
      if (viewScope != null) ..._decodeBlocks(viewScope.blocksJson),
      ...extraBlocks,
    ]);
    await _database
        .into(_database.chatScopes)
        .insertOnConflictUpdate(
          ChatScopesCompanion.insert(
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
          ),
        );
  }

  Future<bool> _cachedRootIsOrdinary({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) async {
    final row =
        await (_database.select(_database.cachedChatMessages)..where(
              (message) =>
                  message.accountId.equals(accountId) &
                  message.roomToken.equals(roomToken) &
                  message.messageId.equals(messageId),
            ))
            .getSingleOrNull();
    if (row == null) {
      return false;
    }
    try {
      final message = ChatMessage.fromJson(jsonDecode(row.rawJson));
      return message.messageId == messageId &&
          message.roomToken.value == roomToken &&
          message.isThread != true;
    } on Object {
      return false;
    }
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
    final messageRows = await (_database.select(
      _database.cachedChatMessages,
    )..where((row) => row.accountId.equals(accountId))).get();
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
          messageRows
              .where((message) => message.roomToken == row.roomToken)
              .where(
                (message) => networkThreadId == null
                    ? message.threadId == null ||
                          message.threadId == message.messageId
                    : message.threadId == networkThreadId,
              )
              .where((message) {
                final cursor = ChatCursor.parse(message.messageId.toString());
                return blocks.any((block) => block.contains(cursor));
              })
              .map((message) => message.messageId)
              .toList()
            ..sort();
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
        enqueueSequence: row.enqueueSequence,
        state: _outboxState(row.outboxState),
        attemptCount: row.attemptCount,
        messageIds: _decodeMessageIds(row.messageIdsJson),
        duplicateRiskAcknowledged: row.duplicateRiskAcknowledged,
        errorClass: row.errorClass,
        nextAttemptAt: row.nextAttemptAt,
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
  }) async {
    await (_database.update(
      _database.chatCapabilities,
    )..where((row) => row.accountId.equals(account.accountId.value))).write(
      ChatCapabilitiesCompanion(
        generation: Value(account.capabilityGeneration),
        credentialGeneration: Value(account.credentialGeneration),
        lane: Value(account.lane.name),
        updatedAtMillis: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
      ),
    );

    final syncedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final entry in account.scopes.entries) {
      final key = entry.key;
      final scope = entry.value;
      final wasSynced = syncedScope == key;
      await _database
          .into(_database.chatScopes)
          .insertOnConflictUpdate(
            ChatScopesCompanion.insert(
              accountId: account.accountId.value,
              roomToken: key.roomToken.value,
              scopeKey: _networkScopeKey(key.threadId),
              threadId: Value(key.threadId),
              historyCursor: scope.historyCursor.value,
              futureCursor: scope.futureCursor.value,
              lastCommonRead: scope.lastCommonRead?.value ?? '0',
              lastReadMessage: scope.lastReadMessage,
              unreadMessages: scope.unreadMessages,
              hasHistory: scope.hasHistory,
              futureConverged: scope.futureConverged,
              blocksJson: _encodeBlocks(scope.blocks),
              lastSyncedAtMillis: wasSynced
                  ? Value(syncedAt)
                  : const Value.absent(),
              lastSyncError: wasSynced
                  ? const Value(null)
                  : const Value.absent(),
            ),
          );
    }

    for (final operation in account.operations.values) {
      final existing =
          await (_database.select(_database.textSendOperations)..where(
                (row) =>
                    row.accountId.equals(account.accountId.value) &
                    row.operationId.equals(operation.operationId.value),
              ))
              .getSingleOrNull();
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _database
          .into(_database.textSendOperations)
          .insertOnConflictUpdate(
            TextSendOperationsCompanion.insert(
              accountId: account.accountId.value,
              operationId: operation.operationId.value,
              roomToken: operation.roomToken.value,
              referenceId: operation.referenceId.value,
              message: operation.message,
              replayContractRevision: operation.replayContractRevision,
              enqueueSequence: operation.enqueueSequence,
              outboxState: operation.state.name,
              attemptCount: operation.attemptCount,
              messageIdsJson: jsonEncode(operation.messageIds),
              duplicateRiskAcknowledged: operation.duplicateRiskAcknowledged,
              errorClass: Value(operation.errorClass),
              nextAttemptAt: Value(operation.nextAttemptAt),
              replyTo: Value(operation.replyTo),
              threadId: Value(operation.threadId),
              replyToToken: Value(operation.replyToToken?.value),
              parentRoomToken: Value(operation.parentRoomToken?.value),
              createdAtMillis: existing?.createdAtMillis ?? now,
              updatedAtMillis: now,
            ),
          );
    }

    final messageList = messages.toList(growable: false);
    final threadReplyAccumulators = await _loadThreadReplyAccumulators(
      account,
      messageList,
    );
    for (final message in messageList) {
      await _refreshThreadOriginalFromNamedSend(account, message);
      await _refreshThreadOriginalFromParent(
        account,
        message,
        threadReplyAccumulators,
      );
      await _persistMessage(account, message);
    }
  }

  Future<Map<_ThreadReplyScope, _ThreadReplyAccumulator>>
  _loadThreadReplyAccumulators(
    ChatAccountState account,
    List<ChatMessage> messages,
  ) async {
    final accountId = account.accountId.value;
    final fallbackScopes = <_ThreadReplyScope>{};
    for (final message in messages) {
      final parent = _matchingThreadParent(message);
      if (parent != null && parent.message.threadReplies == null) {
        fallbackScopes.add((
          accountId: accountId,
          roomToken: message.roomToken.value,
          threadId: message.threadId!,
        ));
      }
    }
    if (fallbackScopes.isEmpty) {
      return const <_ThreadReplyScope, _ThreadReplyAccumulator>{};
    }

    final incomingReplyIds = <_ThreadReplyScope, Set<int>>{
      for (final scope in fallbackScopes) scope: <int>{},
    };
    for (final message in messages) {
      final threadId = message.threadId;
      if (threadId == null || threadId < 1 || message.messageId == threadId) {
        continue;
      }
      // A reaction and a deletion notice both arrive as system messages
      // carrying the thread they belong to. Counting those made a bubble
      // claim "1 reply" the moment somebody reacted to it, or deleted
      // something in the thread — neither is a reply.
      if (message.systemMessage.isNotEmpty) {
        continue;
      }
      final scope = (
        accountId: accountId,
        roomToken: message.roomToken.value,
        threadId: threadId,
      );
      incomingReplyIds[scope]?.add(message.messageId);
    }

    final messageIdColumn = _database.cachedChatMessages.messageId;
    final rawJsonColumn = _database.cachedChatMessages.rawJson;
    final accumulators = <_ThreadReplyScope, _ThreadReplyAccumulator>{};
    for (final scope in fallbackScopes) {
      final rows =
          await (_database.selectOnly(_database.cachedChatMessages)
                ..addColumns([messageIdColumn, rawJsonColumn])
                ..where(
                  _database.cachedChatMessages.accountId.equals(
                        scope.accountId,
                      ) &
                      _database.cachedChatMessages.roomToken.equals(
                        scope.roomToken,
                      ) &
                      _database.cachedChatMessages.threadId.equals(
                        scope.threadId,
                      ) &
                      // Reactions and deletion notices are cached like any
                      // other message and carry the thread they belong to.
                      // Counting them here is what made a wrong "1 reply"
                      // survive every later recount, not just appear once.
                      _database.cachedChatMessages.systemMessage.equals(''),
                ))
              .get();
      final replyIds = incomingReplyIds[scope]!;
      int? cachedCountFloor;
      for (final row in rows) {
        final messageId = row.read(messageIdColumn);
        if (messageId == null) {
          continue;
        }
        if (messageId == scope.threadId) {
          final rawJson = row.read(rawJsonColumn);
          cachedCountFloor = rawJson == null
              ? null
              : _storedThreadReplyCount(rawJson);
        } else {
          replyIds.add(messageId);
        }
      }
      accumulators[scope] = _ThreadReplyAccumulator(
        replyIds: replyIds,
        cachedCountFloor: cachedCountFloor,
      );
    }
    return accumulators;
  }

  Future<void> _refreshThreadOriginalFromNamedSend(
    ChatAccountState account,
    ChatMessage message,
  ) async {
    final threadId = message.threadId;
    final threadReplies = message.threadReplies;
    if (threadId == null ||
        message.messageId == threadId ||
        message.parent != null ||
        threadReplies == null) {
      return;
    }
    final accountId = account.accountId.value;
    final root =
        await (_database.select(_database.cachedChatMessages)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.roomToken.equals(message.roomToken.value) &
                  row.messageId.equals(threadId),
            ))
            .getSingleOrNull();
    if (root == null) {
      return;
    }
    final original = ChatMessage.fromJson(jsonDecode(root.rawJson));
    if (original.messageId != threadId ||
        original.roomToken != message.roomToken) {
      return;
    }
    final originalWire = Map<String, Object?>.of(original.wire)
      ..['threadId'] = threadId
      ..['isThread'] = true
      ..['threadReplies'] = threadReplies;
    await (_database.update(_database.cachedChatMessages)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.roomToken.equals(message.roomToken.value) &
              row.messageId.equals(threadId),
        ))
        .write(
          CachedChatMessagesCompanion(
            threadId: Value(threadId),
            rawJson: Value(jsonEncode(originalWire)),
          ),
        );
  }

  Future<void> _refreshThreadOriginalFromParent(
    ChatAccountState account,
    ChatMessage message,
    Map<_ThreadReplyScope, _ThreadReplyAccumulator> replyAccumulators,
  ) async {
    // Same rule as the accumulator: a system message about a reaction or a
    // deletion carries its thread, but it is not a reply to anything.
    if (message.systemMessage.isNotEmpty) {
      return;
    }
    final parent = _matchingThreadParent(message);
    if (parent == null) {
      return;
    }

    final accountId = account.accountId.value;
    final threadId = message.threadId!;
    final original = parent.message;
    final serverCount = original.threadReplies;
    final accumulator =
        replyAccumulators[(
          accountId: accountId,
          roomToken: message.roomToken.value,
          threadId: threadId,
        )];
    final threadReplies = serverCount == null
        ? accumulator!.resolve(null)
        : accumulator?.resolve(serverCount) ?? serverCount;
    final originalWire = Map<String, Object?>.of(original.wire)
      ..['threadReplies'] = threadReplies;
    final displayText = _displayText(account.server, original);
    await (_database.update(_database.cachedChatMessages)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.roomToken.equals(message.roomToken.value) &
              row.messageId.equals(threadId),
        ))
        .write(
          CachedChatMessagesCompanion(
            actorType: Value(original.actorType),
            actorId: Value(original.actorId),
            actorDisplayName: Value(original.actorDisplayName),
            timestamp: Value(original.timestamp),
            systemMessage: Value(original.systemMessage),
            messageType: Value(original.messageType),
            referenceId: Value(original.referenceId),
            displayText: Value(displayText),
            deleted: Value(original.deleted),
            threadId: Value(threadId),
            rawJson: Value(jsonEncode(originalWire)),
          ),
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
    ).root.flattenedText.trim();
    return normalizeGiphyReferencePreview(displayText);
  }

  Future<void> _persistMessage(
    ChatAccountState account,
    ChatMessage message,
  ) async {
    final displayText = _displayText(account.server, message);
    await _database
        .into(_database.cachedChatMessages)
        .insertOnConflictUpdate(
          CachedChatMessagesCompanion.insert(
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
        );

    final conversation = await getConversation(
      accountId: account.accountId.value,
      roomToken: message.roomToken.value,
    );
    if (conversation == null ||
        (conversation.lastMessageTimestamp ?? -1) > message.timestamp) {
      return;
    }
    await (_database.update(_database.cachedConversations)..where(
          (row) =>
              row.accountId.equals(account.accountId.value) &
              row.token.equals(message.roomToken.value),
        ))
        .write(
          CachedConversationsCompanion(
            lastActivity: Value(message.timestamp),
            lastMessageText: Value(displayText.isEmpty ? null : displayText),
            lastMessageTimestamp: Value(message.timestamp),
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
