part of 'response.dart';

// ---------------------------------------------------------------------------
// Rename (PUT .../room/{token})
// ---------------------------------------------------------------------------

sealed class UpdateRoomNameResponse {
  const UpdateRoomNameResponse(this.request);

  final UpdateRoomNameRequest request;
  int get statusCode;
}

final class UpdateRoomNameSuccess extends UpdateRoomNameResponse {
  UpdateRoomNameSuccess._({
    required UpdateRoomNameRequest request,
    required this.room,
  }) : super(request);

  @override
  int get statusCode => 200;

  final ConversationRoom room;

  @override
  String toString() => 'UpdateRoomNameSuccess()';
}

final class UpdateRoomNameReauthenticationRequired
    extends UpdateRoomNameResponse {
  const UpdateRoomNameReauthenticationRequired._({
    required UpdateRoomNameRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'UpdateRoomNameReauthenticationRequired()';
}

final class UpdateRoomNameForbidden extends UpdateRoomNameResponse {
  const UpdateRoomNameForbidden._({required UpdateRoomNameRequest request})
    : super(request);

  @override
  int get statusCode => 403;

  @override
  String toString() => 'UpdateRoomNameForbidden()';
}

final class UpdateRoomNameRoomMissing extends UpdateRoomNameResponse {
  const UpdateRoomNameRoomMissing._({required UpdateRoomNameRequest request})
    : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'UpdateRoomNameRoomMissing()';
}

final class UpdateRoomNameHttpFailure extends UpdateRoomNameResponse {
  const UpdateRoomNameHttpFailure._({
    required UpdateRoomNameRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;

  @override
  String toString() =>
      'UpdateRoomNameHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

UpdateRoomNameResponse decodeUpdateRoomNameResponse({
  required UpdateRoomNameRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 401:
      _decodeOcsEnvelope(body);
      return UpdateRoomNameReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return UpdateRoomNameForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return UpdateRoomNameRoomMissing._(request: request);
    case 429:
      return UpdateRoomNameHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return UpdateRoomNameHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      return UpdateRoomNameSuccess._(request: request, room: _decodeRoom(body));
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

// ---------------------------------------------------------------------------
// Description (PUT .../room/{token}/description)
// ---------------------------------------------------------------------------

sealed class UpdateRoomDescriptionResponse {
  const UpdateRoomDescriptionResponse(this.request);

  final UpdateRoomDescriptionRequest request;
  int get statusCode;
}

final class UpdateRoomDescriptionSuccess extends UpdateRoomDescriptionResponse {
  UpdateRoomDescriptionSuccess._({
    required UpdateRoomDescriptionRequest request,
    required this.room,
  }) : super(request);

  @override
  int get statusCode => 200;

  final ConversationRoom room;

  @override
  String toString() => 'UpdateRoomDescriptionSuccess()';
}

final class UpdateRoomDescriptionReauthenticationRequired
    extends UpdateRoomDescriptionResponse {
  const UpdateRoomDescriptionReauthenticationRequired._({
    required UpdateRoomDescriptionRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'UpdateRoomDescriptionReauthenticationRequired()';
}

final class UpdateRoomDescriptionForbidden
    extends UpdateRoomDescriptionResponse {
  const UpdateRoomDescriptionForbidden._({
    required UpdateRoomDescriptionRequest request,
  }) : super(request);

  @override
  int get statusCode => 403;

  @override
  String toString() => 'UpdateRoomDescriptionForbidden()';
}

final class UpdateRoomDescriptionRoomMissing
    extends UpdateRoomDescriptionResponse {
  const UpdateRoomDescriptionRoomMissing._({
    required UpdateRoomDescriptionRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'UpdateRoomDescriptionRoomMissing()';
}

final class UpdateRoomDescriptionHttpFailure
    extends UpdateRoomDescriptionResponse {
  const UpdateRoomDescriptionHttpFailure._({
    required UpdateRoomDescriptionRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;

  @override
  String toString() =>
      'UpdateRoomDescriptionHttpFailure(statusCode: $statusCode, '
      'kind: ${kind.name})';
}

UpdateRoomDescriptionResponse decodeUpdateRoomDescriptionResponse({
  required UpdateRoomDescriptionRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 401:
      _decodeOcsEnvelope(body);
      return UpdateRoomDescriptionReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return UpdateRoomDescriptionForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return UpdateRoomDescriptionRoomMissing._(request: request);
    case 429:
      return UpdateRoomDescriptionHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return UpdateRoomDescriptionHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      return UpdateRoomDescriptionSuccess._(
        request: request,
        room: _decodeRoom(body),
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

// ---------------------------------------------------------------------------
// Notification level (POST .../room/{token}/notify)
// ---------------------------------------------------------------------------

sealed class UpdateNotificationLevelResponse {
  const UpdateNotificationLevelResponse(this.request);

  final UpdateNotificationLevelRequest request;
  int get statusCode;
}

final class UpdateNotificationLevelSuccess
    extends UpdateNotificationLevelResponse {
  const UpdateNotificationLevelSuccess._({
    required UpdateNotificationLevelRequest request,
  }) : super(request);

  @override
  int get statusCode => 200;

  @override
  String toString() => 'UpdateNotificationLevelSuccess()';
}

final class UpdateNotificationLevelReauthenticationRequired
    extends UpdateNotificationLevelResponse {
  const UpdateNotificationLevelReauthenticationRequired._({
    required UpdateNotificationLevelRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'UpdateNotificationLevelReauthenticationRequired()';
}

final class UpdateNotificationLevelRoomMissing
    extends UpdateNotificationLevelResponse {
  const UpdateNotificationLevelRoomMissing._({
    required UpdateNotificationLevelRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'UpdateNotificationLevelRoomMissing()';
}

final class UpdateNotificationLevelHttpFailure
    extends UpdateNotificationLevelResponse {
  const UpdateNotificationLevelHttpFailure._({
    required UpdateNotificationLevelRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;

  @override
  String toString() =>
      'UpdateNotificationLevelHttpFailure(statusCode: $statusCode, '
      'kind: ${kind.name})';
}

UpdateNotificationLevelResponse decodeUpdateNotificationLevelResponse({
  required UpdateNotificationLevelRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 401:
      _decodeOcsEnvelope(body);
      return UpdateNotificationLevelReauthenticationRequired._(
        request: request,
      );
    case 404:
      _decodeOcsEnvelope(body);
      return UpdateNotificationLevelRoomMissing._(request: request);
    case 429:
      return UpdateNotificationLevelHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return UpdateNotificationLevelHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      _decodeOcsEnvelope(body);
      return UpdateNotificationLevelSuccess._(request: request);
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

// ---------------------------------------------------------------------------
// Favorite (POST/DELETE .../room/{token}/favorite)
// ---------------------------------------------------------------------------

sealed class SetFavoriteResponse {
  const SetFavoriteResponse(this.request);

  final SetFavoriteRequest request;
  int get statusCode;
}

final class SetFavoriteSuccess extends SetFavoriteResponse {
  const SetFavoriteSuccess._({required SetFavoriteRequest request})
    : super(request);

  @override
  int get statusCode => 200;

  @override
  String toString() => 'SetFavoriteSuccess()';
}

final class SetFavoriteReauthenticationRequired extends SetFavoriteResponse {
  const SetFavoriteReauthenticationRequired._({
    required SetFavoriteRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'SetFavoriteReauthenticationRequired()';
}

final class SetFavoriteRoomMissing extends SetFavoriteResponse {
  const SetFavoriteRoomMissing._({required SetFavoriteRequest request})
    : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'SetFavoriteRoomMissing()';
}

final class SetFavoriteHttpFailure extends SetFavoriteResponse {
  const SetFavoriteHttpFailure._({
    required SetFavoriteRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;

  @override
  String toString() =>
      'SetFavoriteHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

SetFavoriteResponse decodeSetFavoriteResponse({
  required SetFavoriteRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 401:
      _decodeOcsEnvelope(body);
      return SetFavoriteReauthenticationRequired._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return SetFavoriteRoomMissing._(request: request);
    case 429:
      return SetFavoriteHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return SetFavoriteHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      _decodeOcsEnvelope(body);
      return SetFavoriteSuccess._(request: request);
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

// ---------------------------------------------------------------------------
// Archive (POST/DELETE .../room/{token}/archive)
// ---------------------------------------------------------------------------

sealed class SetArchivedResponse {
  const SetArchivedResponse(this.request);

  final SetArchivedRequest request;
  int get statusCode;
}

final class SetArchivedSuccess extends SetArchivedResponse {
  const SetArchivedSuccess._({required SetArchivedRequest request})
    : super(request);

  @override
  int get statusCode => 200;

  @override
  String toString() => 'SetArchivedSuccess()';
}

final class SetArchivedReauthenticationRequired extends SetArchivedResponse {
  const SetArchivedReauthenticationRequired._({
    required SetArchivedRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'SetArchivedReauthenticationRequired()';
}

final class SetArchivedRoomMissing extends SetArchivedResponse {
  const SetArchivedRoomMissing._({required SetArchivedRequest request})
    : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'SetArchivedRoomMissing()';
}

final class SetArchivedHttpFailure extends SetArchivedResponse {
  const SetArchivedHttpFailure._({
    required SetArchivedRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;

  @override
  String toString() =>
      'SetArchivedHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

SetArchivedResponse decodeSetArchivedResponse({
  required SetArchivedRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 401:
      _decodeOcsEnvelope(body);
      return SetArchivedReauthenticationRequired._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return SetArchivedRoomMissing._(request: request);
    case 429:
      return SetArchivedHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return SetArchivedHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      _decodeOcsEnvelope(body);
      return SetArchivedSuccess._(request: request);
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}
