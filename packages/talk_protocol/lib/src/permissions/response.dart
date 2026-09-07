part of 'permissions.dart';

sealed class PermissionUpdateResponse {
  const PermissionUpdateResponse(this.request, this.statusCode);
  final PermissionUpdateRequest request;
  final int statusCode;
}

final class RoomPermissionsUpdated extends PermissionUpdateResponse {
  const RoomPermissionsUpdated._(PermissionUpdateRequest request, this.room)
    : super(request, 200);
  final ConversationRoom room;
  @override
  String toString() => 'RoomPermissionsUpdated()';
}

final class AttendeePermissionsUpdated extends PermissionUpdateResponse {
  const AttendeePermissionsUpdated._(
    SetParticipantPermissionsRequest request,
    this.participant,
  ) : super(request, 200);
  final Participant participant;
  @override
  String toString() => 'AttendeePermissionsUpdated()';
}

enum PermissionUpdateFailureKind {
  rejected,
  reauthenticationRequired,
  forbidden,
  notFound,
  rateLimited,
  serviceUnavailable,
}

final class PermissionUpdateFailure extends PermissionUpdateResponse {
  const PermissionUpdateFailure._(
    super.request,
    super.statusCode,
    this.kind, {
    this.reason,
    this.forcedValue,
  });
  final PermissionUpdateFailureKind kind;
  final String? reason;
  final int? forcedValue;
  @override
  String toString() =>
      'PermissionUpdateFailure(statusCode: $statusCode, kind: ${kind.name})';
}

PermissionUpdateResponse decodePermissionUpdateResponse({
  required PermissionUpdateRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  const code = TalkProtocolErrorCode.invalidPermissionResponse;
  if (body.length > permissionUpdateMaximumBytes) {
    protocolFailure(code, r'$.body');
  }
  if (statusCode == 429 || statusCode == 503) {
    return PermissionUpdateFailure._(
      request,
      statusCode,
      statusCode == 429
          ? PermissionUpdateFailureKind.rateLimited
          : PermissionUpdateFailureKind.serviceUnavailable,
    );
  }
  if (!const {200, 400, 401, 403, 404}.contains(statusCode)) {
    protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    );
  }
  final Object? value;
  try {
    value =
        JsonFreezeSession(
          maximumDepth: 24,
          maximumNodes: 60000,
          errorCode: code,
          errorPath: r'$.body',
        ).freeze(
          decodeJsonRejectingDuplicateMembers(
            utf8.decode(body, allowMalformed: false),
            code: code,
            path: r'$.body',
          ),
        );
  } on FormatException {
    protocolFailure(code, r'$.body');
  }
  final root = requireObject(value, path: r'$', code: code);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: code);
  final meta = requireObject(ocs['meta'], path: r'$.ocs.meta', code: code);
  final ocsCode = requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: code,
    minimum: 0,
    maximum: 999,
  );
  if (!ocs.containsKey('data') ||
      meta['status'] != (statusCode == 200 ? 'ok' : 'failure') ||
      (ocsCode != statusCode && !(statusCode == 401 && ocsCode == 997))) {
    protocolFailure(code, r'$.ocs.meta');
  }
  final data = ocs['data'];
  if (statusCode != 200) {
    final details = data == null || (data is List && data.isEmpty)
        ? <String, Object?>{}
        : requireObject(data, path: r'$.ocs.data', code: code);
    final reason = details['error'] == null
        ? null
        : requireString(
            details['error'],
            path: r'$.ocs.data.error',
            code: code,
            maxLength: 128,
          );
    final forced = reason == 'forced'
        ? requireInt(
            details['forced'],
            path: r'$.ocs.data.forced',
            code: code,
            minimum: 0,
            maximum: request.kind == PermissionEditKind.mentions ? 1 : 511,
          )
        : null;
    return PermissionUpdateFailure._(
      request,
      statusCode,
      switch (statusCode) {
        400 => PermissionUpdateFailureKind.rejected,
        401 => PermissionUpdateFailureKind.reauthenticationRequired,
        403 => PermissionUpdateFailureKind.forbidden,
        _ => PermissionUpdateFailureKind.notFound,
      },
      reason: reason,
      forcedValue: forced,
    );
  }
  if (request is SetParticipantPermissionsRequest) {
    final list = requireList(data, path: r'$.ocs.data', code: code);
    if (list.length != 1) protocolFailure(code, r'$.ocs.data');
    final participant = parseParticipant(list.single, path: r'$.ocs.data[0]');
    if (participant.attendeeId != request.attendeeId) {
      protocolFailure(code, r'$.ocs.data[0].attendeeId');
    }
    return AttendeePermissionsUpdated._(request, participant);
  }
  final room = ConversationRoom.fromJson(data);
  if (room.token != request.roomToken) {
    protocolFailure(code, r'$.ocs.data.token');
  }
  return RoomPermissionsUpdated._(request, room);
}
