part of 'nextcloud_api.dart';

mixin _NextcloudApiRemoteFiles on _HttpNextcloudApiBase {
  /// Lists one directory of the account's own Files storage.
  Future<RemoteDirectoryResponse> listRemoteDirectory({
    required RemoteDirectoryRequest directoryRequest,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(
            directoryRequest.httpMethod,
            directoryRequest.uri,
            abortTrigger,
          )
          ..headers.addAll({
            ...directoryRequest.headers,
            'Accept': 'application/xml',
            'Authorization': _basicAuthorization(
              directoryRequest.loginName,
              appPassword,
            ),
          })
          ..bodyBytes = directoryRequest.bodyBytes;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {207, 401, 403, 404, 429, 503},
      maximumBytes: remoteFilesMaximumListingBytes,
      readBodyForStatusCodes: const {207},
    );
    return decodeRemoteDirectoryResponse(
      request: directoryRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Shares a file that already lives on the server into a conversation.
  ///
  /// Nothing is uploaded and no copy is made: the server posts the existing
  /// file into the room, so what the recipients get is the same file.
  Future<RemoteFileShareResponse> shareRemoteFile({
    required RemoteFileShareRequest shareRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(shareRequest.httpMethod, shareRequest.uri, abortTrigger)
          ..headers.addAll({
            ...shareRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          })
          ..bodyBytes = shareRequest.bodyBytes;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 201, 400, 401, 403, 404, 429, 503},
      maximumBytes: remoteFilesMaximumShareBytes,
      readBodyForStatusCodes: const {200, 201},
    );
    return decodeRemoteFileShareResponse(
      request: shareRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}
