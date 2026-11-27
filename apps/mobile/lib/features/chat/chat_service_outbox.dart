part of 'chat_service.dart';

extension _ChatServiceOutbox on ChatService {
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
