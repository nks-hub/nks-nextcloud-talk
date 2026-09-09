part of 'nextcloud_api.dart';

mixin _NextcloudApiBots on _HttpNextcloudApiBase {
  /// Reads every bot installed on the server.
  ///
  /// Administrator-only upstream: an ordinary account is answered `403`, which
  /// the decoder reports as its own outcome rather than a failure.
  Future<BotAdminListResponse> listAdminBots({
    required BotAdminListRequest listRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(listRequest.httpMethod, listRequest.uri, abortTrigger)
          ..headers.addAll({
            ...listRequest.headers,
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {
        200,
        401,
        403,
        404,
        429,
        ...{500, 502, 503},
      },
      maximumBytes: maximumBotAdminBytes,
      readBodyForStatusCodes: const {200},
    );
    return decodeBotAdminListResponse(
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}
