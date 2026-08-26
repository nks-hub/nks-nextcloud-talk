import 'dart:convert';
import 'dart:typed_data';

import '../conversations/models.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import 'request.dart';

part 'response_updates.dart';
part 'response_administration.dart';
part 'response_call_notifications.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidRoomSettingsResponse;
const int roomSettingsMaximumWireBytes = 4 * 1024 * 1024;
const int _roomSettingsMaximumJsonDepth = 24;
const int _roomSettingsMaximumJsonNodes = 60000;

enum RoomSettingsHttpFailureKind { rateLimited, serviceUnavailable }

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
