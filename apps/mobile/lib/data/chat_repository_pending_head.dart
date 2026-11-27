part of 'chat_repository.dart';

extension PendingTextHead on ChatRepository {
  Future<StoredTextSendOperation?> _firstPendingSend(
    String accountId,
    String roomToken,
  ) =>
      (_database.select(_database.textSendOperations)
            ..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.roomToken.equals(roomToken) &
                  row.outboxState.isIn(const [
                    'queued',
                    'retryable',
                    'sending',
                    'awaitingConfirmation',
                  ]),
            )
            ..orderBy([(row) => OrderingTerm.asc(row.enqueueSequence)])
            ..limit(1))
          .getSingleOrNull();

  bool _awaitsAutomaticConfirmation(StoredTextSendOperation head) =>
      head.outboxState == TextSendOutboxState.awaitingConfirmation.name &&
      head.nextAttemptAt != null &&
      head.messageIdsJson == '[]' &&
      head.automaticResendCount < textSendMaximumAutomaticResends;

  Future<StoredTextSendOperation?> _absenceVerificationHead(
    String accountId,
    String roomToken,
  ) async {
    final head = await _firstPendingSend(accountId, roomToken);
    return head != null && _awaitsAutomaticConfirmation(head) ? head : null;
  }

  Future<bool> hasRetryableHead(String accountId, String roomToken) async {
    final head = await _firstPendingSend(accountId, roomToken);
    return head != null &&
        (head.outboxState != TextSendOutboxState.awaitingConfirmation.name ||
            _awaitsAutomaticConfirmation(head));
  }
}
