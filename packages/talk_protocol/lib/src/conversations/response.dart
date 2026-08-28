import '../json_value.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';

const int conversationMaximumRooms = 100000;
const int _conversationMaximumJsonDepth = 64;
const int _conversationMaximumJsonNodes = 250000;

/// Validated conversation-list response headers.
///
/// A cursor-v4 server sends both the cursor and the configuration hash. Legacy
/// `conversation-v4` servers answer full snapshots without `modifiedSince`
/// support and may omit either header, which is why both are nullable.
/// [requireCursorProfile] restores the strict contract for requests that depend
/// on it. Malformed values stay rejected in both cases.
final class ConversationResponseHeaders {
  ConversationResponseHeaders._({
    required this.configurationHash,
    required this.cursor,
    required this.federationInvites,
  });

  factory ConversationResponseHeaders.parse(
    Map<String, String> headers, {
    bool requireCursorProfile = true,
  }) {
    const relevantNames = <String>{
      'x-nextcloud-talk-hash',
      'x-nextcloud-talk-modified-before',
      'x-nextcloud-talk-federation-invites',
    };
    final normalized = <String, String>{};
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (!relevantNames.contains(name)) {
        continue;
      }
      if (normalized.containsKey(name)) {
        protocolFailure(
          TalkProtocolErrorCode.invalidConversationHeaders,
          r'$.headers[<duplicate>]',
        );
      }
      normalized[name] = entry.value;
    }

    final rawHash = normalized['x-nextcloud-talk-hash'];
    if (rawHash == null && requireCursorProfile) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationHeaders,
        r'$.headers.xNextcloudTalkHash',
      );
    }
    final rawCursor = normalized['x-nextcloud-talk-modified-before'];
    if (rawCursor == null && requireCursorProfile) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationHeaders,
        r'$.headers.xNextcloudTalkModifiedBefore',
      );
    }

    final rawFederationInvites =
        normalized['x-nextcloud-talk-federation-invites'];
    return ConversationResponseHeaders._(
      configurationHash: rawHash == null
          ? null
          : ConversationConfigurationHash.parse(
              rawHash,
              path: r'$.headers.xNextcloudTalkHash',
            ),
      cursor: rawCursor == null
          ? null
          : ConversationCursor.parse(
              rawCursor,
              path: r'$.headers.xNextcloudTalkModifiedBefore',
              code: TalkProtocolErrorCode.invalidConversationHeaders,
            ),
      federationInvites: rawFederationInvites == null
          ? null
          : ConversationCursor.parse(
              rawFederationInvites,
              path: r'$.headers.xNextcloudTalkFederationInvites',
              code: TalkProtocolErrorCode.invalidConversationHeaders,
            ),
    );
  }

  final ConversationConfigurationHash? configurationHash;
  final ConversationCursor? cursor;
  final ConversationCursor? federationInvites;

  @override
  String toString() => 'ConversationResponseHeaders(<redacted>)';
}

/// A classified response from the conversation-list endpoint.
sealed class ConversationListResponse {
  const ConversationListResponse(this.request);

  final ConversationListRequest request;
  int get statusCode;
}

/// HTTP 200 with OCS success, validated rooms and cursor-v4 headers.
final class ConversationListSuccess extends ConversationListResponse {
  ConversationListSuccess._({
    required ConversationListRequest request,
    required this.rooms,
    required this.responseHeaders,
  }) : super(request);

  @override
  int get statusCode => 200;

  final List<ConversationRoom> rooms;
  final ConversationResponseHeaders responseHeaders;

  /// `null` for a legacy snapshot server; the next fetch must stay full.
  ConversationCursor? get cursor => responseHeaders.cursor;

  ConversationConfigurationHash? get configurationHash =>
      responseHeaders.configurationHash;

  ConversationCursor? get federationInvites =>
      responseHeaders.federationInvites;

  @override
  String toString() => 'ConversationListSuccess(roomCount: ${rooms.length})';
}

