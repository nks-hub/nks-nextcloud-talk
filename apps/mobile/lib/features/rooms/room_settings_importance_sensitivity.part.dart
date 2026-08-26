part of 'room_settings_service.dart';

extension RoomSettingsImportanceSensitivity on RoomSettingsService {
  Future<ConversationRoom> setImportant({
    required String accountId,
    required String roomToken,
    required bool important,
  }) async {
    final context = await _authContext(accountId);
    final ({ServerBase server, CapabilitySnapshot capabilities}) admission =
        await _importanceSensitivityAdmission(context);
    final SetImportantRequest request;
    try {
      request = SetImportantRequest(
        accountId: AccountId.parse(accountId),
        server: admission.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        capabilities: admission.capabilities,
        important: important,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.setImportant(
        importantRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    return switch (response) {
      SetImportantSuccess(:final room) => room,
      SetImportantReauthenticationRequired() =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      SetImportantRoomMissing() => throw const RoomSettingsException(
        RoomSettingsError.roomMissing,
      ),
      SetImportantHttpFailure(:final kind) => throw RoomSettingsException(
        _mapHttpFailure(kind),
      ),
    };
  }

  Future<ConversationRoom> setSensitive({
    required String accountId,
    required String roomToken,
    required bool sensitive,
  }) async {
    final context = await _authContext(accountId);
    final ({ServerBase server, CapabilitySnapshot capabilities}) admission =
        await _importanceSensitivityAdmission(context);
    final SetSensitiveRequest request;
    try {
      request = SetSensitiveRequest(
        accountId: AccountId.parse(accountId),
        server: admission.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        capabilities: admission.capabilities,
        sensitive: sensitive,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.setSensitive(
        sensitiveRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    return switch (response) {
      SetSensitiveSuccess(:final room) => room,
      SetSensitiveRejected() => throw const RoomSettingsException(
        RoomSettingsError.rejected,
      ),
      SetSensitiveReauthenticationRequired() =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      SetSensitiveRoomMissing() => throw const RoomSettingsException(
        RoomSettingsError.roomMissing,
      ),
      SetSensitiveHttpFailure(:final kind) => throw RoomSettingsException(
        _mapHttpFailure(kind),
      ),
    };
  }

  Future<({ServerBase server, CapabilitySnapshot capabilities})>
  _importanceSensitivityAdmission(_AuthContext context) async {
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
    return (server: server, capabilities: capabilities);
  }
}
