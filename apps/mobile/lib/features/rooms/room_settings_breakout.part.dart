part of 'room_settings_service.dart';

extension RoomSettingsBreakouts on RoomSettingsService {
  /// Creates the breakout rooms of a group conversation. Moderator-only; the
  /// caller gates it on `breakout-rooms-v1`.
  Future<ConversationRoom?> configureBreakoutRooms({
    required String accountId,
    required String roomToken,
    required int amount,
    BreakoutRoomMode mode = BreakoutRoomMode.automatic,
    String? attendeeMap,
  }) {
    return _administer(
      accountId: accountId,
      roomToken: roomToken,
      build: (ids) => ConfigureBreakoutRoomsRequest(
        accountId: ids.accountId,
        server: ids.server,
        roomToken: ids.roomToken,
        mode: mode,
        amount: amount,
        attendeeMap: attendeeMap,
      ),
    );
  }

  /// Moves this account from its breakout room into [target].
  ///
  /// `roomToken` is the PARENT's, not either room's: the server looks the
  /// target up among the parent's children and refuses the move unless the
  /// parent is in free mode with the session started — and unless the caller
  /// is NOT a moderator, since a moderator is already in every room
  /// (`BreakoutRoomService::switchBreakoutRoom`).
  Future<ConversationRoom?> switchBreakoutRoom({
    required String accountId,
    required String roomToken,
    required String target,
  }) {
    return _administer(
      accountId: accountId,
      roomToken: roomToken,
      build: (ids) => SwitchBreakoutRoomRequest(
        accountId: ids.accountId,
        server: ids.server,
        roomToken: ids.roomToken,
        target: ConversationToken.parse(target, path: r'$.target'),
      ),
    );
  }

  /// The breakout rooms of a parent conversation. A refusal comes back as an
  /// empty list — the caller has nothing to show either way.
  Future<List<ConversationRoom>> listBreakoutRooms({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _authContext(accountId);
    final BreakoutRoomsListRequest request;
    try {
      request = BreakoutRoomsListRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    final response = await _call(
      () => _api.listBreakoutRooms(
        listRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    return response.rooms;
  }

  /// [childTokens] are the breakout rooms this removal deletes on the server.
  /// They are dropped from the cache with it, the same way `deleteRoom` drops
  /// the room it deleted: without that the list keeps offering conversations
  /// that no longer exist until the next sync.
  Future<ConversationRoom?> removeBreakoutRooms({
    required String accountId,
    required String roomToken,
    Iterable<String> childTokens = const <String>[],
  }) async {
    final room = await _administer(
      accountId: accountId,
      roomToken: roomToken,
      build: (ids) => RemoveBreakoutRoomsRequest(
        accountId: ids.accountId,
        server: ids.server,
        roomToken: ids.roomToken,
      ),
    );
    for (final token in childTokens) {
      await _accounts.removeConversation(accountId: accountId, token: token);
    }
    return room;
  }

  /// Starts or ends the breakout session of the parent conversation.
  Future<ConversationRoom?> runBreakoutRooms({
    required String accountId,
    required String roomToken,
    required bool start,
  }) {
    return _administer(
      accountId: accountId,
      roomToken: roomToken,
      build: (ids) => RunBreakoutRoomsRequest(
        accountId: ids.accountId,
        server: ids.server,
        roomToken: ids.roomToken,
        start: start,
      ),
    );
  }

  /// Posts one message into every breakout room. Nothing comes back but the
  /// success itself.
  Future<void> broadcastToBreakoutRooms({
    required String accountId,
    required String roomToken,
    required String message,
  }) async {
    await _administer(
      accountId: accountId,
      roomToken: roomToken,
      build: (ids) => BroadcastBreakoutRoomsRequest(
        accountId: ids.accountId,
        server: ids.server,
        roomToken: ids.roomToken,
        message: message,
      ),
    );
  }

  /// Raises or withdraws a breakout room's request for a moderator.
  /// `roomToken` is the breakout room's own token.
  Future<ConversationRoom?> setBreakoutAssistance({
    required String accountId,
    required String roomToken,
    required bool requested,
  }) {
    return _administer(
      accountId: accountId,
      roomToken: roomToken,
      build: (ids) => BreakoutAssistanceRequest(
        accountId: ids.accountId,
        server: ids.server,
        roomToken: ids.roomToken,
        requested: requested,
      ),
    );
  }
}
