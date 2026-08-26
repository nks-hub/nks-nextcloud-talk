part of 'chat_repository.dart';

extension _ChatRepositoryMutations on ChatRepository {
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
  }) async {
    final rows =
        await (_database.select(_database.cachedChatMessages)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.roomToken.equals(message.roomToken.value),
            ))
            .get();
    for (final row in rows) {
      if (row.messageId == message.messageId) {
        continue;
      }
      final ChatMessage cached;
      try {
        cached = ChatMessage.fromJson(jsonDecode(row.rawJson));
      } on FormatException {
        continue;
      } on TalkProtocolException {
        continue;
      }
      final updated = cached.replaceParentMessageIfMatching(message);
      if (identical(updated, cached)) {
        continue;
      }
      await (_database.update(_database.cachedChatMessages)..where(
            (candidate) =>
                candidate.accountId.equals(accountId) &
                candidate.roomToken.equals(message.roomToken.value) &
                candidate.messageId.equals(row.messageId),
          ))
          .write(
            CachedChatMessagesCompanion(
              rawJson: Value(jsonEncode(updated.wire)),
            ),
          );
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
    if (conversation == null ||
        (conversation.lastMessageTimestamp ?? -1) > message.timestamp) {
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
