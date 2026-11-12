part of 'nextcloud_api.dart';

const _ownTalkFetchAllowedStatusCodes = {
  200,
  304,
  400,
  401,
  403,
  404,
  429,
  503,
};
const _ownTalkUpdateAllowedStatusCodes = {
  200,
  400,
  401,
  403,
  404,
  412,
  428,
  429,
  503,
};

/// Optional OwnTalk Extensions server app. Callers must have seen the
/// capability first; nothing here probes for it.
mixin _NextcloudApiOwnTalkExtensions on _HttpNextcloudApiBase {
  Future<OwnTalkSettingsFetchResult> fetchOwnTalkRoomSettings({
    required FetchOwnTalkRoomSettingsRequest settingsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', settingsRequest.uri, abortTrigger)
      ..headers.addAll({
        ...settingsRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _ownTalkFetchAllowedStatusCodes,
      maximumBytes: ownTalkExtensionsMaximumWireBytes,
      readBodyForStatusCodes: const {200, 400, 401, 403, 404, 429, 503},
      sessionAccountId: settingsRequest.accountId,
      sessionServer: settingsRequest.server,
    );
    return decodeFetchOwnTalkRoomSettingsResponse(
      request: settingsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Applies one merge patch. Never retried: a repeat after an unseen success
  /// would answer `412` against the caller's own write.
  Future<OwnTalkSettingsUpdateResult> updateOwnTalkRoomSettings({
    required UpdateOwnTalkRoomSettingsRequest settingsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('PATCH', settingsRequest.uri, abortTrigger)
      ..headers.addAll({
        ...settingsRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyBytes = settingsRequest.bodyBytes;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _ownTalkUpdateAllowedStatusCodes,
      maximumBytes: ownTalkExtensionsMaximumWireBytes,
      sessionAccountId: settingsRequest.accountId,
      sessionServer: settingsRequest.server,
    );
    return decodeUpdateOwnTalkRoomSettingsResponse(
      request: settingsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}
