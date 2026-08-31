part of 'nextcloud_api.dart';

mixin _NextcloudApiPolls on _HttpNextcloudApiBase {
  Future<PollResponse> getPoll({
    required PollShowRequest pollRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) => _sendPoll(
    pollRequest,
    loginName: loginName,
    appPassword: appPassword,
    confirmedStatusCode: 200,
    abortTrigger: abortTrigger,
  );

  Future<PollResponse> createPoll({
    required PollCreateRequest pollRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) => _sendPoll(
    pollRequest,
    loginName: loginName,
    appPassword: appPassword,
    confirmedStatusCode: 201,
    abortTrigger: abortTrigger,
  );

  Future<PollResponse> votePoll({
    required PollVoteRequest pollRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) => _sendPoll(
    pollRequest,
    loginName: loginName,
    appPassword: appPassword,
    confirmedStatusCode: 200,
    abortTrigger: abortTrigger,
  );

  Future<PollResponse> _sendPoll(
    PollRequest pollRequest, {
    required String loginName,
    required String appPassword,
    required int confirmedStatusCode,
    Future<void>? abortTrigger,
  }) async {
    final request = _request(pollRequest.method, pollRequest.uri, abortTrigger)
      ..headers.addAll({
        ...pollRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final jsonBody = pollRequest.jsonBody;
    if (jsonBody != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(jsonBody);
    }
    final payload = await _sendBody(
      request,
      allowedStatusCodes: {
        confirmedStatusCode,
        400,
        401,
        403,
        404,
        429,
        500,
        502,
        503,
        504,
      },
      maximumBytes: pollMaximumResponseBytes,
      readBodyForStatusCodes: {confirmedStatusCode},
    );
    return decodePollResponse(
      request: pollRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      confirmedStatusCode: confirmedStatusCode,
    );
  }
}
