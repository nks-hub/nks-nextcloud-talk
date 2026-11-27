part of 'chat_service.dart';

extension _ChatServiceOutbox on ChatService {
  /// Delivery for a message admitted on stored capabilities.
  ///
  /// The server is asked now, because a change it reports would make it
  /// refuse a claim made with the stored ones. If it cannot be asked, the
  /// stored ones still send the message or arm its retry.
  Future<void> _deliverAfterStoredAdmission(
    _PreparedChat stored,
    int? threadId,
  ) async {
    var prepared = stored;
    try {
      prepared = await _prepare(
        stored.account.id,
        stored.room.token.value,
        threadId: threadId,
        allowPersistedCapabilitiesForSend: true,
      );
    } on Object {
      // Falls back to [stored].
    }
    await _deliverPending(prepared, threadId: threadId);
  }

  Future<bool> _updatePendingTextSend(
    String accountId,
    String roomToken,
    String operationId,
    Future<bool> Function() update,
  ) async {
    final roomKey = _roomKey(accountId, roomToken);
    _ChatRetryWake? retryWake;
    final changed = await _serializeRoom<bool>(_deliveryKey(roomKey), () async {
      final changed = await update();
      final retry = _retryTimers[roomKey];
      if (changed && retry?.operationId == operationId) {
        retryWake = retry;
      }
      return changed;
    });
    if (changed) {
      _sendActivity(1);
      unawaited(
        _resumeOutbox(
          accountId,
          roomToken,
          retryWake: retryWake,
        ).whenComplete(() => _sendActivity(-1)),
      );
    }
    return changed;
  }

  Future<void> _resumeOutbox(
    String accountId,
    String roomToken, {
    required _ChatRetryWake? retryWake,
  }) async {
    final roomKey = _roomKey(accountId, roomToken);
    try {
      final pending = await _chat.roomsWithPendingTextSends();
      if (!pending.any(
        (room) => room.accountId == accountId && room.roomToken == roomToken,
      )) {
        _cancelRetryWake(roomKey, retryWake);
        return;
      }
      final prepared = await _prepare(
        accountId,
        roomToken,
        allowPersistedCapabilitiesForSend: true,
        preferPersistedCapabilities: true,
      );
      _cancelRetryWake(roomKey, retryWake);
      await _deliverPending(prepared, clearsRoomError: false);
    } on Object {
      // The durable row remains for its ordinary retry or the next wake.
    }
  }
}
