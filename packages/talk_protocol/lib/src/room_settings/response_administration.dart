part of 'response.dart';

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
  const LeaveRoomReauthenticationRequired._({required LeaveRoomRequest request})
    : super(request);

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
// Conversation administration
// ---------------------------------------------------------------------------

/// A classified response to any [RoomAdministrationRequest].
///
/// The administration endpoints share their common response family. SIP also
/// uses 412 when the instance has no configured bridge.
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
    this.statusCode = 200,
  }) : super(request);

  /// 200 for every change, 201 for the breakout broadcast, which creates
  /// messages rather than changing the conversation.
  @override
  final int statusCode;

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

/// HTTP 412. A server-side component required for this setting is not
/// configured. Talk uses it for SIP when no SIP bridge is available.
final class RoomAdministrationPreconditionFailed
    extends RoomAdministrationResponse {
  const RoomAdministrationPreconditionFailed._({
    required RoomAdministrationRequest request,
  }) : super(request);

  @override
  int get statusCode => 412;

  @override
  String toString() => 'RoomAdministrationPreconditionFailed()';
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
    case 412:
      _decodeOcsEnvelope(body);
      return RoomAdministrationPreconditionFailed._(request: request);
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
    case 201:
      // The breakout broadcast: `ocs.data` holds the created chat messages,
      // which is not a conversation and is not needed here.
      _decodeOcsEnvelope(body);
      return RoomAdministrationSuccess._(
        request: request,
        room: null,
        statusCode: 201,
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

/// The breakout rooms of a parent conversation, or why they could not be read.
final class BreakoutRoomsListResponse {
  const BreakoutRoomsListResponse._({
    required this.request,
    required this.statusCode,
    required this.rooms,
  });

  final BreakoutRoomsListRequest request;
  final int statusCode;

  /// Empty for every status but 200.
  final List<ConversationRoom> rooms;

  bool get isSuccess => statusCode == 200;

  @override
  String toString() =>
      'BreakoutRoomsListResponse(status: $statusCode, rooms: ${rooms.length})';
}

/// 200 carries the rooms; 400/401/403/404/429/503 carry nothing. Anything
/// else is a protocol failure, like every other decoder here.
BreakoutRoomsListResponse decodeBreakoutRoomsListResponse({
  required BreakoutRoomsListRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      final data = _decodeOcsEnvelope(body);
      final items = requireList(data, path: r'$.ocs.data', code: _responseCode);
      if (items.length > breakoutRoomsMaximum) {
        protocolFailure(_responseCode, r'$.ocs.data.length');
      }
      final session = JsonFreezeSession(
        errorCode: _responseCode,
        errorPath: r'$.ocs.data',
      );
      return BreakoutRoomsListResponse._(
        request: request,
        statusCode: 200,
        rooms: List.unmodifiable([
          for (var i = 0; i < items.length; i++)
            parseConversationRoom(
              items[i],
              path: '\$.ocs.data[$i]',
              session: session,
            ),
        ]),
      );
    case 400:
    case 401:
    case 403:
    case 404:
      _decodeOcsEnvelope(body);
      return BreakoutRoomsListResponse._(
        request: request,
        statusCode: statusCode,
        rooms: const <ConversationRoom>[],
      );
    case 429:
    case 503:
      return BreakoutRoomsListResponse._(
        request: request,
        statusCode: statusCode,
        rooms: const <ConversationRoom>[],
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}
