part of 'chat_repository.dart';

/// The cached row exists, but cannot represent a canonical thread root.
final class InvalidCachedThreadRootException implements Exception {
  const InvalidCachedThreadRootException();

  @override
  String toString() => 'InvalidCachedThreadRootException()';
}

/// Strict cached-thread classification for admission and other mutations.
extension ValidatedChatRepositoryThreadQueries on ChatRepository {
  Future<bool?> validatedCachedRootIsNamedThread({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) => _validatedCachedRootIsNamedThreadQuery(
    this,
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
  );
}

/// Reads for an open room that do not load its whole cached history.
extension ChatRepositoryMessageWindow on ChatRepository {
  /// The newest [limit] messages of a room's main timeline, oldest first.
  ///
  /// The cache is never pruned, so the unbounded read grew with the room and
  /// ran again on every write to the table.
  Stream<List<CachedChatMessage>> watchRecentMessages({
    required String accountId,
    required String roomToken,
    required int limit,
    bool includeThreadReplies = false,
  }) {
    final query = _database.select(_database.cachedChatMessages)
      ..where(
        (message) => _timelineMessages(
          message,
          accountId: accountId,
          roomToken: roomToken,
          threadId: null,
          includeThreadReplies: includeThreadReplies,
        ),
      )
      ..orderBy([(message) => OrderingTerm.desc(message.messageId)])
      ..limit(limit);
    return query.watch().map((rows) => rows.reversed.toList(growable: false));
  }

  /// The thread root and its newest [limit] replies, oldest first.
  ///
  /// The root is selected separately so a deep thread cannot push it out of
  /// the bounded reply window. The inner descending query can walk the thread
  /// index from its newest edge; only the bounded result is sorted for display.
  Stream<List<CachedChatMessage>> watchRecentThreadMessages({
    required String accountId,
    required String roomToken,
    required int threadId,
    required int limit,
  }) {
    if (threadId < 1) {
      throw ArgumentError.value(threadId, 'threadId');
    }
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit');
    }
    final notices = _ChatRepositoryQueries._noticeSystemMessages;
    final noticeSlots = List.filled(notices.length, '?').join(', ');
    final table = _database.cachedChatMessages;
    final query = _database.customSelect(
      '''
        SELECT bounded.*
          FROM (
            SELECT root.*
              FROM cached_chat_messages AS root
             WHERE root.account_id = ?
               AND root.room_token = ?
               AND root.message_id = ?
               AND root.system_message NOT IN ($noticeSlots)
            UNION ALL
            SELECT replies.*
              FROM (
                SELECT reply.*
                  FROM cached_chat_messages AS reply
                 WHERE reply.account_id = ?
                   AND reply.room_token = ?
                   AND reply.thread_id = ?
                   AND reply.message_id <> ?
                   AND reply.system_message NOT IN ($noticeSlots)
                 ORDER BY reply.message_id DESC
                 LIMIT ?
              ) AS replies
          ) AS bounded
         ORDER BY bounded.message_id ASC
      ''',
      variables: [
        Variable.withString(accountId),
        Variable.withString(roomToken),
        Variable.withInt(threadId),
        for (final notice in notices) Variable.withString(notice),
        Variable.withString(accountId),
        Variable.withString(roomToken),
        Variable.withInt(threadId),
        Variable.withInt(threadId),
        for (final notice in notices) Variable.withString(notice),
        Variable.withInt(limit),
      ],
      readsFrom: {table},
    );
    return query.watch().map(
      (rows) => <CachedChatMessage>[
        for (final row in rows) table.map(row.data),
      ],
    );
  }

