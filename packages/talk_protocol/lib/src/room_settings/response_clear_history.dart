part of 'response.dart';

sealed class ClearRoomHistoryResponse {
  const ClearRoomHistoryResponse(this.request);

  final ClearRoomHistoryRequest request;
  int get statusCode;
}

/// HTTP 200 or 202. Both mean the server history was cleared.
final class ClearRoomHistorySuccess extends ClearRoomHistoryResponse {
  const ClearRoomHistorySuccess._({
    required ClearRoomHistoryRequest request,
    required this.statusCode,
    required this.systemMessage,
    required this.lastCommonRead,
  }) : super(request);

  @override
  final int statusCode;

  /// The new authoritative `history_cleared` system message.
  final ChatMessage systemMessage;

  /// Present only when the caller exposes public read status.
  final ChatCursor? lastCommonRead;

  /// A 202 means Matterbridge or federation can retain an external copy.
  bool get externalCopiesMayRemain => statusCode == 202;

  @override
  String toString() =>
      'ClearRoomHistorySuccess(externalCopiesMayRemain: '
      '$externalCopiesMayRemain)';
}

final class ClearRoomHistoryReauthenticationRequired
    extends ClearRoomHistoryResponse {
  const ClearRoomHistoryReauthenticationRequired._({
    required ClearRoomHistoryRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

/// HTTP 403. This covers a non-moderator, a preserved room, a read-only room,
/// and one-to-one history deletion disabled by server configuration.
final class ClearRoomHistoryForbidden extends ClearRoomHistoryResponse {
  const ClearRoomHistoryForbidden._({required ClearRoomHistoryRequest request})
    : super(request);

  @override
  int get statusCode => 403;
}

final class ClearRoomHistoryRoomMissing extends ClearRoomHistoryResponse {
  const ClearRoomHistoryRoomMissing._({
    required ClearRoomHistoryRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;
}

final class ClearRoomHistoryHttpFailure extends ClearRoomHistoryResponse {
  const ClearRoomHistoryHttpFailure._({
    required ClearRoomHistoryRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;
}

ClearRoomHistoryResponse decodeClearRoomHistoryResponse({
  required ClearRoomHistoryRequest request,
  required int statusCode,
  required Uint8List body,
  ChatResponseHeaders? headers,
}) {
  switch (statusCode) {
    case 200:
    case 202:
      final data = _decodeClearHistoryEnvelope(
        body,
        statusCode: statusCode,
        expectedStatus: 'ok',
      );
      final message = ChatMessage.fromJson(data);
      if (message.roomToken != request.roomToken ||
          message.systemMessage != 'history_cleared' ||
          message.threadId != null ||
          message.isThread == true) {
        protocolFailure(_responseCode, r'$.ocs.data');
      }
      final commonRead = (headers ?? ChatResponseHeaders.fromMap(const {}))
          .cursor('X-Chat-Last-Common-Read');
      return ClearRoomHistorySuccess._(
        request: request,
        statusCode: statusCode,
        systemMessage: message,
        lastCommonRead: commonRead,
      );
    case 401:
      _decodeClearHistoryEnvelope(
        body,
        statusCode: 401,
        expectedStatus: 'failure',
      );
      return ClearRoomHistoryReauthenticationRequired._(request: request);
    case 403:
      _decodeClearHistoryEnvelope(
        body,
        statusCode: 403,
        expectedStatus: 'failure',
      );
      return ClearRoomHistoryForbidden._(request: request);
    case 404:
      _decodeClearHistoryEnvelope(
        body,
        statusCode: 404,
        expectedStatus: 'failure',
      );
      return ClearRoomHistoryRoomMissing._(request: request);
    case 429:
      return ClearRoomHistoryHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return ClearRoomHistoryHttpFailure._(
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

Object? _decodeClearHistoryEnvelope(
  Uint8List body, {
  required int statusCode,
  required String expectedStatus,
}) {
  final root = requireObject(
    _decodeJsonBytes(body),
    path: r'$',
    code: _responseCode,
  );
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: _responseCode,
  );
  final wireStatus = requireString(
    meta['status'],
    path: r'$.ocs.meta.status',
    code: _responseCode,
    minLength: 1,
    maxLength: 32,
  );
  final wireStatusCode = requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: _responseCode,
    minimum: 0,
    maximum: 999,
  );
  if (wireStatus != expectedStatus || wireStatusCode != statusCode) {
    protocolFailure(_responseCode, r'$.ocs.meta');
  }
  if (!ocs.containsKey('data')) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  return ocs['data'];
}