/// HTTP 401. The account must reauthenticate before another authenticated call.
final class ConversationReauthenticationRequired
    extends ConversationListResponse {
  const ConversationReauthenticationRequired._({
    required ConversationListRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'ConversationReauthenticationRequired()';
}

/// HTTP 200 carrying an OCS-level failure instead of conversation data.
final class ConversationOcsFailure extends ConversationListResponse {
  const ConversationOcsFailure._({
    required ConversationListRequest request,
    required this.ocsStatusCode,
  }) : super(request);

  final int ocsStatusCode;

  @override
  int get statusCode => 200;

  @override
  String toString() => 'ConversationOcsFailure(ocsStatusCode: $ocsStatusCode)';
}

enum ConversationHttpFailureKind {
  upgradeRequired,
  rateLimited,
  serviceUnavailable,
}

/// A supported non-body HTTP failure that must not enter merge planning.
final class ConversationHttpFailure extends ConversationListResponse {
  const ConversationHttpFailure._({
    required ConversationListRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final ConversationHttpFailureKind kind;

  @override
  String toString() =>
      'ConversationHttpFailure(statusCode: $statusCode, kind: ${kind.name})';
}

ConversationListResponse decodeConversationListResponse({
  required ConversationListRequest request,
  required int statusCode,
  required Object? json,
  Map<String, String> headers = const <String, String>{},
}) {
  switch (statusCode) {
    case 401:
      _validateOcsErrorEnvelope(json);
      return ConversationReauthenticationRequired._(request: request);
    case 426:
      return ConversationHttpFailure._(
        request: request,
        statusCode: 426,
        kind: ConversationHttpFailureKind.upgradeRequired,
      );
    case 429:
      return ConversationHttpFailure._(
        request: request,
        statusCode: 429,
        kind: ConversationHttpFailureKind.rateLimited,
      );
    case 503:
      return ConversationHttpFailure._(
        request: request,
        statusCode: 503,
        kind: ConversationHttpFailureKind.serviceUnavailable,
      );
    case 200:
      return _decodeSuccessOrOcsFailure(
        request: request,
        json: json,
        headers: headers,
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

ConversationListResponse _decodeSuccessOrOcsFailure({
  required ConversationListRequest request,
  required Object? json,
  required Map<String, String> headers,
}) {
  final envelope = _parseOcsEnvelope(json);
  final roomsJson = requireList(
    envelope.data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidConversationResponse,
  );
  if (roomsJson.length > conversationMaximumRooms) {
    protocolFailure(
      TalkProtocolErrorCode.invalidConversationResponse,
      r'$.ocs.data',
    );
  }
  if (envelope.status != 'ok' || envelope.statusCode != 200) {
    return ConversationOcsFailure._(
      request: request,
      ocsStatusCode: envelope.statusCode,
    );
  }

  // Only an incremental fetch depends on the cursor profile. A full fetch
  // accepts a legacy conversation-v4 snapshot without cursor and hash.
  final responseHeaders = ConversationResponseHeaders.parse(
    headers,
    requireCursorProfile: request.mode == ConversationFetchMode.incremental,
  );
  final session = JsonFreezeSession(
    maximumDepth: _conversationMaximumJsonDepth,
    maximumNodes: _conversationMaximumJsonNodes,
    errorCode: TalkProtocolErrorCode.invalidConversationResponse,
    errorPath: r'$.ocs.data',
  );
  final rooms = <ConversationRoom>[];
  final tokens = <ConversationToken>{};
  for (var index = 0; index < roomsJson.length; index++) {
    final room = parseConversationRoom(
      roomsJson[index],
      path: '\$.ocs.data[$index]',
      session: session,
    );
    if (!tokens.add(room.token)) {
      protocolFailure(
        TalkProtocolErrorCode.duplicateConversationToken,
        r'$.ocs.data',
      );
    }
    rooms.add(room);
  }
  return ConversationListSuccess._(
    request: request,
    rooms: List<ConversationRoom>.unmodifiable(rooms),
    responseHeaders: responseHeaders,
  );
}

void _validateOcsErrorEnvelope(Object? json) {
  final session = JsonFreezeSession(
    maximumDepth: _conversationMaximumJsonDepth,
    maximumNodes: _conversationMaximumJsonNodes,
    errorCode: TalkProtocolErrorCode.invalidConversationResponse,
    errorPath: r'$.ocs',
  );
  final frozen = session.freeze(json);
  _parseOcsEnvelope(frozen);
}

({String status, int statusCode, Object? data}) _parseOcsEnvelope(
  Object? json,
) {
  const code = TalkProtocolErrorCode.invalidConversationResponse;
  final root = requireObject(json, path: r'$', code: code);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: code);
  final meta = requireObject(ocs['meta'], path: r'$.ocs.meta', code: code);
  final status = requireString(
    meta['status'],
    path: r'$.ocs.meta.status',
    code: code,
  );
  if (status != 'ok' && status != 'failure') {
    protocolFailure(code, r'$.ocs.meta.status');
  }
  final ocsStatusCode = requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: code,
    minimum: 0,
    maximum: 999,
  );
  if (meta.containsKey('message')) {
    requireString(
      meta['message'],
      path: r'$.ocs.meta.message',
      code: code,
      maxLength: 4096,
    );
  }
  if (!ocs.containsKey('data')) {
    protocolFailure(code, r'$.ocs.data');
  }
  final data = ocs['data'];
  return (status: status, statusCode: ocsStatusCode, data: data);
}
