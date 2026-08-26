part of 'chat_repository.dart';

extension _ChatRepositoryReadMarkers on ChatRepository {
  Future<ChatMergeOutcome> _applyChatReadResponse(ChatReadResponse response) {
    return _database.transaction(() async {
      final accountId = response.request.accountId.value;
      final roomToken = response.request.roomToken.value;
      final conversation = await getConversation(
        accountId: accountId,
        roomToken: roomToken,
      );
      final marker = response.marker;
      if (conversation == null || marker == null) {
        return ChatMergeOutcome.rejected;
      }

      final Map<String, Object?> roomWire;
      try {
        final decoded = jsonDecode(conversation.rawJson);
        if (decoded is! Map<String, Object?>) {
          return ChatMergeOutcome.rejected;
        }
        roomWire = Map<String, Object?>.of(decoded);
        if (ConversationRoom.fromJson(roomWire).token !=
            response.request.roomToken) {
          return ChatMergeOutcome.rejected;
        }
      } on Object {
        return ChatMergeOutcome.rejected;
      }

      final ordinaryThreadIds =
          await _rootBackedViewThreadIdsInCurrentTransaction(
            accountId: accountId,
            roomToken: roomToken,
          );
      final snapshot = await _loadRuntime(accountId);
      final result = planChatReadMerge(snapshot, response);
      final plan = result.plan;
      if (plan == null) {
        return result.outcome;
      }

      final candidate = plan.commit(snapshot);
      await _persistAccount(candidate.accounts[response.request.accountId]!);
      await _projectRootNetworkStateToViewsInCurrentTransaction(
        accountId: accountId,
        roomToken: roomToken,
        preservedViewThreadIds: ordinaryThreadIds,
      );

      roomWire
        ..['lastReadMessage'] = marker.lastReadMessage
        ..['lastCommonReadMessage'] = marker.lastCommonReadMessage
        ..['unreadMessages'] = marker.unreadMessages;
      await (_database.update(_database.cachedConversations)..where(
            (row) =>
                row.accountId.equals(accountId) & row.token.equals(roomToken),
          ))
          .write(
            CachedConversationsCompanion(
              unreadMessages: Value(marker.unreadMessages),
              rawJson: Value(jsonEncode(roomWire)),
            ),
          );
      return result.outcome;
    });
  }
}
