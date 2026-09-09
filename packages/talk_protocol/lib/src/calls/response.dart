import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';

enum CallResponseClassification {
  confirmed,
  rejected,
  reauthenticationRequired,
  forbidden,
  sessionMissing,
  conflict,
  rateLimited,
  serverFailure,
}

final class CallRestResponse {
  const CallRestResponse._({
    required this.request,
    required this.statusCode,
    required this.classification,
    required this.peers,
    required this.errorCode,
  });

  final CallRestRequest request;
  final int statusCode;
  final CallResponseClassification classification;
  final List<CallPeer> peers;

  /// Bounded machine-readable Talk error, never included in [toString].
  final String? errorCode;

  bool get ownSessionPresent => peers.any(
    (peer) =>
        peer.sessionId == request.authority.nextcloudSessionId &&
        peer.roomToken == request.authority.roomToken,
  );

  @override
  String toString() =>
      'CallRestResponse(statusCode: $statusCode, '
      'classification: ${classification.name}, peers: ${peers.length}, '
      'sensitive: <redacted>)';
}

CallRestResponse decodeCallRestResponse({
  required CallRestRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  if (statusCode == 200) {
    final data = _decodeOcsData(body);
    final peers = request is CallPeersRequest
        ? _decodePeers(request, data)
        : const <CallPeer>[];
    return CallRestResponse._(
      request: request,
      statusCode: statusCode,
      classification: CallResponseClassification.confirmed,
      peers: peers,
      errorCode: null,
    );
  }

  final classification = switch (statusCode) {
    400 => CallResponseClassification.rejected,
    401 => CallResponseClassification.reauthenticationRequired,
    403 => CallResponseClassification.forbidden,
    404 => CallResponseClassification.sessionMissing,
    409 => CallResponseClassification.conflict,
    429 => CallResponseClassification.rateLimited,
    >= 500 && <= 599 => CallResponseClassification.serverFailure,
    _ => protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    ),
  };
  return CallRestResponse._(
    request: request,
    statusCode: statusCode,
    classification: classification,
    peers: const <CallPeer>[],
    errorCode: statusCode == 400 ? _optionalErrorCode(body) : null,
  );
}

Object? _decodeOcsData(Uint8List body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } on Object {
    protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.body');
  }
  final root = requireObject(
    decoded,
    path: r'$',
    code: TalkProtocolErrorCode.invalidCallResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidCallResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidCallResponse,
  );
  if (requireString(
        meta['status'],
        path: r'$.ocs.meta.status',
        code: TalkProtocolErrorCode.invalidCallResponse,
      ) !=
      'ok') {
    protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.ocs.meta');
  }
  if (requireInt(
        meta['statuscode'],
        path: r'$.ocs.meta.statuscode',
        code: TalkProtocolErrorCode.invalidCallResponse,
      ) !=
      200) {
    protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.ocs.meta');
  }
  requireString(
    meta['message'],
    path: r'$.ocs.meta.message',
    code: TalkProtocolErrorCode.invalidCallResponse,
    maxLength: 4096,
  );
  return ocs['data'];
}

List<CallPeer> _decodePeers(CallPeersRequest request, Object? data) {
  final rawPeers = requireList(
    data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidCallResponse,
  );
  if (rawPeers.length > 512) {
    protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.ocs.data');
  }
  final peers = <CallPeer>[];
  final sessions = <String>{};
  for (var index = 0; index < rawPeers.length; index++) {
    final peer = CallPeer.fromJson(rawPeers[index], index: index);
    if (peer.roomToken != request.roomToken ||
        !sessions.add(peer.sessionId.value)) {
      protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.ocs.data');
    }
    peers.add(peer);
  }
  return UnmodifiableListView(peers);
}

enum CallRecordingResponseClassification {
  confirmed,
  rejected,
  reauthenticationRequired,
  forbidden,
  roomMissing,
  preconditionFailed,
  rateLimited,
  serverFailure,
}

final class CallRecordingResponse {
  const CallRecordingResponse._({
    required this.request,
    required this.statusCode,
    required this.classification,
    required this.errorCode,
  });

