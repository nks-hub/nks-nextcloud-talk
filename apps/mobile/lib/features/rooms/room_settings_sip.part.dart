part of 'room_settings_service.dart';

extension RoomSettingsSipOperations on RoomSettingsService {
  /// Fetches the room-specific phone/SIP instructions from Talk's signaling
  /// settings. The value can contain phone numbers, so it never enters logs or
  /// durable storage.
  Future<String> fetchSipDialInInstructions({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _authContext(accountId);
    final SignalingSettingsRequest request;
    try {
      request = SignalingSettingsRequest(
        context: SignalingRequestContext(
          accountId: AccountId.parse(accountId),
          requestId: SignalingRequestId.parse(_uuid.v4()),
          server: ServerBase.parse(context.account.serverUrl),
          roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
          credentialGeneration: 1,
          capabilityGeneration: 1,
          settingsRevision: 'sip-dial-in',
          connectionEpoch: 0,
          roomEpoch: 0,
        ),
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.getSignalingSettings(
        settingsRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    return switch (response.classification) {
      SignalingSettingsClassification.confirmed
          when response.settings != null =>
        response.settings!.sipDialinInfo,
      SignalingSettingsClassification.reauthenticationRequired =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      SignalingSettingsClassification.roomRefreshRequired =>
        throw const RoomSettingsException(RoomSettingsError.roomMissing),
      SignalingSettingsClassification.serverError =>
        throw const RoomSettingsException(RoomSettingsError.serviceUnavailable),
      _ => throw const RoomSettingsException(RoomSettingsError.invalidResponse),
    };
  }
}
