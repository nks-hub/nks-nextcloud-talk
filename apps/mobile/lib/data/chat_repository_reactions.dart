part of 'chat_repository.dart';

typedef _CachedReactionMessage = ({ChatMessage message, String rawJson});

extension _ChatRepositoryReactions on ChatRepository {
  static const _reactionNotices = <String>{
    'reaction',
    'reaction_deleted',
    'reaction_revoked',
  };

  Future<Map<_ChatMessageKey, _CachedReactionMessage?>> _loadReactionMessages({
    required String accountId,
    required Iterable<ChatMessage> messages,
  }) async {
    final idsByRoom = <String, Set<int>>{};
    for (final message in messages) {
      final key = _reactionTarget(message);
      if (key != null) {
        (idsByRoom[key.roomToken] ??= <int>{}).add(key.messageId);
      }
    }
    final result = <_ChatMessageKey, _CachedReactionMessage?>{};
    const chunkSize = 500;
    for (final MapEntry(key: roomToken, value: ids) in idsByRoom.entries) {
      final messageIds = ids.toList(growable: false);
      for (final messageId in messageIds) {
        result[(roomToken: roomToken, messageId: messageId)] = null;
      }
      for (var offset = 0; offset < messageIds.length; offset += chunkSize) {
        final end = offset + chunkSize < messageIds.length
            ? offset + chunkSize
            : messageIds.length;
        final chunk = messageIds.sublist(offset, end);
        final rows =
            await (_database.select(_database.cachedChatMessages)..where(
                  (message) =>
                      message.accountId.equals(accountId) &
                      message.roomToken.equals(roomToken) &
                      message.messageId.isIn(chunk),
                ))
                .get();
        for (final row in rows) {
          final key = (roomToken: roomToken, messageId: row.messageId);
          result[key] = _decodeReactionMessage(row, key);
        }
      }
    }
    return result;
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
    Map<_ChatMessageKey, _CachedReactionMessage?> cachedMessages,
  ) async {
    final key = _reactionTarget(message);
    if (key == null) {
      return;
    }
    var cached = cachedMessages[key];
    if (!cachedMessages.containsKey(key)) {
      final row =
          await (_database.select(_database.cachedChatMessages)..where(
                (candidate) =>
                    candidate.accountId.equals(account.accountId.value) &
                    candidate.roomToken.equals(key.roomToken) &
                    candidate.messageId.equals(key.messageId),
              ))
              .getSingleOrNull();
      cached = row == null ? null : _decodeReactionMessage(row, key);
      cachedMessages[key] = cached;
    }
    if (cached == null) {
      return;
    }
    final parent = message.parent as ChatFullParent;
    for (var attempt = 0; attempt < 2; attempt++) {
      final current = cached;
      if (current == null) {
        return;
      }
      // Only the two reaction fields are taken across. The notice's parent is
      // authoritative about who reacted, not about an edit or a deletion that
      // may have landed on the cached row since.
      final wire = Map<String, Object?>.of(current.message.wire)
        ..['reactions'] = parent.message.reactions
        ..['reactionsSelf'] = parent.message.reactionsSelf;
      final rawJson = jsonEncode(wire);
      final updated =
          await (_database.update(_database.cachedChatMessages)..where(
                (candidate) =>
                    candidate.accountId.equals(account.accountId.value) &
                    candidate.roomToken.equals(key.roomToken) &
                    candidate.messageId.equals(key.messageId) &
                    candidate.rawJson.equals(current.rawJson),
              ))
              .write(CachedChatMessagesCompanion(rawJson: Value(rawJson)));
      if (updated != 0) {
        cachedMessages[key] = (
          message: ChatMessage.fromJson(wire),
          rawJson: rawJson,
        );
        return;
      }
      final row =
          await (_database.select(_database.cachedChatMessages)..where(
                (candidate) =>
                    candidate.accountId.equals(account.accountId.value) &
                    candidate.roomToken.equals(key.roomToken) &
                    candidate.messageId.equals(key.messageId),
              ))
              .getSingleOrNull();
      cached = row == null ? null : _decodeReactionMessage(row, key);
      if (cached == null) {
        cachedMessages.remove(key);
        return;
      }
    }
    // Another writer won twice. Leave its newer row intact and make a later
    // notice reload it instead of carrying this snapshot forward.
    cachedMessages.remove(key);
  }

  void _forgetChangedReactionTargets(
    Map<_ChatMessageKey, _CachedReactionMessage?> cachedMessages,
    ChatMessage message,
  ) {
    cachedMessages.remove((
      roomToken: message.roomToken.value,
      messageId: message.messageId,
    ));
    final parent = message.parent;
    if ((message.systemMessage == 'message_edited' ||
            message.systemMessage == 'message_deleted') &&
        parent is ChatFullParent &&
        parent.roomToken == message.roomToken) {
      cachedMessages.remove((
        roomToken: message.roomToken.value,
        messageId: parent.messageId,
      ));
    }
    final threadId = message.threadId;
    if (message.systemMessage.isEmpty && threadId != null) {
      cachedMessages.remove((
        roomToken: message.roomToken.value,
        messageId: threadId,
      ));
    }
  }

  _ChatMessageKey? _reactionTarget(ChatMessage message) {
    if (!_reactionNotices.contains(message.systemMessage)) {
      return null;
    }
    final parent = message.parent;
    if (parent is! ChatFullParent || parent.roomToken != message.roomToken) {
      return null;
    }
    return (roomToken: message.roomToken.value, messageId: parent.messageId);
  }

  _CachedReactionMessage? _decodeReactionMessage(
    CachedChatMessage row,
    _ChatMessageKey key,
  ) {
    try {
      final message = ChatMessage.fromJson(jsonDecode(row.rawJson));
      if (message.messageId == key.messageId &&
          message.roomToken.value == key.roomToken) {
        return (message: message, rawJson: row.rawJson);
      }
    } on Object {
      return null;
    }
    return null;
  }
}