  final CallRecordingRequest request;
  final int statusCode;
  final CallRecordingResponseClassification classification;

  /// The `message` Talk's `400` carries (`status`, `config`, `recording` or
  /// `call`, per `docs/recording.md`); never included in [toString].
  final String? errorCode;

  bool get isSuccess =>
      classification == CallRecordingResponseClassification.confirmed;

  @override
  String toString() =>
      'CallRecordingResponse(statusCode: $statusCode, '
      'classification: ${classification.name})';
}

CallRecordingResponse decodeCallRecordingResponse({
  required CallRecordingRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  if (statusCode == 200) {
    _decodeOcsData(body);
    return CallRecordingResponse._(
      request: request,
      statusCode: statusCode,
      classification: CallRecordingResponseClassification.confirmed,
      errorCode: null,
    );
  }

  final classification = switch (statusCode) {
    400 => CallRecordingResponseClassification.rejected,
    401 => CallRecordingResponseClassification.reauthenticationRequired,
    403 => CallRecordingResponseClassification.forbidden,
    404 => CallRecordingResponseClassification.roomMissing,
    412 => CallRecordingResponseClassification.preconditionFailed,
    429 => CallRecordingResponseClassification.rateLimited,
    >= 500 && <= 599 => CallRecordingResponseClassification.serverFailure,
    _ => protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    ),
  };
  return CallRecordingResponse._(
    request: request,
    statusCode: statusCode,
    classification: classification,
    errorCode: statusCode == 400 ? _optionalErrorCode(body) : null,
  );
}

String? _optionalErrorCode(Uint8List body) {
  if (body.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(body));
    final root = requireObject(
      decoded,
      path: r'$',
      code: TalkProtocolErrorCode.invalidCallResponse,
    );
    final ocs = requireObject(
      root['ocs'],
      path: r'$.ocs',
      code: TalkProtocolErrorCode.invalidCallResponse,
    );
    final meta = requireObject(
      ocs['meta'],
      path: r'$.ocs.meta',
      code: TalkProtocolErrorCode.invalidCallResponse,
    );
    if (requireString(
          meta['status'],
          path: r'$.ocs.meta.status',
          code: TalkProtocolErrorCode.invalidCallResponse,
        ) !=
        'failure') {
      return null;
    }
    requireInt(
      meta['statuscode'],
      path: r'$.ocs.meta.statuscode',
      code: TalkProtocolErrorCode.invalidCallResponse,
      minimum: 400,
      maximum: 499,
    );
    final data = ocs['data'];
    if (data is! Map<String, Object?> || data['error'] == null) {
      return null;
    }
    return requireString(
      data['error'],
      path: r'$.ocs.data.error',
      code: TalkProtocolErrorCode.invalidCallResponse,
      minLength: 1,
      maxLength: 128,
    );
  } on FormatException {
    return null;
  } on TalkProtocolException {
    return null;
  }
}

/// The largest attendance document this client will read. The server writes
/// one row per attendee of the running call, so a megabyte is far past any
/// real meeting and still small enough to hold in memory.
const int maximumCallAttendanceBytes = 1024 * 1024;

/// The header Talk writes for `call/{token}/download?format=csv`. A `200`
/// whose first line is anything else is not an attendance document — the
/// reference server has been observed answering `200 text/html` with an error
/// page for other endpoints, and such a body must not be offered as a export.
const String callAttendanceCsvHeader = 'name,email,type,identifier';

enum CallAttendanceClassification {
  confirmed,

  /// No call is running in this room. Talk answers `400` both before a call
  /// starts and again once it ends; there is no historical attendance.
  noCallRunning,
  reauthenticationRequired,
  forbidden,
  roomMissing,
  rateLimited,
  serverFailure,
}

/// Who the server recorded in the call that is running now.
///
/// [csv] is the server's document with spreadsheet formulas neutralised — see
/// [neutraliseCallAttendanceCsv]. Names are attendee data and are never part
/// of [toString].
final class CallAttendanceDownload {
  const CallAttendanceDownload._({
    required this.request,
    required this.statusCode,
    required this.classification,
    required this.csv,
  });

