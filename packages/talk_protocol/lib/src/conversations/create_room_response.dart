import '../json_value.dart';
import '../protocol_exception.dart';
import 'create_room_request.dart';
import 'models.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidCreateConversationResponse;

/// A classified response from the create-conversation contract.
sealed class CreateConversationResponse {
  const CreateConversationResponse(this.request);

  final CreateConversationRequest request;
  int get statusCode;
}

/// HTTP 200 with OCS success and a validated newly created room.
final class CreateConversationSuccess extends CreateConversationResponse {
  CreateConversationSuccess._({
    required CreateConversationRequest request,
    required this.room,
  }) : super(request);

  @override
  int get statusCode => 200;

  final ConversationRoom room;

  @override
  String toString() => 'CreateConversationSuccess()';
}

/// HTTP 401. The account must reauthenticate before another authenticated call.
final class CreateConversationReauthenticationRequired
    extends CreateConversationResponse {
  const CreateConversationReauthenticationRequired._({
    required CreateConversationRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'CreateConversationReauthenticationRequired()';
}

/// HTTP 200 carrying an OCS-level failure instead of a created room.
final class CreateConversationOcsFailure extends CreateConversationResponse {
  const CreateConversationOcsFailure._({
    required CreateConversationRequest request,
    required this.ocsStatusCode,
  }) : super(request);

  final int ocsStatusCode;

  @override
  int get statusCode => 200;

  @override
  String toString() =>
      'CreateConversationOcsFailure(ocsStatusCode: $ocsStatusCode)';
}

enum CreateConversationHttpFailureKind { rateLimited, serviceUnavailable }

/// A supported non-body HTTP failure that must not be mistaken for success.
final class CreateConversationHttpFailure extends CreateConversationResponse {
  const CreateConversationHttpFailure._({
    required CreateConversationRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final CreateConversationHttpFailureKind kind;

  @override
  String toString() =>
      'CreateConversationHttpFailure(statusCode: $statusCode, '
      'kind: ${kind.name})';
}

CreateConversationResponse decodeCreateConversationResponse({
  required CreateConversationRequest request,
  required int statusCode,
  required Object? json,
}) {
  switch (statusCode) {
    case 401:
      _parseOcsEnvelope(json);
      return CreateConversationReauthenticationRequired._(request: request);
    case 429:
      return CreateConversationHttpFailure._(
        request: request,
        statusCode: 429,
        kind: CreateConversationHttpFailureKind.rateLimited,
      );
    case 503:
      return CreateConversationHttpFailure._(
        request: request,
        statusCode: 503,
        kind: CreateConversationHttpFailureKind.serviceUnavailable,
      );
    case 200:
      return _decodeSuccessOrOcsFailure(request: request, json: json);
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

CreateConversationResponse _decodeSuccessOrOcsFailure({
  required CreateConversationRequest request,
  required Object? json,
}) {
  final envelope = _parseOcsEnvelope(json);
  if (envelope.status != 'ok' ||
      (envelope.statusCode != 200 && envelope.statusCode != 201)) {
    return CreateConversationOcsFailure._(
      request: request,
      ocsStatusCode: envelope.statusCode,
    );
  }

  final session = JsonFreezeSession(
    errorCode: _responseCode,
    errorPath: r'$.ocs.data',
  );
  final room = parseConversationRoom(
    envelope.data,
    path: r'$.ocs.data',
    session: session,
  );
  return CreateConversationSuccess._(request: request, room: room);
}

({String status, int statusCode, Object? data}) _parseOcsEnvelope(
  Object? json,
) {
  const code = _responseCode;
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
  if (!ocs.containsKey('data')) {
    protocolFailure(code, r'$.ocs.data');
  }
  return (status: status, statusCode: ocsStatusCode, data: ocs['data']);
}