  /// How many main-timeline messages are at or after [messageId]: the window
  /// [watchRecentMessages] needs to reach it.
  Future<int> countMessagesFrom({
    required String accountId,
    required String roomToken,
    required int messageId,
    bool includeThreadReplies = false,
  }) async {
    final messages = _database.cachedChatMessages;
    final count = messages.messageId.count();
    final query = _database.selectOnly(messages)
      ..addColumns([count])
      ..where(
        _timelineMessages(
              messages,
              accountId: accountId,
              roomToken: roomToken,
              threadId: null,
              includeThreadReplies: includeThreadReplies,
            ) &
            messages.messageId.isBiggerOrEqualValue(messageId),
      );
    return (await query.getSingle()).read(count) ?? 0;
  }

  /// The range from the [before]th cached timeline message older than
  /// [messageId] to the [after]th newer one, fewer where the cache ends.
  /// [threadId] narrows it to that thread's timeline.
  Future<({int first, int last})> cachedRangeAround({
    required String accountId,
    required String roomToken,
    required int messageId,
    int? threadId,
    bool includeThreadReplies = false,
    int before = 100,
    int after = 100,
  }) async {
    final messages = _database.cachedChatMessages;
    Future<int?> edge({required bool older, required int count}) async {
      if (count < 1) return null;
      final rows =
          await (_database.selectOnly(messages)
                ..addColumns([messages.messageId])
                ..where(
                  _timelineMessages(
                        messages,
                        accountId: accountId,
                        roomToken: roomToken,
                        threadId: threadId,
                        includeThreadReplies: includeThreadReplies,
                      ) &
                      (older
                          ? messages.messageId.isSmallerThanValue(messageId)
                          : messages.messageId.isBiggerThanValue(messageId)),
                )
                ..orderBy([
                  OrderingTerm(
                    expression: messages.messageId,
                    mode: older ? OrderingMode.desc : OrderingMode.asc,
                  ),
                ])
                ..limit(count))
              .get();
      return rows.isEmpty ? null : rows.last.read(messages.messageId);
    }

    return (
      first: await edge(older: true, count: before) ?? messageId,
      last: await edge(older: false, count: after) ?? messageId,
    );
  }

  /// Thread replies at or after [messageId], excluding the always-visible root.
  Future<int> countThreadRepliesFrom({
    required String accountId,
    required String roomToken,
    required int threadId,
    required int messageId,
  }) async {
    if (threadId < 1) {
      throw ArgumentError.value(threadId, 'threadId');
    }
    if (messageId == threadId) {
      return 0;
    }
    final messages = _database.cachedChatMessages;
    final count = messages.messageId.count();
    final query = _database.selectOnly(messages)
      ..addColumns([count])
      ..where(
        messages.accountId.equals(accountId) &
            messages.roomToken.equals(roomToken) &
            messages.threadId.equals(threadId) &
            messages.messageId.equals(threadId).not() &
            messages.messageId.isBiggerOrEqualValue(messageId) &
            messages.systemMessage.isNotIn(
              _ChatRepositoryQueries._noticeSystemMessages,
            ),
      );
    return (await query.getSingle()).read(count) ?? 0;
  }

  /// One message, as a list so it reads like the timeline does: empty while
  /// it is not cached.
  Stream<List<CachedChatMessage>> watchMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) {
    return (_database.select(_database.cachedChatMessages)..where(
          (message) =>
              message.accountId.equals(accountId) &
              message.roomToken.equals(roomToken) &
              message.messageId.equals(messageId),
        ))
        .watch();
  }
}

Expression<bool> _timelineMessages(
  $CachedChatMessagesTable message, {
  required String accountId,
  required String roomToken,
  required int? threadId,
  required bool includeThreadReplies,
}) {
  return message.accountId.equals(accountId) &
      message.roomToken.equals(roomToken) &
      message.systemMessage.isNotIn(
        _ChatRepositoryQueries._noticeSystemMessages,
      ) &
      (threadId == null
          ? (includeThreadReplies
                ? const Constant(true)
                : (message.threadId.isNull() |
                      message.threadId.equalsExp(message.messageId)))
          : (message.threadId.equals(threadId) |
                message.messageId.equals(threadId)));
}