  final CallAttendanceDownloadRequest request;
  final int statusCode;
  final CallAttendanceClassification classification;
  final String? csv;

  bool get isSuccess =>
      classification == CallAttendanceClassification.confirmed;

  @override
  String toString() =>
      'CallAttendanceDownload(statusCode: $statusCode, '
      'classification: ${classification.name}, sensitive: <redacted>)';
}

CallAttendanceDownload decodeCallAttendanceDownload({
  required CallAttendanceDownloadRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  if (statusCode == 200) {
    if (body.length > maximumCallAttendanceBytes) {
      protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.body');
    }
    final String text;
    try {
      text = utf8.decode(body);
    } on FormatException {
      return protocolFailure(
        TalkProtocolErrorCode.invalidCallResponse,
        r'$.body',
      );
    }
    final firstBreak = text.indexOf('\n');
    final header = (firstBreak < 0 ? text : text.substring(0, firstBreak))
        .trimRight();
    if (header != callAttendanceCsvHeader) {
      protocolFailure(TalkProtocolErrorCode.invalidCallResponse, r'$.body');
    }
    return CallAttendanceDownload._(
      request: request,
      statusCode: statusCode,
      classification: CallAttendanceClassification.confirmed,
      csv: neutraliseCallAttendanceCsv(text),
    );
  }

  final classification = switch (statusCode) {
    400 => CallAttendanceClassification.noCallRunning,
    401 => CallAttendanceClassification.reauthenticationRequired,
    403 => CallAttendanceClassification.forbidden,
    404 => CallAttendanceClassification.roomMissing,
    429 => CallAttendanceClassification.rateLimited,
    >= 500 && <= 599 => CallAttendanceClassification.serverFailure,
    _ => protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    ),
  };
  return CallAttendanceDownload._(
    request: request,
    statusCode: statusCode,
    classification: classification,
    csv: null,
  );
}

/// Rewrites [csv] so no cell is read as a formula when the file is opened in
/// a spreadsheet.
///
/// A display name is attendee-controlled text. `=cmd|...`, `+`, `-` and `@`
/// at the start of a cell make Excel and LibreOffice evaluate it, so each such
/// cell is prefixed with an apostrophe, which those programs read as "this is
/// text". The prefix is visible in the exported file: an altered cell is the
/// price of not shipping an executable one.
String neutraliseCallAttendanceCsv(String csv) {
  final rows = _parseCsvRows(csv);
  return rows.map((row) => row.map(_neutraliseCell).join(',')).join('\r\n');
}

const Set<String> _formulaLeaders = {'=', '+', '-', '@', '\t', '\r'};

String _neutraliseCell(String cell) {
  final value = cell.isNotEmpty && _formulaLeaders.contains(cell[0])
      ? "'$cell"
      : cell;
  if (value.isEmpty) {
    return value;
  }
  final needsQuotes =
      value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r') ||
      value != value.trim();
  if (!needsQuotes) {
    return value;
  }
  return '"${value.replaceAll('"', '""')}"';
}

/// Minimal RFC 4180 reader: quoted cells may hold commas, line breaks and
/// doubled quotes. Enough for the document Talk writes, and it has to be a
/// reader rather than a search-and-replace because a cell's first character
/// is only knowable once the quoting is resolved.
List<List<String>> _parseCsvRows(String csv) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  var index = 0;
  while (index < csv.length) {
    final character = csv[index];
    if (quoted) {
      if (character == '"') {
        if (index + 1 < csv.length && csv[index + 1] == '"') {
          cell.write('"');
          index += 2;
          continue;
        }
        quoted = false;
        index++;
        continue;
      }
      cell.write(character);
      index++;
      continue;
    }
    switch (character) {
      case '"':
        quoted = true;
        index++;
      case ',':
        row.add(cell.toString());
        cell.clear();
        index++;
      case '\r':
      case '\n':
        row.add(cell.toString());
        cell.clear();
        rows.add(row);
        row = <String>[];
        index +=
            character == '\r' &&
                index + 1 < csv.length &&
                csv[index + 1] == '\n'
            ? 2
            : 1;
      default:
        cell.write(character);
        index++;
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}
