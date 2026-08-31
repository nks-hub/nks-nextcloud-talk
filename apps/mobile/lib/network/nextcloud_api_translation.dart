part of 'nextcloud_api.dart';

mixin _NextcloudApiTranslation on _HttpNextcloudApiBase {
  Future<TranslationLanguagesResponse> getTranslationLanguages({
    required TranslationLanguagesRequest languagesRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', languagesRequest.uri, abortTrigger)
      ..headers.addAll({
        ...languagesRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 401, 404, 429, 500, 503},
      maximumBytes: translationMaximumResponseBytes,
      parseBodyForStatusCodes: const {200},
    );
    return decodeTranslationLanguagesResponse(
      request: languagesRequest,
      statusCode: payload.statusCode,
      json: payload.json,
    );
  }

  Future<TranslateTextResponse> translateText({
    required TranslateTextRequest translateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', translateRequest.uri, abortTrigger)
      ..headers.addAll({
        ...translateRequest.headers,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..body = jsonEncode(translateRequest.jsonBody);
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 400, 401, 404, 412, 429, 500, 503},
      maximumBytes: translationMaximumResponseBytes,
      parseBodyForStatusCodes: const {200},
    );
    return decodeTranslateTextResponse(
      request: translateRequest,
      statusCode: payload.statusCode,
      json: payload.json,
    );
  }
}
