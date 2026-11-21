part of 'chat_repository.dart';

extension _ChatRepositoryMutations on ChatRepository {
  Future<void> _flushMutationTargetUpdates({
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

  Future<void> _applyMessageMutation({
    required String accountId,
    required ServerBase server,
    required ChatMessage message,
  }) {
    return _database.transaction(() async {
      final displayText = _displayText(server, message);
      await _database
          .into(_database.cachedChatMessages)
          .insertOnConflictUpdate(
            CachedChatMessagesCompanion.insert(
              accountId: accountId,
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
      await _projectMutationIntoCachedParents(
        accountId: accountId,
        message: message,
      );
      await _updateConversationPreviewAfterMutation(
        accountId: accountId,
        message: message,
        displayText: displayText,
      );
    });
  }

  Future<void> _projectMutationIntoCachedParents({
    required String accountId,
    required ChatMessage message,
  }) => _projectMutationsIntoCachedParents(
    accountId: accountId,
    messages: <ChatMessage>[message],
  );

  Future<void> _projectMutationsIntoCachedParents({
    required String accountId,
    required Iterable<ChatMessage> messages,
  }) async {
    final mutationsByRoom = <String, Map<int, ChatMessage>>{};
    for (final message in messages) {
      (mutationsByRoom[message.roomToken.value] ??=
              <int, ChatMessage>{})[message.messageId] =
          message;
    }
    if (mutationsByRoom.isEmpty) {
      return;
    }
    final parentUpdates =
        <({String roomToken, int messageId, String rawJson})>[];
    const targetChunkSize = 100;
    for (final MapEntry(key: roomToken, value: mutations)
        in mutationsByRoom.entries) {
      final targetIds = mutations.keys.toList(growable: false);
      for (
        var offset = 0;
        offset < targetIds.length;
        offset += targetChunkSize
      ) {
        final end = offset + targetChunkSize < targetIds.length
            ? offset + targetChunkSize
            : targetIds.length;
        final chunk = targetIds.sublist(offset, end);
        final chunkMutations = <int, ChatMessage>{
          for (final targetId in chunk) targetId: mutations[targetId]!,
        };
        final minimumTargetId = chunk.reduce(
          (minimum, value) => value < minimum ? value : minimum,
        );
        // The JSON predicates keep the read bounded. Exact parent ids are
        // still checked after decoding because a longer id can share digits.
        final rows =
            await (_database.select(_database.cachedChatMessages)..where((row) {
                  Expression<bool> targetFilter = row.rawJson.like(
                    '%"id":${chunk.first}%',
                  );
                  for (final targetId in chunk.skip(1)) {
                    targetFilter =
                        targetFilter | row.rawJson.like('%"id":$targetId%');
                  }
                  return row.accountId.equals(accountId) &
                      row.roomToken.equals(roomToken) &
                      row.messageId.isBiggerThanValue(minimumTargetId) &
                      row.rawJson.like('%"parent":%') &
                      targetFilter;
                }))
                .get();
        for (final row in rows) {
          final ChatMessage cached;
          try {
            cached = ChatMessage.fromJson(jsonDecode(row.rawJson));
          } on FormatException {
            continue;
          } on TalkProtocolException {
            continue;
          }
          final parent = cached.parent;
          if (parent is! ChatFullParent) {
            continue;
          }
          final mutation = chunkMutations[parent.messageId];
          if (mutation == null) {
            continue;
          }
          final updated = cached.replaceParentMessageIfMatching(mutation);
          if (identical(updated, cached)) {
            continue;
          }
          parentUpdates.add((
            roomToken: roomToken,
            messageId: row.messageId,
            rawJson: jsonEncode(updated.wire),
          ));
        }
      }
    }
    if (parentUpdates.isNotEmpty) {
      await _database.batch((batch) {
        for (final update in parentUpdates) {
          batch.update(
            _database.cachedChatMessages,
            CachedChatMessagesCompanion(rawJson: Value(update.rawJson)),
            where: (candidate) =>
                candidate.accountId.equals(accountId) &
                candidate.roomToken.equals(update.roomToken) &
                candidate.messageId.equals(update.messageId),
          );
        }
      });
    }
  }

  Future<void> _updateConversationPreviewAfterMutation({
    required String accountId,
    required ChatMessage message,
    required String displayText,
  }) async {
    final conversation = await getConversation(
      accountId: accountId,
      roomToken: message.roomToken.value,
    );
    // A room whose preview timestamp is not known yet must not take the
    // timestamp of whatever message happens to be written next: re-reading an
    // OLD message to repair it would otherwise push the room to the top of the
    // list carrying that old message's text.
    if (conversation == null ||
        (conversation.lastMessageTimestamp ?? -1) > message.timestamp ||
        (conversation.lastMessageTimestamp == null &&
            (conversation.lastActivity) > message.timestamp)) {
      return;
    }
    await (_database.update(_database.cachedConversations)..where(
          (row) =>
              row.accountId.equals(accountId) &
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
}
