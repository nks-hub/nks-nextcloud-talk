part of 'chat_repository.dart';

extension ChatRepositoryClearHistory on ChatRepository {
  /// Replaces the target room's server-backed timeline after Talk confirmed a
  /// history clear. Durable sends, drafts and attachment jobs are deliberately
  /// outside this transaction and therefore survive the destructive server
  /// operation.
  Future<void> applyClearRoomHistorySuccess(
    ClearRoomHistorySuccess response,
  ) async {
    final accountId = response.request.accountId.value;
    final roomToken = response.request.roomToken.value;
    final message = response.systemMessage;
    final cursor = ChatCursor.parse(message.messageId.toString());
    final commonRead = response.lastCommonRead;
    if (message.roomToken.value != roomToken ||
        message.systemMessage != 'history_cleared' ||
        message.threadId != null ||
        message.isThread == true ||
        (commonRead != null && commonRead.compareTo(cursor) > 0)) {
      throw StateError('Invalid clear-history replacement');
    }

    await _database.transaction(() async {
      final account = await (_database.select(
        _database.accounts,
      )..where((row) => row.id.equals(accountId))).getSingleOrNull();
      if (account == null) {
        throw StateError('Chat account is not prepared');
      }
      final server = ServerBase.parse(account.serverUrl);
      final displayText = normalizeGiphyReferencePreview(
        renderRichChatMessage(
          message: message.message,
          markdownEnabled: message.markdown ?? false,
          parameters: message.messageParameters,
          server: server,
        ).root.flattenedText.trim(),
      );

      await (_database.delete(_database.cachedChatMessages)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.roomToken.equals(roomToken),
          ))
          .go();
      await (_database.delete(_database.chatScopes)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.roomToken.equals(roomToken),
          ))
          .go();

      await _database
          .into(_database.cachedChatMessages)
          .insert(
            CachedChatMessagesCompanion.insert(
              accountId: accountId,
              roomToken: roomToken,
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
              threadId: const Value(null),
              rawJson: jsonEncode(message.wire),
            ),
          );

      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final blocks = _encodeBlocks([ChatBlock(start: cursor, end: cursor)]);
      for (final scopeKey in <String>[_rootScopeKey, _networkRootScopeKey]) {
        await _database
            .into(_database.chatScopes)
            .insert(
              ChatScopesCompanion.insert(
                accountId: accountId,
                roomToken: roomToken,
                scopeKey: scopeKey,
                threadId: const Value(null),
                historyCursor: cursor.value,
                futureCursor: cursor.value,
                lastCommonRead: commonRead?.value ?? '0',
                lastReadMessage: 0,
                unreadMessages: 1,
                hasHistory: false,
                futureConverged: true,
                blocksJson: blocks,
                lastSyncedAtMillis: Value(now),
              ),
            );
      }
    });
  }
}
