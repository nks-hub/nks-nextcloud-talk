part of 'chat_repository.dart';

extension _ChatRepositoryReadMarkers on ChatRepository {
  Future<void> _persistChatGetCandidate({
    required ChatGetResponse response,
    required ChatMergeOutcome outcome,
    required ChatRuntimeSnapshot candidate,
    required Iterable<ChatMessage> messages,
  }) async {
    final syncedScope = ChatScopeKey(
      roomToken: response.request.roomToken,
      threadId: response.request.threadId,
    );
    final account = candidate.accounts[response.request.accountId]!;
    await _persistAccount(
      account,
      messages: messages,
      syncedScope: syncedScope,
    );
    if (outcome != ChatMergeOutcome.reauthenticationRequired) {
      await _persistMergedCommonReadInConversation(response);
    }
  }

  Future<void> _persistMergedCommonReadInConversation(
    ChatGetResponse response,
  ) async {
    final profile = response.request.profile;
    if (profile.commonReadStatus && response.lastCommonRead == null) {
      return;
    }
    final accountId = response.request.accountId.value;
    final roomToken = response.request.roomToken.value;
    final conversation = await getConversation(
      accountId: accountId,
      roomToken: roomToken,
    );
    if (conversation == null) {
      return;
    }
    final decoded = jsonDecode(conversation.rawJson);
    if (decoded is! Map<String, Object?> || decoded['token'] != roomToken) {
      return;
    }
    final roomWire = Map<String, Object?>.of(decoded);
    final marker = int.parse(
      profile.commonReadStatus ? response.lastCommonRead!.value : '0',
    );
    if (roomWire['lastCommonReadMessage'] == marker) {
      return;
    }
    roomWire['lastCommonReadMessage'] = marker;
    await (_database.update(_database.cachedConversations)..where(
          (row) =>
              row.accountId.equals(accountId) & row.token.equals(roomToken),
        ))
        .write(
          CachedConversationsCompanion(rawJson: Value(jsonEncode(roomWire))),
        );
  }

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
      } on Object catch (error) {
        // `rejected` reaches the caller either way, but on its own it cannot
        // tell a room whose JSON no longer parses from one whose token does
        // not match the request — and those two want opposite fixes.
        debugPrint('[chat] read-marker room rejected: $error');
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
