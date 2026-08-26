part of 'room_settings_service.dart';

extension RoomSettingsMessageExpiration on RoomSettingsService {
  Future<ConversationRoom> setMessageExpiration({
    required String accountId,
    required String roomToken,
    required int seconds,
  }) async {
    final context = await _authContext(accountId);
    final ServerBase server;
    try {
      server = ServerBase.parse(context.account.serverUrl);
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final capabilities = await _call(
      () => _api.getAuthenticatedCapabilities(
        server: server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    final SetMessageExpirationRequest request;
    try {
      request = SetMessageExpirationRequest(
        accountId: AccountId.parse(accountId),
        server: server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        capabilities: capabilities,
        seconds: seconds,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.setMessageExpiration(
        expirationRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );

    return switch (response) {
      SetMessageExpirationSuccess(:final room) => room,
      SetMessageExpirationRejected() => throw const RoomSettingsException(
        RoomSettingsError.rejected,
      ),
      SetMessageExpirationReauthenticationRequired() =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      SetMessageExpirationForbidden() => throw const RoomSettingsException(
        RoomSettingsError.forbidden,
      ),
      SetMessageExpirationRoomMissing() => throw const RoomSettingsException(
        RoomSettingsError.roomMissing,
      ),
      SetMessageExpirationHttpFailure(:final kind) =>
        throw RoomSettingsException(_mapHttpFailure(kind)),
    };
  }
}
