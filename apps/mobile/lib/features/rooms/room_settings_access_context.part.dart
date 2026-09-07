part of 'room_settings_service.dart';

extension _RoomSettingsAccessContext on RoomSettingsService {
  Future<ConversationRoom> _readAccessRoom(
    _AuthContext context,
    String token,
    Future<void>? abort,
  ) async {
    final response = await _call(
      () => _api.getConversations(
        conversationRequest: ConversationListRequest(
          accountId: AccountId.parse(context.account.id),
          requestId: ConversationRequestId.parse(_uuid.v4()),
          server: ServerBase.parse(context.account.serverUrl),
          mode: ConversationFetchMode.full,
          includeLastMessage: false,
        ),
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abort,
      ),
    );
    if (response is! ConversationListSuccess) {
      throw RoomSettingsException(
        response.statusCode == 401
            ? RoomSettingsError.reauthenticationRequired
            : RoomSettingsError.roomMissing,
      );
    }
    final matches = response.rooms.where((room) => room.token.value == token);
    if (matches.length != 1) {
      throw const RoomSettingsException(RoomSettingsError.roomMissing);
    }
    return matches.single;
  }

  Future<void> _validateAccessIdentity(_AuthContext expected) async {
    final current = await _authContext(expected.account.id);
    if (!current.account.selected ||
        current.account.loginName != expected.account.loginName ||
        current.account.serverUrl != expected.account.serverUrl ||
        current.appPassword != expected.appPassword) {
      throw const RoomSettingsException(RoomSettingsError.accountMissing);
    }
  }
}
