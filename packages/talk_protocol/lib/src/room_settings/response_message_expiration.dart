part of 'response.dart';

/// Why Talk refused a message-expiration change with HTTP 400.
enum MessageExpirationRejection {
  breakoutRoom,
  conversationType,
  value,
  forced,
}

sealed class SetMessageExpirationResponse {
  const SetMessageExpirationResponse(this.request);

  final SetMessageExpirationRequest request;
  int get statusCode;
}

final class SetMessageExpirationSuccess extends SetMessageExpirationResponse {
  const SetMessageExpirationSuccess._({
    required SetMessageExpirationRequest request,
    required this.room,
  }) : super(request);

  final ConversationRoom room;

  @override
  int get statusCode => 200;
}

final class SetMessageExpirationRejected extends SetMessageExpirationResponse {
  const SetMessageExpirationRejected._({
    required SetMessageExpirationRequest request,
    required this.reason,
    required this.forcedSeconds,
  }) : super(request);

  final MessageExpirationRejection reason;

  /// The administrator-enforced value when [reason] is
  /// [MessageExpirationRejection.forced].
  final int? forcedSeconds;

  @override
  int get statusCode => 400;
}

final class SetMessageExpirationReauthenticationRequired
    extends SetMessageExpirationResponse {
  const SetMessageExpirationReauthenticationRequired._({
    required SetMessageExpirationRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

final class SetMessageExpirationForbidden extends SetMessageExpirationResponse {
  const SetMessageExpirationForbidden._({
    required SetMessageExpirationRequest request,
  }) : super(request);

  @override
  int get statusCode => 403;
}

final class SetMessageExpirationRoomMissing
    extends SetMessageExpirationResponse {
  const SetMessageExpirationRoomMissing._({
    required SetMessageExpirationRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;
}

final class SetMessageExpirationHttpFailure
    extends SetMessageExpirationResponse {
  const SetMessageExpirationHttpFailure._({
    required SetMessageExpirationRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;
}

SetMessageExpirationResponse decodeSetMessageExpirationResponse({
  required SetMessageExpirationRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      final room = _decodeRoom(body);
      final expiration = room.wire['messageExpiration'];
      if (expiration is! int || expiration < 0) {
        protocolFailure(_responseCode, r'$.ocs.data.messageExpiration');
      }
      return SetMessageExpirationSuccess._(request: request, room: room);
    case 400:
      final data = requireObject(
        _decodeOcsEnvelope(body),
        path: r'$.ocs.data',
        code: _responseCode,
      );
      final wireReason = requireString(
        data['error'],
        path: r'$.ocs.data.error',
        code: _responseCode,
        minLength: 1,
        maxLength: 32,
      );
      final reason = switch (wireReason) {
        'breakout-room' => MessageExpirationRejection.breakoutRoom,
        'type' => MessageExpirationRejection.conversationType,
        'value' => MessageExpirationRejection.value,
        'forced' => MessageExpirationRejection.forced,
        _ => protocolFailure(_responseCode, r'$.ocs.data.error'),
      };
      final forced = data['forced'];
      if (reason != MessageExpirationRejection.forced && forced != null) {
        protocolFailure(_responseCode, r'$.ocs.data.forced');
      }
      final forcedSeconds = reason == MessageExpirationRejection.forced
          ? requireInt(
              forced,
              path: r'$.ocs.data.forced',
              code: _responseCode,
              minimum: 0,
            )
          : null;
      return SetMessageExpirationRejected._(
        request: request,
        reason: reason,
        forcedSeconds: forcedSeconds,
      );
    case 401:
      _decodeOcsEnvelope(body);
      return SetMessageExpirationReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return SetMessageExpirationForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return SetMessageExpirationRoomMissing._(request: request);
    case 429:
      return SetMessageExpirationHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return SetMessageExpirationHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}
