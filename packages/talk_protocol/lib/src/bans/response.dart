import 'dart:convert';
import 'dart:typed_data';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'request.dart';

const int bansMaximumCount = 5000;
const int bansMaximumWireBytes = 2 * 1024 * 1024;
const int _bansMaximumJsonDepth = 16;
const int _bansMaximumJsonNodes = 60000;

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidBansResponse;

/// One ban on a conversation.
///
/// Field names and types come from the `TalkBan` psalm type in
/// `lib/ResponseDefinitions.php`: `id: int`, `moderatorActorType: string`,
/// `moderatorActorId: string`, `moderatorDisplayName: string`,
/// `bannedActorType: string`, `bannedActorId: string`,
/// `bannedDisplayName: string`, `bannedTime: int` ("UNIX timestamp when the
/// participant was banned") and `internalNote: string` ("Internal note for
/// the moderator to remember the reason for the ban").
final class RoomBan {
  RoomBan._({
    required this.id,
    required this.moderatorActorType,
    required this.moderatorActorId,
    required this.moderatorDisplayName,
    required this.bannedActorType,
    required this.bannedActorId,
    required this.bannedDisplayName,
    required this.bannedTime,
    required this.internalNote,
  });

  final int id;
  final String moderatorActorType;
  final String moderatorActorId;
  final String moderatorDisplayName;
  final String bannedActorType;
  final String bannedActorId;
  final String bannedDisplayName;

  /// UNIX timestamp in seconds.
  final int bannedTime;

  final String internalNote;

  /// Renders only [id]: every other field names a real person or repeats a
  /// moderator's private remark about one.
  @override
  String toString() => 'RoomBan(id: $id)';
}

RoomBan parseRoomBan(Object? json, {required String path}) {
  final ban = requireObject(json, path: path, code: _responseCode);
  return RoomBan._(
    id: requireInt(
      ban['id'],
      path: '$path.id',
      code: _responseCode,
      minimum: 0,
    ),
    moderatorActorType: _string(ban, 'moderatorActorType', path, 128),
    moderatorActorId: _string(ban, 'moderatorActorId', path, 4096),
    moderatorDisplayName: _string(ban, 'moderatorDisplayName', path, 4096),
    bannedActorType: _string(ban, 'bannedActorType', path, 128),
    bannedActorId: _string(ban, 'bannedActorId', path, 4096),
    bannedDisplayName: _string(ban, 'bannedDisplayName', path, 4096),
    bannedTime: requireInt(
      ban['bannedTime'],
      path: '$path.bannedTime',
      code: _responseCode,
      minimum: 0,
    ),
    internalNote: _string(ban, 'internalNote', path, banNoteMaximumLength),
  );
}

String _string(
  Map<String, Object?> object,
  String key,
  String parentPath,
  int maxLength,
) {
  return requireString(
    object[key],
    path: '$parentPath.$key',
    code: _responseCode,
    maxLength: maxLength,
  );
}

/// A classified response to a ban list, ban or unban request.
///
/// All three endpoints carry `#[PublicPage]` and
/// `#[RequireModeratorParticipant]` in `lib/Controller/BanController.php`, so
/// they refuse a non-moderator the same way and share one response family.
sealed class RoomBanResponse {
  const RoomBanResponse();

  int get statusCode;
}

/// HTTP 200 for a list request, with every ban on the conversation.
final class RoomBanListSuccess extends RoomBanResponse {
  RoomBanListSuccess._({required this.bans});

  @override
  int get statusCode => 200;

  final List<RoomBan> bans;

  @override
  String toString() => 'RoomBanListSuccess(count: ${bans.length})';
}

/// HTTP 200 for a ban or unban request.
///
/// [ban] is the newly created ban that `banActor` answers with
/// (`DataResponse<Http::STATUS_OK, TalkBan, array{}>`); `unbanActor` answers
/// `DataResponse<Http::STATUS_OK, null, array{}>`, so it is `null` there.
final class RoomBanChangeSuccess extends RoomBanResponse {
  RoomBanChangeSuccess._({required this.ban});

  @override
  int get statusCode => 200;

  final RoomBan? ban;

  @override
  String toString() => 'RoomBanChangeSuccess(created: ${ban != null})';
}

/// HTTP 400. `BanController::banActor` documents this as "Actor information
/// is invalid" and answers `array{error: 'bannedActor'|'internalNote'|
/// 'moderator'|'self'|'room'}`. [error] carries that discriminator verbatim
/// when the server sent one.
final class RoomBanRejected extends RoomBanResponse {
  const RoomBanRejected._({required this.error});

  @override
  int get statusCode => 400;

  final String? error;

