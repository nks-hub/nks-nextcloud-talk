part of 'chat_repository.dart';

typedef _ParentMutation = ({ChatMessage message, int position});

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
    mutations: [(message: message, position: 0)],
  );

  Future<void> _projectMutationsIntoCachedParents({
    required String accountId,
    required Iterable<_ParentMutation> mutations,
    Map<_ChatMessageKey, int> lastReplacementPositions = const {},
  }) async {
    final mutationsByRoom = <String, Map<int, _ParentMutation>>{};
    for (final mutation in mutations) {
      final message = mutation.message;
      final roomMutations = mutationsByRoom.putIfAbsent(
        message.roomToken.value,
        () => {},
      );
      roomMutations[message.messageId] = mutation;
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
        final chunkMutations = <int, _ParentMutation>{
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
          final replacementPosition =
              lastReplacementPositions[(
                roomToken: roomToken,
                messageId: row.messageId,
              )];
          // A later full row brought its own parent snapshot.
          if (mutation == null ||
              (replacementPosition != null &&
                  replacementPosition >= mutation.position)) {
            continue;
          }
          final updated = cached.replaceParentMessageIfMatching(
            mutation.message,
          );
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

extension ChatRepositoryRefreshedMessage on ChatRepository {
  /// Stores [message] as the server returned it to a re-read of that one id.
  ///
  /// The re-read runs outside the room's lane, so live sync can edit or
  /// delete the row while it is on the wire. The row is therefore written only
  /// if it still holds [expectedRawJson], what it held when the re-read began
  /// (null: no row), and only if the copy differs, as every write wakes each
  /// watcher of the table. Returns whether the cache holds the server's copy.
  Future<bool> applyRefreshedMessage({
    required String accountId,
    required ServerBase server,
    required ChatMessage message,
    required String? expectedRawJson,
  }) {
    return _database.transaction(() async {
      final current = await getMessage(
        accountId: accountId,
        roomToken: message.roomToken.value,
        messageId: message.messageId,
      );
      if (current?.rawJson != expectedRawJson) {
        return false;
      }
      if (current?.rawJson != jsonEncode(message.wire)) {
        await _applyMessageMutation(
          accountId: accountId,
          server: server,
          message: message,
        );
      }
      return true;
    });
  }
}
