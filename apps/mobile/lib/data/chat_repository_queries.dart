part of 'chat_repository.dart';

extension _ChatRepositoryQueries on ChatRepository {
  Stream<List<CachedChatMessage>> _watchMessagesQuery({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    final query = _database.select(_database.cachedChatMessages)
      ..where(
        (message) =>
            message.accountId.equals(accountId) &
            message.roomToken.equals(roomToken) &
            (threadId == null
                ? (message.threadId.isNull() |
                      message.threadId.equalsExp(message.messageId))
                : (message.threadId.equals(threadId) |
                      message.messageId.equals(threadId))),
      )
      ..orderBy([(message) => OrderingTerm.asc(message.messageId)]);
    return query.watch();
  }

  Future<bool?> _cachedRootIsNamedThreadQuery({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) async {
    if (threadId < 1) {
      throw ArgumentError.value(threadId, 'threadId');
    }
    final root =
        await (_database.select(_database.cachedChatMessages)..where(
              (message) =>
                  message.accountId.equals(accountId) &
                  message.roomToken.equals(roomToken) &
                  message.messageId.equals(threadId),
            ))
            .getSingleOrNull();
    if (root == null) {
      return null;
    }
    final message = ChatMessage.fromJson(jsonDecode(root.rawJson));
    if (message.messageId != threadId || message.roomToken.value != roomToken) {
      return null;
    }
    return message.isThread == true;
  }

  Stream<List<StoredTextSendOperation>> _watchTextSendOperationsQuery({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    final query = _database.select(_database.textSendOperations)
      ..where(
        (operation) =>
            operation.accountId.equals(accountId) &
            operation.roomToken.equals(roomToken) &
            (threadId == null
                ? operation.replyTo.isNull() & operation.threadId.isNull()
                : operation.replyTo.equals(threadId) |
                      operation.threadId.equals(threadId)),
      )
      ..orderBy([(operation) => OrderingTerm.asc(operation.enqueueSequence)]);
    return query.watch();
  }

  Stream<List<StoredOutgoingTextMessage>> _watchOutgoingTextMessagesQuery({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    final operations = _database.textSendOperations;
    final messages = _database.cachedChatMessages;
    final scopes = _database.chatScopes;
    final query =
        _database.select(operations).join([
            leftOuterJoin(
              messages,
              messages.accountId.equalsExp(operations.accountId) &
                  messages.roomToken.equalsExp(operations.roomToken) &
                  messages.referenceId.equalsExp(operations.referenceId),
            ),
            leftOuterJoin(
              scopes,
              scopes.accountId.equalsExp(operations.accountId) &
                  scopes.roomToken.equalsExp(operations.roomToken) &
                  scopes.scopeKey.equals(_scopeKey(threadId)),
            ),
          ])
          ..where(
            operations.accountId.equals(accountId) &
                operations.roomToken.equals(roomToken) &
                (threadId == null
                    ? operations.replyTo.isNull() & operations.threadId.isNull()
                    : operations.replyTo.equals(threadId) |
                          operations.threadId.equals(threadId)),
          )
          ..orderBy([
            OrderingTerm.asc(operations.enqueueSequence),
            OrderingTerm.asc(messages.messageId),
          ]);
    return query.watch().map((rows) {
      final grouped = <String, _OutgoingTextMessageAccumulator>{};
      for (final row in rows) {
        final operation = row.readTable(operations);
        final scope = row.readTableOrNull(scopes);
        final accumulator = grouped.putIfAbsent(
          operation.operationId,
          () => _OutgoingTextMessageAccumulator(
            operation,
            lastCommonRead: scope == null
                ? null
                : ChatCursor.parse(
                    scope.lastCommonRead,
                    path: r'$.chatScopes.lastCommonRead',
                  ),
          ),
        );
        final message = row.readTableOrNull(messages);
        if (message != null &&
            accumulator.confirmedMessageIds.contains(message.messageId)) {
          accumulator.confirmedMessages[message.messageId] = message;
        }
      }
      return grouped.values
          .map((accumulator) => accumulator.build())
          .toList(growable: false);
    });
  }

  Stream<StoredChatScope?> _watchRootScopeQuery({
    required String accountId,
    required String roomToken,
  }) => _watchScopeQuery(
    accountId: accountId,
    roomToken: roomToken,
    threadId: null,
  );

  Stream<StoredChatScope?> _watchScopeQuery({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) {
    return (_database.select(_database.chatScopes)
          ..where(
            (scope) =>
                scope.accountId.equals(accountId) &
                scope.roomToken.equals(roomToken) &
                scope.scopeKey.equals(_scopeKey(threadId)),
          )
          ..limit(1))
        .watchSingleOrNull();
  }

  Future<CachedConversation?> _getConversationQuery({
    required String accountId,
    required String roomToken,
  }) {
    return (_database.select(_database.cachedConversations)..where(
          (conversation) =>
              conversation.accountId.equals(accountId) &
              conversation.token.equals(roomToken),
        ))
        .getSingleOrNull();
  }
}
