part of 'chat_repository.dart';

extension _ChatRepositoryConversationPreviews on ChatRepository {
  Future<Map<String, int>> _loadConversationPreviewTimestamps({
    required String accountId,
    required Iterable<ChatMessage> messages,
  }) async {
    final roomTokens = messages
        .map((message) => message.roomToken.value)
        .toSet()
        .toList(growable: false);
    final result = <String, int>{};
    const chunkSize = 500;
    for (var offset = 0; offset < roomTokens.length; offset += chunkSize) {
      final end = offset + chunkSize < roomTokens.length
          ? offset + chunkSize
          : roomTokens.length;
      final chunk = roomTokens.sublist(offset, end);
      final rows =
          await (_database.select(_database.cachedConversations)..where(
                (conversation) =>
                    conversation.accountId.equals(accountId) &
                    conversation.token.isIn(chunk),
              ))
              .get();
      for (final row in rows) {
        result[row.token] = row.lastMessageTimestamp ?? -1;
      }
    }
    return result;
  }

  void _trackConversationPreview({
    required Map<String, int> timestamps,
    required Map<String, ({int timestamp, String? text})> updates,
    required ChatMessage message,
    required String displayText,
  }) {
    final roomToken = message.roomToken.value;
    final currentTimestamp = timestamps[roomToken];
    if (currentTimestamp == null || currentTimestamp > message.timestamp) {
      return;
    }
    timestamps[roomToken] = message.timestamp;
    updates[roomToken] = (
      timestamp: message.timestamp,
      text: displayText.isEmpty ? null : displayText,
    );
  }

  Future<void> _persistConversationPreviews({
    required String accountId,
    required Map<String, ({int timestamp, String? text})> updates,
  }) async {
    if (updates.isEmpty) {
      return;
    }
    await _database.batch((batch) {
      for (final MapEntry(key: roomToken, value: preview) in updates.entries) {
        batch.update(
          _database.cachedConversations,
          CachedConversationsCompanion(
            lastActivity: Value(preview.timestamp),
            lastMessageText: Value(preview.text),
            lastMessageTimestamp: Value(preview.timestamp),
          ),
          where: (row) =>
              row.accountId.equals(accountId) & row.token.equals(roomToken),
        );
      }
    });
  }
}