  @override
  String toString() => 'RoomBanRejected(error: ${error ?? 'unknown'})';
}

/// HTTP 401. The account must reauthenticate before another call.
final class RoomBanReauthenticationRequired extends RoomBanResponse {
  const RoomBanReauthenticationRequired._();

  @override
  int get statusCode => 401;

  @override
  String toString() => 'RoomBanReauthenticationRequired()';
}

/// HTTP 403. The caller is not a moderator of the conversation.
final class RoomBanForbidden extends RoomBanResponse {
  const RoomBanForbidden._();

  @override
  int get statusCode => 403;

  @override
  String toString() => 'RoomBanForbidden()';
}

/// HTTP 404. The conversation no longer exists for this participant.
final class RoomBanRoomMissing extends RoomBanResponse {
  const RoomBanRoomMissing._();

  @override
  int get statusCode => 404;

  @override
  String toString() => 'RoomBanRoomMissing()';
}

/// A supported non-body HTTP failure.
final class RoomBanHttpFailure extends RoomBanResponse {
  const RoomBanHttpFailure._({required this.statusCode, required this.kind});

  @override
  final int statusCode;
  final RoomBanHttpFailureKind kind;

  @override
  String toString() =>
      'RoomBanHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

enum RoomBanHttpFailureKind { rateLimited, serviceUnavailable }

RoomBanResponse decodeListBansResponse({
  required ListBansRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final shared = _decodeSharedStatus(statusCode, body);
  if (shared != null) {
    return shared;
  }
  final data = _decodeOcsEnvelope(body);
  final rawBans = requireList(data, path: r'$.ocs.data', code: _responseCode);
  if (rawBans.length > bansMaximumCount) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  return RoomBanListSuccess._(
    bans: List<RoomBan>.unmodifiable([
      for (var index = 0; index < rawBans.length; index++)
        parseRoomBan(rawBans[index], path: r'$.ocs.data[' '$index]'),
    ]),
  );
}

RoomBanResponse decodeBanActorResponse({
  required BanActorRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final shared = _decodeSharedStatus(statusCode, body);
  if (shared != null) {
    return shared;
  }
  final data = _decodeOcsEnvelope(body);
  // PHP renders an empty associative array as `[]`; a server that answered
  // without a body still applied the ban, so that is success without a ban
  // object rather than a malformed payload.
  if (data == null || data is List<Object?>) {
    return RoomBanChangeSuccess._(ban: null);
  }
  return RoomBanChangeSuccess._(ban: parseRoomBan(data, path: r'$.ocs.data'));
}

RoomBanResponse decodeUnbanActorResponse({
  required UnbanActorRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final shared = _decodeSharedStatus(statusCode, body);
  if (shared != null) {
    return shared;
  }
  _decodeOcsEnvelope(body);
  return RoomBanChangeSuccess._(ban: null);
}

/// Classifies every status code except `200`, which each endpoint decodes on
/// its own because the payload shapes differ.
RoomBanResponse? _decodeSharedStatus(int statusCode, Uint8List body) {
  switch (statusCode) {
    case 200:
      return null;
    case 400:
      final data = _decodeOcsEnvelope(body);
      return RoomBanRejected._(error: _optionalError(data));
    case 401:
      _decodeOcsEnvelope(body);
      return const RoomBanReauthenticationRequired._();
    case 403:
      _decodeOcsEnvelope(body);
      return const RoomBanForbidden._();
    case 404:
      _decodeOcsEnvelope(body);
      return const RoomBanRoomMissing._();
    case 429:
      return const RoomBanHttpFailure._(
        statusCode: 429,
        kind: RoomBanHttpFailureKind.rateLimited,
      );
    case 503:
      return const RoomBanHttpFailure._(
        statusCode: 503,
        kind: RoomBanHttpFailureKind.serviceUnavailable,
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

String? _optionalError(Object? data) {
  if (data is! Map<String, Object?> || data['error'] == null) {
    return null;
  }
  return requireString(
    data['error'],
    path: r'$.ocs.data.error',
    code: _responseCode,
    maxLength: 128,
  );
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
  if (bytes.isEmpty || bytes.length > bansMaximumWireBytes) {
    protocolFailure(_responseCode, r'$');
  }
  try {
    final decoded = decodeJsonRejectingDuplicateMembers(
      utf8.decode(bytes, allowMalformed: false),
      code: _responseCode,
      path: r'$',
    );
    return JsonFreezeSession(
      maximumDepth: _bansMaximumJsonDepth,
      maximumNodes: _bansMaximumJsonNodes,
      errorCode: _responseCode,
      errorPath: r'$',
    ).freeze(decoded);
  } on FormatException {
    protocolFailure(_responseCode, r'$');
  }
}
