part of 'room_settings_service.dart';

extension RoomSettingsRecording on RoomSettingsService {
  /// Starts recording the call. Moderator-only; the caller gates it on
  /// `recording-v1` the same way breakout rooms are gated on
  /// `breakout-rooms-v1`.
  Future<void> startCallRecording({
    required String accountId,
    required String roomToken,
    required CallRecordingStartMode mode,
  }) async {
    final context = await _authContext(accountId);
    final StartCallRecordingRequest request;
    try {
      request = StartCallRecordingRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        mode: mode,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    final response = await _call(
      () => _api.administerCallRecording(
        recordingRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    _classifyCallRecording(response);
  }

  /// Stops a recording that is starting or already in progress.
  /// Moderator-only.
  Future<void> stopCallRecording({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _authContext(accountId);
    final StopCallRecordingRequest request;
    try {
      request = StopCallRecordingRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    final response = await _call(
      () => _api.administerCallRecording(
        recordingRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    _classifyCallRecording(response);
  }

  void _classifyCallRecording(CallRecordingResponse response) {
    switch (response.classification) {
      case CallRecordingResponseClassification.confirmed:
        return;
      case CallRecordingResponseClassification.rejected:
        throw RoomSettingsException(
          RoomSettingsError.rejected,
          message: response.errorCode,
        );
      case CallRecordingResponseClassification.reauthenticationRequired:
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        );
      case CallRecordingResponseClassification.forbidden:
        throw const RoomSettingsException(RoomSettingsError.forbidden);
      case CallRecordingResponseClassification.roomMissing:
        throw const RoomSettingsException(RoomSettingsError.roomMissing);
      case CallRecordingResponseClassification.preconditionFailed:
        throw const RoomSettingsException(RoomSettingsError.preconditionFailed);
      case CallRecordingResponseClassification.rateLimited:
        throw const RoomSettingsException(RoomSettingsError.rateLimited);
      case CallRecordingResponseClassification.serverFailure:
        throw const RoomSettingsException(RoomSettingsError.serviceUnavailable);
    }
  }
}
