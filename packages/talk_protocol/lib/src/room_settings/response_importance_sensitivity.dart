part of 'response.dart';

sealed class SetImportantResponse {
  const SetImportantResponse(this.request);

  final SetImportantRequest request;
  int get statusCode;
}

final class SetImportantSuccess extends SetImportantResponse {
  const SetImportantSuccess._({
    required SetImportantRequest request,
    required this.room,
  }) : super(request);

  final ConversationRoom room;

  @override
  int get statusCode => 200;
}

final class SetImportantReauthenticationRequired extends SetImportantResponse {
  const SetImportantReauthenticationRequired._({
    required SetImportantRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

final class SetImportantRoomMissing extends SetImportantResponse {
  const SetImportantRoomMissing._({required SetImportantRequest request})
    : super(request);

  @override
  int get statusCode => 404;
}

final class SetImportantHttpFailure extends SetImportantResponse {
  const SetImportantHttpFailure._({
    required SetImportantRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;
}

SetImportantResponse decodeSetImportantResponse({
  required SetImportantRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      final room = _decodeRoom(body);
      if (room.isImportant != request.important) {
        protocolFailure(_responseCode, r'$.ocs.data.isImportant');
      }
      return SetImportantSuccess._(request: request, room: room);
    case 401:
      _decodeOcsEnvelope(body);
      return SetImportantReauthenticationRequired._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return SetImportantRoomMissing._(request: request);
    case 429:
      return SetImportantHttpFailure._(
        request: request,
        statusCode: statusCode,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return SetImportantHttpFailure._(
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

enum SensitiveRejection { classified }

sealed class SetSensitiveResponse {
  const SetSensitiveResponse(this.request);

  final SetSensitiveRequest request;
  int get statusCode;
}

final class SetSensitiveSuccess extends SetSensitiveResponse {
  const SetSensitiveSuccess._({
    required SetSensitiveRequest request,
    required this.room,
  }) : super(request);

  final ConversationRoom room;

  @override
  int get statusCode => 200;
}

final class SetSensitiveRejected extends SetSensitiveResponse {
  const SetSensitiveRejected._({
    required SetSensitiveRequest request,
    required this.reason,
  }) : super(request);

  final SensitiveRejection reason;

  @override
  int get statusCode => 400;
}

final class SetSensitiveReauthenticationRequired extends SetSensitiveResponse {
  const SetSensitiveReauthenticationRequired._({
    required SetSensitiveRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

final class SetSensitiveRoomMissing extends SetSensitiveResponse {
  const SetSensitiveRoomMissing._({required SetSensitiveRequest request})
    : super(request);

  @override
  int get statusCode => 404;
}

final class SetSensitiveHttpFailure extends SetSensitiveResponse {
  const SetSensitiveHttpFailure._({
    required SetSensitiveRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;
}

SetSensitiveResponse decodeSetSensitiveResponse({
  required SetSensitiveRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      final room = _decodeRoom(body);
      if (room.isSensitive != request.sensitive) {
        protocolFailure(_responseCode, r'$.ocs.data.isSensitive');
      }
      return SetSensitiveSuccess._(request: request, room: room);
    case 400:
      if (request.sensitive) {
        protocolFailure(_responseCode, r'$.statusCode');
      }
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
      if (error != 'classified') {
        protocolFailure(_responseCode, r'$.ocs.data.error');
      }
      return SetSensitiveRejected._(
        request: request,
        reason: SensitiveRejection.classified,
      );
    case 401:
      _decodeOcsEnvelope(body);
      return SetSensitiveReauthenticationRequired._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return SetSensitiveRoomMissing._(request: request);
    case 429:
      return SetSensitiveHttpFailure._(
        request: request,
        statusCode: statusCode,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return SetSensitiveHttpFailure._(
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
