part of 'nextcloud_api.dart';

mixin _NextcloudApiMeetings on _HttpNextcloudApiBase {
  /// Lists the calendars this account could write a meeting into.
  Future<CalendarListResponse> listCalendars({
    required CalendarListRequest listRequest,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(listRequest.httpMethod, listRequest.uri, abortTrigger)
          ..headers.addAll({
            ...listRequest.headers,
            'Accept': 'application/xml',
            'Authorization': _basicAuthorization(
              listRequest.loginName,
              appPassword,
            ),
          })
          ..body = listRequest.body;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {207, 401, 403, 404, 429, 503},
      maximumBytes: maximumCalendarListingBytes,
      readBodyForStatusCodes: const {207},
    );
    return decodeCalendarListResponse(
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Writes a calendar event for one conversation and invites its
  /// participants.
  ///
  /// Never retried here. The endpoint does not deduplicate, so a repeat writes
  /// a second event and invites everybody again; only the caller knows whether
  /// the first attempt is worth repeating.
  Future<ScheduleMeetingResponse> scheduleMeeting({
    required ScheduleMeetingRequest meetingRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(meetingRequest.httpMethod, meetingRequest.uri, abortTrigger)
          ..headers.addAll({
            ...meetingRequest.headers,
            'Authorization': _basicAuthorization(loginName, appPassword),
          })
          ..bodyFields = _meetingForm(meetingRequest.formFields);
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {
        200,
        400,
        401,
        403,
        404,
        429,
        ...{500, 501, 502, 503},
      },
      maximumBytes: 256 * 1024,
    );
    return decodeScheduleMeetingResponse(
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}

/// `bodyFields` takes one value per key; the only repeated field is the
/// attendee list, which is flattened into indexed keys the way PHP reads them.
Map<String, String> _meetingForm(Map<String, List<String>> fields) {
  final form = <String, String>{};
  for (final entry in fields.entries) {
    if (entry.value.length == 1 && !entry.key.endsWith('[]')) {
      form[entry.key] = entry.value.single;
      continue;
    }
    final name = entry.key.substring(0, entry.key.length - 2);
    for (var index = 0; index < entry.value.length; index++) {
      form['$name[$index]'] = entry.value[index];
    }
  }
  return form;
}
