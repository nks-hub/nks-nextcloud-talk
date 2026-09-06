part of 'nextcloud_api.dart';

const int _callRestMaximumBytes = 1024 * 1024;
final Set<int> _callRestAllowedStatusCodes = Set.unmodifiable({
  200,
  400,
  401,
  403,
  404,
  409,
  429,
  ...Iterable<int>.generate(100, (index) => 500 + index),
});

/// Every status `docs/recording.md` documents for start and stop, plus the
/// generic `429`/`503` this package treats uniformly everywhere else.
final Set<int> _callRecordingAllowedStatusCodes = Set.unmodifiable({
  200,
  400,
  401,
  403,
  404,
  412,
  429,
  503,
});

mixin _NextcloudApiCall on _HttpNextcloudApiBase {
  Future<CallRestResponse> getCallPeers({
    required CallPeersRequest peersRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) => _sendCallRestRequest(
    peersRequest,
    loginName: loginName,
    appPassword: appPassword,
    abortTrigger: abortTrigger,
  );

  Future<CallRestResponse> joinCall({
    required JoinCallRequest joinRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) => _sendCallRestRequest(
    joinRequest,
    loginName: loginName,
    appPassword: appPassword,
    abortTrigger: abortTrigger,
  );

  Future<CallRestResponse> updateCallFlags({
    required UpdateCallFlagsRequest updateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) => _sendCallRestRequest(
    updateRequest,
    loginName: loginName,
    appPassword: appPassword,
    abortTrigger: abortTrigger,
  );

  Future<CallRestResponse> leaveCall({
    required LeaveCallRequest leaveRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) => _sendCallRestRequest(
    leaveRequest,
    loginName: loginName,
    appPassword: appPassword,
    abortTrigger: abortTrigger,
  );

  /// Starts or stops call recording. Moderator-only on the server
  /// (`#[RequireLoggedInModeratorParticipant]`); the caller is responsible for
  /// not offering the control to anyone else.
  Future<CallRecordingResponse> administerCallRecording({
    required CallRecordingRequest recordingRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(
            recordingRequest.httpMethod,
            recordingRequest.uri,
            abortTrigger,
          )
          ..headers.addAll({
            ...recordingRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final formBody = recordingRequest.formBody;
    if (formBody != null) {
      request.bodyFields = formBody;
    }
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _callRecordingAllowedStatusCodes,
      maximumBytes: _callRestMaximumBytes,
    );
    return decodeCallRecordingResponse(
      request: recordingRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  Future<CallRestResponse> _sendCallRestRequest(
    CallRestRequest callRequest, {
    required String loginName,
    required String appPassword,
    required Future<void>? abortTrigger,
  }) async {
    final request =
        _request(_callMethod(callRequest.method), callRequest.uri, abortTrigger)
          ..headers.addAll({
            ...callRequest.headers,
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final fields = callRequest.formFields;
    if (fields != null) {
      request.body = _encodeCallForm(fields);
    }
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _callRestAllowedStatusCodes,
      maximumBytes: _callRestMaximumBytes,
      sessionAccountId: callRequest.accountId,
      sessionServer: callRequest.authority.server,
    );
    return decodeCallRestResponse(
      request: callRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}

String _callMethod(CallRestMethod method) => switch (method) {
  CallRestMethod.get => 'GET',
  CallRestMethod.post => 'POST',
  CallRestMethod.put => 'PUT',
  CallRestMethod.delete => 'DELETE',
};

String _encodeCallForm(Map<String, List<String>> fields) => fields.entries
    .expand(
      (entry) => entry.value.map(
        (value) =>
            '${Uri.encodeQueryComponent(entry.key)}='
            '${Uri.encodeQueryComponent(value)}',
      ),
    )
    .join('&');
