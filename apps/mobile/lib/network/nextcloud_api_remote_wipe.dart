part of 'nextcloud_api.dart';

mixin _NextcloudApiRemoteWipe on _HttpNextcloudApiBase {
  /// Asks the server whether this app password has been marked for wipe, or
  /// reports that the wipe is done.
  ///
  /// No `Authorization` header: the token in the body is what the core route
  /// authenticates, and a revoked password would make an authenticated call
  /// fail before the question is even asked.
  Future<RemoteWipeResponse> remoteWipe({
    required RemoteWipeRequest wipeRequest,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(wipeRequest.httpMethod, wipeRequest.uri, abortTrigger)
          ..headers.addAll(wipeRequest.headers)
          ..bodyBytes = wipeRequest.bodyBytes;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 401, 403, 404, 429, 500, 502, 503},
      maximumBytes: remoteWipeMaximumResponseBytes,
      readBodyForStatusCodes: const {200},
    );
    // 401 and 403 mean the token cannot ask the question; that is not an
    // instruction to wipe, so it is reported as "not requested".
    if (payload.statusCode == 401 || payload.statusCode == 403) {
      return decodeRemoteWipeResponse(
        request: wipeRequest,
        statusCode: 404,
        body: Uint8List(0),
      );
    }
    return decodeRemoteWipeResponse(
      request: wipeRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}
