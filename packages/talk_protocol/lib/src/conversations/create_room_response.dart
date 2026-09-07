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

/// A validated existing, created, or partially invited conversation.
final class CreateConversationSuccess extends CreateConversationResponse {
  CreateConversationSuccess._({
    required CreateConversationRequest request,
    required this.room,
    required this.statusCode,
    required this.invalidParticipants,
  }) : super(request);

  @override
  final int statusCode;

  final ConversationRoom room;
  final Map<String, List<String>> invalidParticipants;

  @override
  String toString() => 'CreateConversationSuccess()';
}

/// A definitive server refusal, distinct from a lost mutation response.
final class CreateConversationRejected extends CreateConversationResponse {
  const CreateConversationRejected._({
    required CreateConversationRequest request,
    required this.statusCode,
    required this.error,
    required this.message,
  }) : super(request);

  @override
  final int statusCode;
  final String? error;
  final String? message;

  @override
  String toString() => 'CreateConversationRejected(statusCode: $statusCode)';
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
    case 400 || 403 || 404:
      final envelope = _parseOcsEnvelope(json);
      if (envelope.status != 'failure' || envelope.statusCode != statusCode) {
        protocolFailure(_responseCode, r'$.ocs.meta');
      }
      final data = envelope.data is List && (envelope.data as List).isEmpty
          ? <String, Object?>{}
          : requireObject(
              envelope.data,
              path: r'$.ocs.data',
              code: _responseCode,
            );
      final error = data['error'];
      final message = data['message'];
      return CreateConversationRejected._(
        request: request,
        statusCode: statusCode,
        error: error == null
            ? null
            : requireString(
                error,
                path: r'$.ocs.data.error',
                code: _responseCode,
                maxLength: 128,
              ),
        message: message == null
            ? null
            : requireString(
                message,
                path: r'$.ocs.data.message',
                code: _responseCode,
                maxLength: 4096,
              ),
      );
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
    // Talk answers a created room with 201, not 200; measured against
    // Nextcloud 34.0.1, where `POST v4/room` returned 201 for both a group
    // and a public room. Accepting only 200 made every creation fail.
    case 200 || 201 || 202:
      return _decodeSuccessOrOcsFailure(
        request: request,
        statusCode: statusCode,
        json: json,
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

CreateConversationResponse _decodeSuccessOrOcsFailure({
  required CreateConversationRequest request,
  required int statusCode,
  required Object? json,
}) {
  final envelope = _parseOcsEnvelope(json);
  if (envelope.status != 'ok' ||
      !const {200, 201, 202}.contains(envelope.statusCode)) {
    return CreateConversationOcsFailure._(
      request: request,
      ocsStatusCode: envelope.statusCode,
    );
  }
  if (statusCode != 200 && statusCode != envelope.statusCode) {
    protocolFailure(_responseCode, r'$.ocs.meta');
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
  final invalid = <String, List<String>>{};
  if (envelope.statusCode == 202) {
    final data = requireObject(
      envelope.data,
      path: r'$.ocs.data',
      code: _responseCode,
    );
    final entries = requireObject(
      data['invalidParticipants'],
      path: r'$.ocs.data.invalidParticipants',
      code: _responseCode,
    );
    if (entries.length > 32) {
      protocolFailure(_responseCode, r'$.ocs.data.invalidParticipants');
    }
    var count = 0;
    for (final entry in entries.entries) {
      if (entry.key.length > 128) {
        protocolFailure(_responseCode, r'$.ocs.data.invalidParticipants');
      }
      final items = requireList(
        entry.value,
        path: r'$.ocs.data.invalidParticipants[]',
        code: _responseCode,
      );
      count += items.length;
      if (count > 5000) {
        protocolFailure(_responseCode, r'$.ocs.data.invalidParticipants');
      }
      invalid[entry.key] = List.unmodifiable(
        items.map(
          (item) => requireString(
            item,
            path: r'$.ocs.data.invalidParticipants[][]',
            code: _responseCode,
            maxLength: 1024,
          ),
        ),
      );
    }
    if (count == 0) {
      protocolFailure(_responseCode, r'$.ocs.data.invalidParticipants');
    }
  }
  return CreateConversationSuccess._(
    request: request,
    room: room,
    statusCode: statusCode,
    invalidParticipants: Map.unmodifiable(invalid),
  );
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
