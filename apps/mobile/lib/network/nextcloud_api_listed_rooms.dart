part of 'nextcloud_api.dart';

mixin _NextcloudApiListedRooms on _HttpNextcloudApiBase {
  /// Lists the conversations the server publishes as open to everyone.
  Future<ListedRoomsResponse> listOpenRooms({
    required ListedRoomsRequest roomsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(roomsRequest.httpMethod, roomsRequest.uri, abortTrigger)
          ..headers.addAll({
            ...roomsRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 401, 403, 404, 429, 503},
      maximumBytes: listedRoomsMaximumResponseBytes,
      readBodyForStatusCodes: const {200},
    );
    return decodeListedRoomsResponse(
      request: roomsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Makes the account a participant of a conversation it merely saw listed.
  Future<JoinListedRoomResponse> joinListedRoom({
    required JoinListedRoomRequest joinRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(joinRequest.httpMethod, joinRequest.uri, abortTrigger)
          ..headers.addAll({
            ...joinRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          })
          ..bodyBytes = joinRequest.bodyBytes;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 401, 403, 404, 409, 429, 503},
      maximumBytes: listedRoomsMaximumResponseBytes,
      readBodyForStatusCodes: const {200},
    );
    return decodeJoinListedRoomResponse(
      request: joinRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}
