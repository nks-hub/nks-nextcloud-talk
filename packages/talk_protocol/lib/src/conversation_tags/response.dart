import 'dart:convert';
import 'dart:typed_data';

import '../conversations/models.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidRoomSettingsResponse;
const int conversationTagsMaximumWireBytes = 2 * 1024 * 1024;

enum ConversationTagsHttpFailureKind { rateLimited, serviceUnavailable }

sealed class FetchConversationTagsResponse {
  const FetchConversationTagsResponse(this.request);

  final FetchConversationTagsRequest request;
  int get statusCode;
}

final class FetchConversationTagsSuccess extends FetchConversationTagsResponse {
  const FetchConversationTagsSuccess._({
    required FetchConversationTagsRequest request,
    required this.definitions,
  }) : super(request);

  final List<ConversationTagDefinition> definitions;

  @override
  int get statusCode => 200;
}

final class FetchConversationTagsReauthenticationRequired
    extends FetchConversationTagsResponse {
  const FetchConversationTagsReauthenticationRequired._({
    required FetchConversationTagsRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

final class FetchConversationTagsHttpFailure
    extends FetchConversationTagsResponse {
  const FetchConversationTagsHttpFailure._({
    required FetchConversationTagsRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final ConversationTagsHttpFailureKind kind;
}

FetchConversationTagsResponse decodeFetchConversationTagsResponse({
  required FetchConversationTagsRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  return switch (statusCode) {
    200 => FetchConversationTagsSuccess._(
      request: request,
      definitions: parseConversationTagDefinitions(
        _decodeEnvelope(body, expectedStatusCode: 200, requireSuccess: true),
      ),
    ),
    401 => _fetchReauthentication(request, body),
    429 => FetchConversationTagsHttpFailure._(
      request: request,
      statusCode: statusCode,
      kind: ConversationTagsHttpFailureKind.rateLimited,
    ),
    503 => FetchConversationTagsHttpFailure._(
      request: request,
      statusCode: statusCode,
      kind: ConversationTagsHttpFailureKind.serviceUnavailable,
    ),
    _ => _unsupportedStatus(),
  };
}

sealed class AssignConversationTagsResponse {
  const AssignConversationTagsResponse(this.request);

  final AssignConversationTagsRequest request;
  int get statusCode;
}

final class AssignConversationTagsSuccess
    extends AssignConversationTagsResponse {
  const AssignConversationTagsSuccess._({
    required AssignConversationTagsRequest request,
    required this.room,
  }) : super(request);

  final ConversationRoom room;

  @override
  int get statusCode => 200;
}

final class AssignConversationTagsReauthenticationRequired
    extends AssignConversationTagsResponse {
  const AssignConversationTagsReauthenticationRequired._({
    required AssignConversationTagsRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

final class AssignConversationTagsForbidden
    extends AssignConversationTagsResponse {
  const AssignConversationTagsForbidden._({
    required AssignConversationTagsRequest request,
  }) : super(request);

  @override
  int get statusCode => 403;
}

final class AssignConversationTagsRoomMissing
    extends AssignConversationTagsResponse {
  const AssignConversationTagsRoomMissing._({
    required AssignConversationTagsRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;
}

final class AssignConversationTagsHttpFailure
    extends AssignConversationTagsResponse {
  const AssignConversationTagsHttpFailure._({
    required AssignConversationTagsRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final ConversationTagsHttpFailureKind kind;
}

AssignConversationTagsResponse decodeAssignConversationTagsResponse({
  required AssignConversationTagsRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      final data = _decodeEnvelope(
        body,
        expectedStatusCode: 200,
        requireSuccess: true,
      );
      final session = JsonFreezeSession(
        errorCode: _responseCode,
        errorPath: r'$.ocs.data',
      );
      final room = parseConversationRoom(
        data,
        path: r'$.ocs.data',
        session: session,
      );
      if (room.token != request.roomToken ||
          room.tagIds.any((id) => !request.tagIds.contains(id))) {
        protocolFailure(_responseCode, r'$.ocs.data.tagIds');
      }
      return AssignConversationTagsSuccess._(request: request, room: room);
    case 401:
      _decodeEnvelope(body, expectedStatusCode: 401, requireSuccess: false);
      return AssignConversationTagsReauthenticationRequired._(request: request);
    case 403:
      _decodeEnvelope(body, expectedStatusCode: 403, requireSuccess: false);
      return AssignConversationTagsForbidden._(request: request);
    case 404:
      _decodeEnvelope(body, expectedStatusCode: 404, requireSuccess: false);
      return AssignConversationTagsRoomMissing._(request: request);
    case 429:
      return AssignConversationTagsHttpFailure._(
        request: request,
        statusCode: statusCode,
        kind: ConversationTagsHttpFailureKind.rateLimited,
      );
    case 503:
      return AssignConversationTagsHttpFailure._(
        request: request,
        statusCode: statusCode,
        kind: ConversationTagsHttpFailureKind.serviceUnavailable,
      );
    default:
      return _unsupportedStatus();
  }
}

FetchConversationTagsResponse _fetchReauthentication(
  FetchConversationTagsRequest request,
  Uint8List body,
) {
  _decodeEnvelope(body, expectedStatusCode: 401, requireSuccess: false);
  return FetchConversationTagsReauthenticationRequired._(request: request);
}

Object? _decodeEnvelope(
  Uint8List body, {
  required int expectedStatusCode,
  required bool requireSuccess,
}) {
  if (body.isEmpty || body.length > conversationTagsMaximumWireBytes) {
    protocolFailure(_responseCode, r'$.body');
  }
  final String source;
  try {
    source = const Utf8Decoder(allowMalformed: false).convert(body);
  } on FormatException {
    protocolFailure(_responseCode, r'$.body');
  }
  final decoded =
      JsonFreezeSession(
        maximumDepth: 24,
        maximumNodes: 20000,
        errorCode: _responseCode,
        errorPath: r'$',
      ).freeze(
        decodeJsonRejectingDuplicateMembers(
          source,
          code: _responseCode,
          path: r'$',
        ),
      );
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
  if ((requireSuccess && status != 'ok') ||
      (!requireSuccess && status != 'failure')) {
    protocolFailure(_responseCode, r'$.ocs.meta.status');
  }
  final statusCode = requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: _responseCode,
    minimum: 0,
    maximum: 999,
  );
  if (statusCode != expectedStatusCode || !ocs.containsKey('data')) {
    protocolFailure(_responseCode, r'$.ocs.meta.statuscode');
  }
  return ocs['data'];
}

Never _unsupportedStatus() => protocolFailure(
  TalkProtocolErrorCode.unsupportedHttpStatus,
  r'$.statusCode',
);
