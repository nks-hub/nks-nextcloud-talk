part of 'chat_repository.dart';

extension _ChatRepositoryThreadReplies on ChatRepository {
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
      // Reaction and deletion notices carry a thread id but are not replies.
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

    final accumulators = <_ThreadReplyScope, _ThreadReplyAccumulator>{
      for (final scope in fallbackScopes)
        scope: _ThreadReplyAccumulator(
          replyIds: incomingReplyIds[scope]!,
          cachedCountFloor: null,
        ),
    };
    final cached = _database.cachedChatMessages;
    final rootJson = CaseWhenExpression<String>(
      cases: [
        CaseWhen(
          cached.messageId.equalsExp(cached.threadId),
          then: cached.rawJson,
        ),
      ],
    );
    final roomTokens = fallbackScopes.map((scope) => scope.roomToken).toSet();
    final threadIds = fallbackScopes.map((scope) => scope.threadId).toSet();
    final rows =
        await (_database.selectOnly(cached)
              ..addColumns([
                cached.roomToken,
                cached.threadId,
                cached.messageId,
                rootJson,
              ])
              ..where(
                cached.accountId.equals(accountId) &
                    cached.roomToken.isIn(roomTokens) &
                    cached.threadId.isIn(threadIds) &
                    // Counting cached system notices made reactions and
                    // deletions look like thread replies after a recount.
                    cached.systemMessage.equals(''),
              ))
            .get();
    for (final row in rows) {
      final roomToken = row.read(cached.roomToken);
      final threadId = row.read(cached.threadId);
      final messageId = row.read(cached.messageId);
      if (roomToken == null || threadId == null || messageId == null) {
        continue;
      }
      final accumulator =
          accumulators[(
            accountId: accountId,
            roomToken: roomToken,
            threadId: threadId,
          )];
      if (accumulator == null) {
        // The two IN clauses may also return a room/thread cross-product.
        continue;
      }
      if (messageId == threadId) {
        final rawJson = row.read(rootJson);
        accumulator.cachedCountFloor = rawJson == null
            ? null
            : _storedThreadReplyCount(rawJson);
      } else {
        accumulator.replyIds.add(messageId);
      }
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

  Future<_PendingThreadRootUpdate?> _refreshThreadOriginalFromParent(
    ChatAccountState account,
    ChatMessage message,
    Map<_ThreadReplyScope, _ThreadReplyAccumulator> replyAccumulators, {
    required bool adoptContent,
  }) async {
    // Same rule as the accumulator: a system message about a reaction or a
    // deletion carries its thread, but it is not a reply to anything.
    if (message.systemMessage.isNotEmpty) {
      return null;
    }
    final parent = _matchingThreadParent(message);
    if (parent == null) {
      return null;
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
    if (!adoptContent) {
      // The parent in a send's response is a copy from when that response was
      // built, and it can arrive after a read that already saw the parent
      // edited or deleted. The cached row keeps its text and deletion state;
      // only what the reply is the authority on, its thread, is taken.
      final cachedRow =
          await (_database.select(_database.cachedChatMessages)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.roomToken.equals(message.roomToken.value) &
                    row.messageId.equals(threadId),
              ))
              .getSingleOrNull();
      if (cachedRow == null) {
        return null;
      }
      final cachedWire = Map<String, Object?>.of(
        jsonDecode(cachedRow.rawJson) as Map<String, Object?>,
      )..['threadReplies'] = threadReplies;
      for (final key in const ['threadId', 'isThread', 'threadTitle']) {
        if (original.wire.containsKey(key)) {
          cachedWire[key] = original.wire[key];
        }
      }
      await (_database.update(_database.cachedChatMessages)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.roomToken.equals(message.roomToken.value) &
                row.messageId.equals(threadId),
          ))
          .write(
            CachedChatMessagesCompanion(
              threadId: Value(threadId),
              rawJson: Value(jsonEncode(cachedWire)),
            ),
          );
      return null;
    }
    final originalWire = Map<String, Object?>.of(original.wire)
      ..['threadReplies'] = threadReplies;
    final displayText = _displayText(account.server, original);
    return (
      key: (roomToken: message.roomToken.value, messageId: threadId),
      companion: CachedChatMessagesCompanion(
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

  Future<void> _flushThreadRootUpdates({
    required String accountId,
    required Map<_ChatMessageKey, CachedChatMessagesCompanion> updates,
  }) async {
    if (updates.isEmpty) {
      return;
    }
    await _database.batch((batch) {
      for (final MapEntry(key: key, value: companion) in updates.entries) {
        batch.update(
          _database.cachedChatMessages,
          companion,
          where: (row) =>
              row.accountId.equals(accountId) &
              row.roomToken.equals(key.roomToken) &
              row.messageId.equals(key.messageId),
        );
      }
    });
  }
}
