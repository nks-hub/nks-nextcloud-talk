part of 'chat_service.dart';

extension _BackgroundTextDelivery on ChatService {
  /// Delivers what the outbox still holds in rooms nobody has open.
  ///
  /// The room pane replays its own room while it is on screen. A message
  /// queued in a tunnel and an app reopened on the conversation list have no
  /// pane, so without this the text would wait until the room was opened
  /// again. Each room goes through the ordinary sync, which also verifies
  /// capabilities online before anything is claimed; a room whose sync fails
  /// keeps its rows and the error is the pane's to show.
  ///
  /// Each account drains in its own lane. A server that hangs until its
  /// timeout would otherwise hold every later room in the drain behind it,
  /// including the rooms of a second account whose server is reachable, so a
  /// signed-in account's queued text waits on an unrelated account's outage.
  Future<bool> _drainPendingTextSends() async {
    // A drain answers a wake: the network is back, the app resumed. A send
    // that failed for want of a connection is worth trying now, not when its
    // backoff runs out.
    await _chat.expediteUnsentTextSends();
    final lanes = <String, List<String>>{};
    for (final room in await _chat.roomsWithPendingTextSends()) {
      (lanes[room.accountId] ??= <String>[]).add(room.roomToken);
    }
    final retries = await Future.wait<bool>([
      for (final lane in lanes.entries) _drainAccountLane(lane.key, lane.value),
    ]);
    return retries.contains(true);
  }

  /// One account's rooms, one at a time. The transport serializes an account's
  /// requests onto a single session anyway, so racing them inside a lane buys
  /// no parallelism and only reorders the sends.
  Future<bool> _drainAccountLane(
    String accountId,
    List<String> roomTokens,
  ) async {
    var retry = false;
    for (final roomToken in roomTokens) {
      if (_suspendedAccounts.contains(accountId)) {
        return false;
      }
      try {
        final result = await _syncRoom(
          accountId: accountId,
          roomToken: roomToken,
          joinExisting: true,
          automatic: true,
        );
        if (result == ChatSynchronizationResult.deferred) {
          await _drainWithoutReading(accountId, roomToken);
        }
        // A send into a named thread is proven absent only by a read of that
        // thread, which the room's own sync does not make.
        final pending = await _chat.pendingAbsenceVerification(
          accountId: accountId,
          roomToken: roomToken,
        );
        if (pending?.threadId != null) {
          await _syncRoom(
            accountId: accountId,
            roomToken: roomToken,
            threadId: pending!.threadId,
            joinExisting: true,
            automatic: true,
          );
        }
      } on ChatServiceException catch (error) {
        if (error.code != ChatServiceError.network &&
            error.code != ChatServiceError.serviceUnavailable &&
            error.code != ChatServiceError.rateLimited) {
          continue;
        }
      } on _ChatSynchronizationCancelled {
        continue;
      }
      if (!retry && await _chat.hasRetryableHead(accountId, roomToken)) {
        retry = true;
      }
    }
    return retry;
  }
}
