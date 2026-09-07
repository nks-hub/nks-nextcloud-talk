part of 'nextcloud_api.dart';

mixin _NextcloudApiPolls on _HttpNextcloudApiBase {
  Future<PollResponse> closePoll({
    required PollCloseRequest pollRequest,
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

  Future<PollResponse> createPollDraft({
    required PollDraftCreateRequest pollRequest,
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

  Future<PollResponse> editPollDraft({
    required PollDraftEditRequest pollRequest,
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

  Future<PollDraftListResponse> getPollDrafts({
    required PollDraftListRequest pollRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final payload = await _sendPollPayload(
      pollRequest,
      loginName: loginName,
      appPassword: appPassword,
      confirmedStatusCode: 200,
      abortTrigger: abortTrigger,
    );
    return decodePollDraftListResponse(
      request: pollRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  Future<PollDraftDeleteResponse> deletePollDraft({
    required PollDraftDeleteRequest pollRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final payload = await _sendPollPayload(
      pollRequest,
      loginName: loginName,
      appPassword: appPassword,
      confirmedStatusCode: 202,
      abortTrigger: abortTrigger,
    );
    return decodePollDraftDeleteResponse(
      request: pollRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  Future<PollExportResponse> exportPoll({
    required PollExportRequest pollRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final payload = await _sendPollPayload(
      pollRequest,
      loginName: loginName,
      appPassword: appPassword,
      confirmedStatusCode: 200,
      maximumBytes: pollMaximumExportBytes,
      accept: pollRequest.format.mimeType,
      abortTrigger: abortTrigger,
    );
    return decodePollExportResponse(
      request: pollRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      contentType: payload.headers['content-type'],
    );
  }

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
    final payload = await _sendPollPayload(
      pollRequest,
      loginName: loginName,
      appPassword: appPassword,
      confirmedStatusCode: confirmedStatusCode,
      abortTrigger: abortTrigger,
    );
    return decodePollResponse(
      request: pollRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      confirmedStatusCode: confirmedStatusCode,
    );
  }

  Future<_BodyPayload> _sendPollPayload(
    PollRequest pollRequest, {
    required String loginName,
    required String appPassword,
    required int confirmedStatusCode,
    int maximumBytes = pollMaximumResponseBytes,
    String accept = 'application/json',
    Future<void>? abortTrigger,
  }) async {
    final cancelled = Completer<void>();
    final abort = abortTrigger == null
        ? cancelled.future
        : Future.any<void>([cancelled.future, abortTrigger]);
    final request = _request(pollRequest.method, pollRequest.uri, abort)
      ..headers.addAll({
        ...pollRequest.headers,
        'Accept': accept,
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final jsonBody = pollRequest.jsonBody;
    if (jsonBody != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(jsonBody);
    }
    try {
      return await _sendBody(
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
        maximumBytes: maximumBytes,
        readBodyForStatusCodes: {confirmedStatusCode},
        sessionAccountId: pollRequest.accountId,
        sessionServer: pollRequest.server,
      ).timeout(
        requestTimeout,
        onTimeout: () {
          if (!cancelled.isCompleted) cancelled.complete();
          throw const NextcloudApiException(NextcloudApiError.timeout);
        },
      );
    } finally {
      if (!cancelled.isCompleted) cancelled.complete();
    }
  }
}
