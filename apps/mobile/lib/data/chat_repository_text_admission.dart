part of 'chat_repository.dart';

extension ChatRepositoryTextAdmission on ChatRepository {
  Future<TextSendOutboxOperation> admitTextSend({
    required String accountId,
    required ConversationToken roomToken,
    required ChatTextSendAuthority authority,
    required ChatOperationId operationId,
    required ChatReferenceId referenceId,
    required String message,
    bool silent = false,
    ({String id, int? threadId, int? replyTo})? recoverableDraft,
    int? composerThreadId,
    int? replyTo,
    int? threadId,
    ConversationToken? replyToToken,
    ConversationToken? parentRoomToken,
    PrivateReplyEligibilitySnapshot? privateReplyEligibility,
  }) {
    return _database.transaction(() async {
      if (recoverableDraft != null) {
        final drafts = _database.refusedTextDrafts;
        final target =
            drafts.accountId.equals(accountId) &
            drafts.roomToken.equals(roomToken.value) &
            drafts.draftId.equals(recoverableDraft.id);
        final saved = await (_database.select(
          drafts,
        )..where((_) => target)).getSingleOrNull();
        if (saved == null ||
            saved.message.trim() != message ||
            saved.silent != silent ||
            saved.threadId != recoverableDraft.threadId ||
            saved.replyTo != recoverableDraft.replyTo) {
          throw StateError('Draft does not match this send');
        }
        await (_database.delete(drafts)..where((_) => target)).go();
      }
      final snapshot = await _loadRuntime(accountId);
      final account = snapshot.accounts[AccountId.parse(accountId)];
      if (account == null) {
        throw StateError('Chat account does not exist');
      }
      final sequence =
          account.operations.values
              .where((operation) => operation.roomToken == roomToken)
              .fold<int>(0, (value, operation) {
                return operation.enqueueSequence > value
                    ? operation.enqueueSequence
                    : value;
              }) +
          1;
      final result = admitTextSendOperation(
        snapshot,
        accountId: account.accountId,
        authority: authority,
        draft: TextSendOutboxDraft(
          operationId: operationId,
          operationKind: 'textSend',
          roomToken: roomToken,
          referenceId: referenceId,
          message: message,
          replayContractRevision: textSendReplayContractRevision,
          silent: silent,
          enqueueSequence: sequence,
          replyTo: replyTo,
          replyThreadId: replyTo == null ? null : composerThreadId,
          threadId: threadId,
          replyToToken: replyToToken,
          parentRoomToken: parentRoomToken,
          privateReplyEligibility: privateReplyEligibility,
        ),
      );
      final plan = result.plan;
      if (result.outcome != ChatOutboxOutcome.queued || plan == null) {
        throw StateError('Text send was not admitted');
      }
      final candidate = plan.commit(snapshot);
      final candidateAccount = candidate.accounts[account.accountId]!;
      await _persistAccount(candidateAccount);
      if (composerThreadId != null) {
        await (_database.update(_database.textSendOperations)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.operationId.equals(operationId.value),
            ))
            .write(
              TextSendOperationsCompanion(
                composerThreadId: Value(composerThreadId),
              ),
            );
      }
      return candidateAccount.operations[operationId]!;
    });
  }
}
