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

const _ownTalkUploadAllowedStatusCodes = {
  200,
  400,
  401,
  403,
  404,
  412,
  413,
  415,
  428,
  429,
  503,
  507,
};
const _ownTalkImageAllowedStatusCodes = {200, 401, 403, 404, 429, 503};

/// A photo upload is up to megabytes over a phone connection, so it gets far
/// longer than the 20 s a JSON call does.
const _ownTalkImageTimeout = Duration(minutes: 2);

/// Optional OwnTalk Extensions server app. Callers must have seen the
/// capability first; nothing here probes for it.
///
/// The calls authenticate with Basic auth alone and stay outside the room
/// session: a desktop re-enters the room while its details are open, and a
/// new session would otherwise discard a write the server already applied.
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
    );
    return decodeFetchOwnTalkRoomSettingsResponse(
      request: settingsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: payload.headers,
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
    );
    return decodeUpdateOwnTalkRoomSettingsResponse(
      request: settingsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: payload.headers,
    );
  }

  /// Uploads a background image. Never retried, for the same reason as
  /// [updateOwnTalkRoomSettings].
  Future<OwnTalkSettingsUpdateResult> uploadOwnTalkRoomImage({
    required UploadOwnTalkRoomImageRequest uploadRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('PUT', uploadRequest.uri, abortTrigger)
      ..headers.addAll({
        ...uploadRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyBytes = uploadRequest.bodyBytes;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _ownTalkUploadAllowedStatusCodes,
      maximumBytes: ownTalkExtensionsMaximumWireBytes,
      timeout: _ownTalkImageTimeout,
    );
    return decodeUploadOwnTalkRoomImageResponse(
      request: uploadRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: payload.headers,
    );
  }

  Future<OwnTalkImageFetchResult> fetchOwnTalkRoomImage({
    required FetchOwnTalkRoomImageRequest imageRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', imageRequest.uri, abortTrigger)
      ..headers.addAll({
        ...imageRequest.headers,
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _ownTalkImageAllowedStatusCodes,
      maximumBytes: ownTalkExtensionsMaximumImageBytes,
      readBodyForStatusCodes: const {200},
      timeout: _ownTalkImageTimeout,
    );
    return decodeFetchOwnTalkRoomImageResponse(
      request: imageRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: payload.headers,
    );
  }
}
