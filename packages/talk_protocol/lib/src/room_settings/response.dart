import 'dart:convert';
import 'dart:typed_data';

import '../conversations/models.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import 'request.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidRoomSettingsResponse;
const int roomSettingsMaximumWireBytes = 4 * 1024 * 1024;
const int _roomSettingsMaximumJsonDepth = 24;
const int _roomSettingsMaximumJsonNodes = 60000;

enum RoomSettingsHttpFailureKind { rateLimited, serviceUnavailable }

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
      return UpdateRoomNameSuccess._(
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

final class UpdateRoomDescriptionForbidden extends UpdateRoomDescriptionResponse {
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

// ---------------------------------------------------------------------------
// Delete (DELETE .../room/{token})
// ---------------------------------------------------------------------------

sealed class DeleteRoomResponse {
  const DeleteRoomResponse(this.request);

  final DeleteRoomRequest request;
  int get statusCode;
}

final class DeleteRoomSuccess extends DeleteRoomResponse {
  const DeleteRoomSuccess._({required DeleteRoomRequest request})
    : super(request);

  @override
  int get statusCode => 200;

  @override
  String toString() => 'DeleteRoomSuccess()';
}

/// HTTP 400. The server refused the deletion, e.g. a one-to-one conversation
/// that can only be left.
final class DeleteRoomRejected extends DeleteRoomResponse {
  const DeleteRoomRejected._({required DeleteRoomRequest request})
    : super(request);

  @override
  int get statusCode => 400;

  @override
  String toString() => 'DeleteRoomRejected()';
}

final class DeleteRoomReauthenticationRequired extends DeleteRoomResponse {
  const DeleteRoomReauthenticationRequired._({
    required DeleteRoomRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'DeleteRoomReauthenticationRequired()';
}

/// HTTP 403. The caller is not a moderator or owner of the conversation.
final class DeleteRoomForbidden extends DeleteRoomResponse {
  const DeleteRoomForbidden._({required DeleteRoomRequest request})
    : super(request);

  @override
  int get statusCode => 403;

  @override
  String toString() => 'DeleteRoomForbidden()';
}

final class DeleteRoomRoomMissing extends DeleteRoomResponse {
  const DeleteRoomRoomMissing._({required DeleteRoomRequest request})
    : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'DeleteRoomRoomMissing()';
}

final class DeleteRoomHttpFailure extends DeleteRoomResponse {
  const DeleteRoomHttpFailure._({
    required DeleteRoomRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;

  @override
  String toString() =>
      'DeleteRoomHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

DeleteRoomResponse decodeDeleteRoomResponse({
  required DeleteRoomRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 400:
      _decodeOcsEnvelope(body);
      return DeleteRoomRejected._(request: request);
    case 401:
      _decodeOcsEnvelope(body);
      return DeleteRoomReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return DeleteRoomForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return DeleteRoomRoomMissing._(request: request);
    case 429:
      return DeleteRoomHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return DeleteRoomHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      _decodeOcsEnvelope(body);
      return DeleteRoomSuccess._(request: request);
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

// ---------------------------------------------------------------------------
// Leave (DELETE .../room/{token}/participants/self)
// ---------------------------------------------------------------------------

sealed class LeaveRoomResponse {
  const LeaveRoomResponse(this.request);

  final LeaveRoomRequest request;
  int get statusCode;
}

final class LeaveRoomSuccess extends LeaveRoomResponse {
  const LeaveRoomSuccess._({required LeaveRoomRequest request})
    : super(request);

  @override
  int get statusCode => 200;

  @override
  String toString() => 'LeaveRoomSuccess()';
}

final class LeaveRoomReauthenticationRequired extends LeaveRoomResponse {
  const LeaveRoomReauthenticationRequired._({
    required LeaveRoomRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'LeaveRoomReauthenticationRequired()';
}

/// HTTP 400. The server refused the departure, e.g. the caller is the last
/// moderator and must promote someone else before leaving.
final class LeaveRoomRejected extends LeaveRoomResponse {
  const LeaveRoomRejected._({required LeaveRoomRequest request})
    : super(request);

  @override
  int get statusCode => 400;

  @override
  String toString() => 'LeaveRoomRejected()';
}

final class LeaveRoomForbidden extends LeaveRoomResponse {
  const LeaveRoomForbidden._({required LeaveRoomRequest request})
    : super(request);

  @override
  int get statusCode => 403;

  @override
  String toString() => 'LeaveRoomForbidden()';
}

final class LeaveRoomRoomMissing extends LeaveRoomResponse {
  const LeaveRoomRoomMissing._({required LeaveRoomRequest request})
    : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'LeaveRoomRoomMissing()';
}

final class LeaveRoomHttpFailure extends LeaveRoomResponse {
  const LeaveRoomHttpFailure._({
    required LeaveRoomRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;

  @override
  String toString() =>
      'LeaveRoomHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

LeaveRoomResponse decodeLeaveRoomResponse({
  required LeaveRoomRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 400:
      _decodeOcsEnvelope(body);
      return LeaveRoomRejected._(request: request);
    case 401:
      _decodeOcsEnvelope(body);
      return LeaveRoomReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return LeaveRoomForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return LeaveRoomRoomMissing._(request: request);
    case 429:
      return LeaveRoomHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return LeaveRoomHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      _decodeOcsEnvelope(body);
      return LeaveRoomSuccess._(request: request);
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

// ---------------------------------------------------------------------------
// Conversation administration (public, password, lobby, read-only, avatar)
// ---------------------------------------------------------------------------

/// A classified response to any [RoomAdministrationRequest].
///
/// The six administration endpoints answer with the same status codes and the
/// same meaning for each of them, so they share one response family the way
/// the three participant-moderation endpoints do.
sealed class RoomAdministrationResponse {
  const RoomAdministrationResponse(this.request);

  final RoomAdministrationRequest request;
  int get statusCode;
}

/// HTTP 200. The change was applied.
///
/// [room] is the refreshed conversation when the endpoint answered with one:
/// Talk `docs/webinar.md` and `docs/avatar.md` document the lobby and avatar
/// payloads as "See array definition in Get user´s conversations", while the
/// public, password and read-only sections document no data at all. A caller
/// that needs the new state either uses [room] or refetches.
final class RoomAdministrationSuccess extends RoomAdministrationResponse {
  RoomAdministrationSuccess._({
    required RoomAdministrationRequest request,
    required this.room,
  }) : super(request);

  @override
  int get statusCode => 200;

  final ConversationRoom? room;

  @override
  String toString() => 'RoomAdministrationSuccess(room: ${room != null})';
}

/// HTTP 400. The server refused the change: the conversation type does not
/// support it, the value is invalid, or a password violated the instance
/// policy.
///
/// [message] is the translated explanation Talk `docs/conversation.md`
/// ("Set password for a conversation") tells clients to show: "`400 Bad
/// Request` When the password does not match the password policy. Show
/// `ocs.data.message` to the user in this case". It is `null` for every other
/// refusal, which carries no such field.
final class RoomAdministrationRejected extends RoomAdministrationResponse {
  const RoomAdministrationRejected._({
    required RoomAdministrationRequest request,
    required this.message,
  }) : super(request);

  @override
  int get statusCode => 400;

  final String? message;

  /// Never renders [message]: the server composes it from the failing
  /// password policy rules, so it is about a secret the caller just sent.
  @override
  String toString() =>
      'RoomAdministrationRejected(explained: ${message != null})';
}

/// HTTP 401. The account must reauthenticate before another call.
final class RoomAdministrationReauthenticationRequired
    extends RoomAdministrationResponse {
  const RoomAdministrationReauthenticationRequired._({
    required RoomAdministrationRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'RoomAdministrationReauthenticationRequired()';
}

/// HTTP 403. The caller is not a moderator or owner of the conversation, or
/// the conversation is not public where the endpoint requires it to be.
final class RoomAdministrationForbidden extends RoomAdministrationResponse {
  const RoomAdministrationForbidden._({
    required RoomAdministrationRequest request,
  }) : super(request);

  @override
  int get statusCode => 403;

  @override
  String toString() => 'RoomAdministrationForbidden()';
}

/// HTTP 404. The conversation no longer exists for this participant.
final class RoomAdministrationRoomMissing extends RoomAdministrationResponse {
  const RoomAdministrationRoomMissing._({
    required RoomAdministrationRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'RoomAdministrationRoomMissing()';
}

/// A supported non-body HTTP failure.
final class RoomAdministrationHttpFailure extends RoomAdministrationResponse {
  const RoomAdministrationHttpFailure._({
    required RoomAdministrationRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;

  @override
  String toString() =>
      'RoomAdministrationHttpFailure(statusCode: $statusCode, '
      'kind: ${kind.name})';
}

RoomAdministrationResponse decodeRoomAdministrationResponse({
  required RoomAdministrationRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 400:
      return RoomAdministrationRejected._(
        request: request,
        message: _optionalRejectionMessage(_decodeOcsEnvelope(body)),
      );
    case 401:
      _decodeOcsEnvelope(body);
      return RoomAdministrationReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return RoomAdministrationForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return RoomAdministrationRoomMissing._(request: request);
    case 429:
      return RoomAdministrationHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return RoomAdministrationHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      return RoomAdministrationSuccess._(
        request: request,
        room: _optionalRoom(_decodeOcsEnvelope(body)),
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

/// Reads the refreshed conversation out of a `200` payload, or returns `null`
/// when the endpoint answered without one. PHP renders an empty associative
/// array as `[]`, so a list is the documented "no data" shape rather than a
/// malformed room.
ConversationRoom? _optionalRoom(Object? data) {
  if (data == null || data is List<Object?>) {
    return null;
  }
  final session = JsonFreezeSession(
    errorCode: _responseCode,
    errorPath: r'$.ocs.data',
  );
  return parseConversationRoom(data, path: r'$.ocs.data', session: session);
}

/// Reads `ocs.data.message` out of a `400` payload. Absent for every refusal
/// except a violated password policy, and never trusted beyond a bounded
/// string.
String? _optionalRejectionMessage(Object? data) {
  if (data is! Map<String, Object?> || data['message'] == null) {
    return null;
  }
  return requireString(
    data['message'],
    path: r'$.ocs.data.message',
    code: _responseCode,
    maxLength: 4096,
  );
}

// ---------------------------------------------------------------------------
// Shared envelope decoding
// ---------------------------------------------------------------------------

ConversationRoom _decodeRoom(Uint8List body) {
  final data = _decodeOcsEnvelope(body);
  final session = JsonFreezeSession(
    errorCode: _responseCode,
    errorPath: r'$.ocs.data',
  );
  return parseConversationRoom(data, path: r'$.ocs.data', session: session);
}

Object? _decodeOcsEnvelope(Uint8List body) {
  final decoded = _decodeJsonBytes(body);
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: _responseCode,
  );
  final status = requireString(
    meta['status'],
    path: r'$.ocs.meta.status',
    code: _responseCode,
    minLength: 1,
    maxLength: 32,
  );
  if (status != 'ok' && status != 'failure') {
    protocolFailure(_responseCode, r'$.ocs.meta.status');
  }
  requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: _responseCode,
    minimum: 0,
    maximum: 999,
  );
  if (!ocs.containsKey('data')) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  return ocs['data'];
}

Object? _decodeJsonBytes(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > roomSettingsMaximumWireBytes) {
    protocolFailure(_responseCode, r'$');
  }
  try {
    final decoded = decodeJsonRejectingDuplicateMembers(
      utf8.decode(bytes, allowMalformed: false),
      code: _responseCode,
      path: r'$',
    );
    return JsonFreezeSession(
      maximumDepth: _roomSettingsMaximumJsonDepth,
      maximumNodes: _roomSettingsMaximumJsonNodes,
      errorCode: _responseCode,
      errorPath: r'$',
    ).freeze(decoded);
  } on FormatException {
    protocolFailure(_responseCode, r'$');
  }
}
