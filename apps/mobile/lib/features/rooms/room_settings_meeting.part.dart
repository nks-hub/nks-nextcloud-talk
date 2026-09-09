part of 'room_settings_service.dart';

extension RoomSettingsMeeting on RoomSettingsService {
  /// The calendars this account could write a meeting into.
  ///
  /// The server publishes no privileges for them, so a calendar that will
  /// refuse the event is indistinguishable here from one that will take it;
  /// [scheduleMeeting] reports that refusal when it happens.
  Future<List<CalendarEntry>> listCalendars({required String accountId}) async {
    final context = await _authContext(accountId);
    final CalendarListRequest request;
    try {
      request = CalendarListRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        loginName: context.account.loginName,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    final response = await _call(
      () => _api.listCalendars(
        listRequest: request,
        appPassword: context.appPassword,
      ),
    );
    return switch (response.outcome) {
      CalendarListOutcome.listed => response.calendars,
      CalendarListOutcome.reauthenticationRequired =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      CalendarListOutcome.unavailable => throw const RoomSettingsException(
        RoomSettingsError.forbidden,
      ),
      CalendarListOutcome.transientError => throw const RoomSettingsException(
        RoomSettingsError.serviceUnavailable,
      ),
    };
  }

  /// Writes a calendar event for this conversation and invites its
  /// participants.
  ///
  /// Sent once and never retried: the endpoint writes a second event and
  /// invites everybody again if it is repeated, so an answer that did not
  /// arrive is reported as ambiguous rather than sent twice.
  Future<void> scheduleMeeting({
    required String accountId,
    required String roomToken,
    required String calendarUri,
    required DateTime start,
    DateTime? end,
    String? title,
    String? description,
  }) async {
    final context = await _authContext(accountId);
    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: ServerBase.parse(context.account.serverUrl),
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
    } on NextcloudApiException catch (error) {
      throw RoomSettingsException(_mapApiError(error));
    }
    final ScheduleMeetingRequest request;
    try {
      request = ScheduleMeetingRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        calendarUri: calendarUri,
        start: start.toUtc(),
        end: end?.toUtc(),
        title: title,
        description: description,
        capabilities: capabilities,
        now: DateTime.now().toUtc(),
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.rejected);
    }
    final ScheduleMeetingResponse response;
    try {
      response = await _api.scheduleMeeting(
        meetingRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
    } on NextcloudApiException catch (error) {
      // A connection that dropped around this request may or may not have
      // written the event. Repeating it is the one thing that must not
      // happen, so it is reported as ambiguous.
      throw RoomSettingsException(
        error.code == NextcloudApiError.unexpectedStatus &&
                error.statusCode == 401
            ? RoomSettingsError.reauthenticationRequired
            : RoomSettingsError.ambiguous,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    if (response.isSuccess) {
      return;
    }
    throw RoomSettingsException(switch (response.outcome) {
      ScheduleMeetingOutcome.refused => RoomSettingsError.rejected,
      ScheduleMeetingOutcome.reauthenticationRequired =>
        RoomSettingsError.reauthenticationRequired,
      ScheduleMeetingOutcome.forbidden => RoomSettingsError.forbidden,
      ScheduleMeetingOutcome.roomMissing => RoomSettingsError.roomMissing,
      ScheduleMeetingOutcome.rateLimited => RoomSettingsError.rateLimited,
      ScheduleMeetingOutcome.serverFailure ||
      ScheduleMeetingOutcome.scheduled => RoomSettingsError.serviceUnavailable,
    }, message: response.refusal?.name);
  }
}