extension _ChatRepositoryQueries on ChatRepository {
  /// System messages the timeline never shows, because the thing they
  /// announce is already visible on the message they point at.
  ///
  /// Reported from the field 2026-09-03: deleting two messages left four rows
  /// — two „Message deleted" bubbles and two „You deleted a message" lines.
  /// Upstream Android drops exactly these before rendering
  /// (`ChatViewModel.shouldRemoveMessage`: message_deleted with a parent,
  /// the three reaction kinds, poll_voted, message_edited, thread_created).
  /// They stay in the cache — the parent update is derived from them.
  static const _noticeSystemMessages = <String>[
    'message_deleted',
    'message_edited',
    'reaction',
    'reaction_deleted',
    'reaction_revoked',
    'poll_voted',
    'thread_created',
  ];

  SimpleSelectStatement<$CachedChatMessagesTable, CachedChatMessage>
  _messagesQuery({
    required String accountId,
    required String roomToken,
    int? threadId,
    bool includeThreadReplies = false,
  }) {
    final query = _database.select(_database.cachedChatMessages)
      ..where(
        (message) => _timelineMessages(
          message,
          accountId: accountId,
          roomToken: roomToken,
          threadId: threadId,
          includeThreadReplies: includeThreadReplies,
        ),
      )
      ..orderBy([(message) => OrderingTerm.asc(message.messageId)]);
    return query;
  }

  Future<bool?> _cachedRootIsNamedThreadQuery({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) async {
    try {
      return await _validatedCachedRootIsNamedThreadQuery(
        this,
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
      );
    } on InvalidCachedThreadRootException {
      return null;
    }
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

Future<bool?> _validatedCachedRootIsNamedThreadQuery(
  ChatRepository repository, {
  required String accountId,
  required String roomToken,
  required int threadId,
}) async {
  if (threadId < 1) {
    throw ArgumentError.value(threadId, 'threadId');
  }
  final root =
      await (repository._database.select(
            repository._database.cachedChatMessages,
          )..where(
            (message) =>
                message.accountId.equals(accountId) &
                message.roomToken.equals(roomToken) &
                message.messageId.equals(threadId),
          ))
          .getSingleOrNull();
  if (root == null) {
    return null;
  }
  return _classifyCachedRootAsNamedThread(
    root,
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
  );
}

bool _classifyCachedRootAsNamedThread(
  CachedChatMessage root, {
  required String accountId,
  required String roomToken,
  required int threadId,
}) {
  if (threadId < 1) {
    throw ArgumentError.value(threadId, 'threadId');
  }
  if (root.accountId != accountId ||
      root.roomToken != roomToken ||
      root.messageId != threadId ||
      root.deleted ||
      root.systemMessage.isNotEmpty ||
      !_isCanonicalCachedRootThreadId(root.threadId, threadId)) {
    throw const InvalidCachedThreadRootException();
  }

  final ChatMessage message;
  try {
    message = ChatMessage.fromJson(jsonDecode(root.rawJson));
  } on FormatException {
    throw const InvalidCachedThreadRootException();
  } on TalkProtocolException {
    throw const InvalidCachedThreadRootException();
  }
  if (message.messageId != threadId ||
      message.roomToken.value != roomToken ||
      message.deleted ||
      message.systemMessage.isNotEmpty ||
      !_isCanonicalCachedRootThreadId(message.threadId, threadId) ||
      root.threadId != message.threadId) {
    throw const InvalidCachedThreadRootException();
  }
  if (message.isThread != true) {
    return false;
  }
  final title = message.threadTitle?.trim();
  if (root.threadId != threadId ||
      message.threadId != threadId ||
      title == null ||
      title.isEmpty ||
      title.length > 200) {
    throw const InvalidCachedThreadRootException();
  }
  return true;
}

bool _isCanonicalCachedRootThreadId(int? value, int rootMessageId) =>
    value == null || value == 0 || value == rootMessageId;
