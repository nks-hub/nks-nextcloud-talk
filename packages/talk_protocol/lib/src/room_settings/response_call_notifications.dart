part of 'response.dart';

sealed class UpdateCallNotificationLevelResponse {
  const UpdateCallNotificationLevelResponse(this.request);

  final UpdateCallNotificationLevelRequest request;
  int get statusCode;
}

final class UpdateCallNotificationLevelSuccess
    extends UpdateCallNotificationLevelResponse {
  const UpdateCallNotificationLevelSuccess._({
    required UpdateCallNotificationLevelRequest request,
    required this.room,
  }) : super(request);

  final ConversationRoom room;

  @override
  int get statusCode => 200;
}

final class UpdateCallNotificationLevelRejected
    extends UpdateCallNotificationLevelResponse {
  const UpdateCallNotificationLevelRejected._({
    required UpdateCallNotificationLevelRequest request,
  }) : super(request);

  @override
  int get statusCode => 400;
}

final class UpdateCallNotificationLevelReauthenticationRequired
    extends UpdateCallNotificationLevelResponse {
  const UpdateCallNotificationLevelReauthenticationRequired._({
    required UpdateCallNotificationLevelRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

final class UpdateCallNotificationLevelRoomMissing
    extends UpdateCallNotificationLevelResponse {
  const UpdateCallNotificationLevelRoomMissing._({
    required UpdateCallNotificationLevelRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;
}

final class UpdateCallNotificationLevelHttpFailure
    extends UpdateCallNotificationLevelResponse {
  const UpdateCallNotificationLevelHttpFailure._({
    required UpdateCallNotificationLevelRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;
}

UpdateCallNotificationLevelResponse decodeUpdateCallNotificationLevelResponse({
  required UpdateCallNotificationLevelRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      return UpdateCallNotificationLevelSuccess._(
        request: request,
        room: _decodeRoom(body),
      );
    case 400:
      final data = requireObject(
        _decodeOcsEnvelope(body),
        path: r'$.ocs.data',
        code: _responseCode,
      );
      final error = requireString(
        data['error'],
        path: r'$.ocs.data.error',
        code: _responseCode,
        minLength: 1,
        maxLength: 32,
      );
      if (error != 'level') {
        protocolFailure(_responseCode, r'$.ocs.data.error');
      }
      return UpdateCallNotificationLevelRejected._(request: request);
    case 401:
      _decodeOcsEnvelope(body);
      return UpdateCallNotificationLevelReauthenticationRequired._(
        request: request,
      );
    case 404:
      _decodeOcsEnvelope(body);
      return UpdateCallNotificationLevelRoomMissing._(request: request);
    case 429:
      return UpdateCallNotificationLevelHttpFailure._(
        request: request,
        statusCode: statusCode,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return UpdateCallNotificationLevelHttpFailure._(
        request: request,
        statusCode: statusCode,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}
