part of 'room_settings_service.dart';

extension RoomSettingsCallAttendance on RoomSettingsService {
  /// Downloads who the server recorded in the call running in this room.
  ///
  /// Moderator-only, and the caller gates it on `download-call-participants`
  /// the same way recording is gated on `recording-v1`. There is no historical
  /// attendance: outside a running call the server answers `400`, which
  /// arrives here as [RoomSettingsError.preconditionFailed].
  ///
  /// The returned document has spreadsheet formulas neutralised; the display
  /// names in it are written by the attendees.
  Future<String> downloadCallAttendance({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _authContext(accountId);
    final CallAttendanceDownloadRequest request;
    try {
      request = CallAttendanceDownloadRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    final response = await _call(
      () => _api.downloadCallAttendance(
        attendanceRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    final csv = response.csv;
    if (response.isSuccess && csv != null) {
      return csv;
    }
    throw RoomSettingsException(switch (response.classification) {
      CallAttendanceClassification.noCallRunning =>
        RoomSettingsError.preconditionFailed,
      CallAttendanceClassification.reauthenticationRequired =>
        RoomSettingsError.reauthenticationRequired,
      CallAttendanceClassification.forbidden => RoomSettingsError.forbidden,
      CallAttendanceClassification.roomMissing => RoomSettingsError.roomMissing,
      CallAttendanceClassification.rateLimited => RoomSettingsError.rateLimited,
      CallAttendanceClassification.serverFailure ||
      CallAttendanceClassification.confirmed =>
        RoomSettingsError.serviceUnavailable,
    });
  }
}
