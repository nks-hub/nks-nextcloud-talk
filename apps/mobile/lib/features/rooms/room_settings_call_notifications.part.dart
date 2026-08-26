part of 'room_settings_service.dart';

extension RoomSettingsCallNotifications on RoomSettingsService {
  Future<ConversationRoom> setCallNotificationLevel({
    required String accountId,
    required String roomToken,
    required RoomCallNotificationLevel level,
  }) async {
    final context = await _authContext(accountId);
    final UpdateCallNotificationLevelRequest request;
    try {
      request = UpdateCallNotificationLevelRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        level: level,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.updateCallNotificationLevel(
        updateRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );

    return switch (response) {
      UpdateCallNotificationLevelSuccess(:final room) => room,
      UpdateCallNotificationLevelRejected() =>
        throw const RoomSettingsException(RoomSettingsError.rejected),
      UpdateCallNotificationLevelReauthenticationRequired() =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      UpdateCallNotificationLevelRoomMissing() =>
        throw const RoomSettingsException(RoomSettingsError.roomMissing),
      UpdateCallNotificationLevelHttpFailure(:final kind) =>
        throw RoomSettingsException(_mapHttpFailure(kind)),
    };
  }
}
