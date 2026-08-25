import 'dart:convert';
import 'dart:typed_data';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';

const int participantsMaximumCount = 5000;
const int participantsMaximumWireBytes = 4 * 1024 * 1024;
const int _participantsMaximumJsonDepth = 24;
const int _participantsMaximumJsonNodes = 60000;
const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidParticipantsResponse;

/// A classified response from the room participants endpoint.
sealed class ParticipantsResponse {
  const ParticipantsResponse(this.request);

  final ParticipantsRequest request;
  int get statusCode;
}

/// HTTP 200 with OCS success and a validated participant list.
final class ParticipantsSuccess extends ParticipantsResponse {
  ParticipantsSuccess._({
    required ParticipantsRequest request,
    required this.participants,
  }) : super(request);

  @override
  int get statusCode => 200;

  final List<Participant> participants;

  @override
  String toString() => 'ParticipantsSuccess(count: ${participants.length})';
}

/// HTTP 401. The account must reauthenticate before another authenticated call.
final class ParticipantsReauthenticationRequired extends ParticipantsResponse {
  const ParticipantsReauthenticationRequired._({
    required ParticipantsRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'ParticipantsReauthenticationRequired()';
}

/// HTTP 403. The account is no longer allowed to see this room's participants.
final class ParticipantsForbidden extends ParticipantsResponse {
  const ParticipantsForbidden._({required ParticipantsRequest request})
    : super(request);

  @override
  int get statusCode => 403;

  @override
  String toString() => 'ParticipantsForbidden()';
}

/// HTTP 404. The room no longer exists or the account is not a participant.
final class ParticipantsRoomMissing extends ParticipantsResponse {
  const ParticipantsRoomMissing._({required ParticipantsRequest request})
    : super(request);

  @override
  int get statusCode => 404;

  @override
  String toString() => 'ParticipantsRoomMissing()';
}

enum ParticipantsHttpFailureKind { rateLimited, serviceUnavailable }

/// A supported non-body HTTP failure.
final class ParticipantsHttpFailure extends ParticipantsResponse {
  const ParticipantsHttpFailure._({
    required ParticipantsRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final ParticipantsHttpFailureKind kind;

  @override
  String toString() =>
      'ParticipantsHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

ParticipantsResponse decodeParticipantsResponse({
  required ParticipantsRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 401:
      _decodeOcsEnvelope(body);
      return ParticipantsReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return ParticipantsForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return ParticipantsRoomMissing._(request: request);
    case 429:
      return ParticipantsHttpFailure._(
        request: request,
        statusCode: 429,
        kind: ParticipantsHttpFailureKind.rateLimited,
      );
    case 503:
      return ParticipantsHttpFailure._(
        request: request,
        statusCode: 503,
        kind: ParticipantsHttpFailureKind.serviceUnavailable,
      );
    case 200:
      return _decodeSuccess(request: request, body: body);
    default:
      protocolFailure(TalkProtocolErrorCode.unsupportedHttpStatus, r'$.statusCode');
  }
}

ParticipantsSuccess _decodeSuccess({
  required ParticipantsRequest request,
  required Uint8List body,
}) {
  final data = _decodeOcsEnvelope(body);
  final itemsJson = requireList(data, path: r'$.ocs.data', code: _responseCode);
  if (itemsJson.length > participantsMaximumCount) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  final participants = <Participant>[];
  final seenAttendees = <int>{};
  for (var index = 0; index < itemsJson.length; index++) {
    final participant = parseParticipant(
      itemsJson[index],
      path: '\$.ocs.data[$index]',
    );
    if (!seenAttendees.add(participant.attendeeId)) {
      protocolFailure(_responseCode, r'$.ocs.data');
    }
    participants.add(participant);
  }
  return ParticipantsSuccess._(
    request: request,
    participants: List<Participant>.unmodifiable(participants),
  );
}

Object? _decodeOcsEnvelope(Uint8List body) {
  final decoded = _decodeJsonBytes(body);
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  final meta = requireObject(ocs['meta'], path: r'$.ocs.meta', code: _responseCode);
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
  if (bytes.isEmpty || bytes.length > participantsMaximumWireBytes) {
    protocolFailure(_responseCode, r'$');
  }
  try {
    final decoded = decodeJsonRejectingDuplicateMembers(
      utf8.decode(bytes, allowMalformed: false),
      code: _responseCode,
      path: r'$',
    );
    return JsonFreezeSession(
      maximumDepth: _participantsMaximumJsonDepth,
      maximumNodes: _participantsMaximumJsonNodes,
      errorCode: _responseCode,
      errorPath: r'$',
    ).freeze(decoded);
  } on FormatException {
    protocolFailure(_responseCode, r'$');
  }
}
