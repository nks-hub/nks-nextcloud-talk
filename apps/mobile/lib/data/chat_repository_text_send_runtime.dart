part of 'chat_repository.dart';

extension ChatRepositoryTextSendActions on ChatRepository {
  Future<bool> skipTextSend({
    required String accountId,
    required String roomToken,
    required String operationId,
  }) async {
    final rows = _database.textSendOperations;
    // The state check and update are one write so a late confirmation wins.
    final changed =
        await (_database.update(rows)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.roomToken.equals(roomToken) &
                  row.operationId.equals(operationId) &
                  row.outboxState.equals(
                    TextSendOutboxState.awaitingConfirmation.name,
                  ) &
                  row.automaticResendCount.isBiggerOrEqualValue(
                    textSendMaximumAutomaticResends,
                  ) &
                  row.messageIdsJson.equals('[]'),
            ))
            .write(
              TextSendOperationsCompanion(
                outboxState: Value(TextSendOutboxState.skipped.name),
                nextAttemptAt: const Value(null),
                updatedAtMillis: Value(DateTime.now().millisecondsSinceEpoch),
              ),
            );
    return changed != 0;
  }
}

extension _ChatRepositoryTextSendRuntime on ChatRepository {
  Future<ClaimedTextSend?> _claimTextSendTransaction(
    String accountId,
    TextSendOwnership? ownership,
    Future<ClaimedTextSend?> Function(
      Future<bool> Function(ChatOperationId) reserve,
    )
    claim,
  ) async {
    TextSendReservation? reservation;
    try {
      final claimed = await _database.transaction(
        () => claim((id) async {
          if (ownership == null) return true;
          reservation = await ownership.acquire(accountId, id);
          return reservation != null;
        }),
      );
      if (claimed == null || reservation == null) return claimed;
      return ClaimedTextSend(
        request: claimed.request,
        operation: claimed.operation,
        reservation: reservation,
      );
    } on Object {
      // The claim was not published if the transaction rolled back.
      await reservation?.release();
      rethrow;
    }
  }

  Future<bool> _hasInterruptedTextSend(
    String accountId,
    Set<ChatOperationId> inFlight,
  ) async => (await _sendingTextOperationIds(
    accountId,
  )).any((id) => !inFlight.contains(id));

  Future<List<ChatOperationId>> _sendingTextOperationIds(
    String accountId,
  ) async {
    final rows = _database.textSendOperations;
    return (_database.selectOnly(rows)
          ..addColumns([rows.operationId])
          ..where(
            rows.accountId.equals(accountId) &
                rows.outboxState.equals(TextSendOutboxState.sending.name),
          ))
        .map((row) => ChatOperationId.parse(row.read(rows.operationId)!))
        .get();
  }
}
