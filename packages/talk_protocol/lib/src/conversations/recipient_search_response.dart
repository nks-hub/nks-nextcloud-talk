import '../json_value.dart';
import '../protocol_exception.dart';
import 'recipient_search_request.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidRecipientSearchResponse;
const int _recipientSearchMaximumResults = 200;

/// A single user or group returned by the recipient-search contract.
final class ConversationRecipient {
  ConversationRecipient._({
    required this.id,
    required this.label,
    required this.shareType,
    required this.subline,
    required this.wire,
  });

  final String id;
  final String label;
  final RecipientShareType shareType;
  final String? subline;
  final Map<String, Object?> wire;

  @override
  String toString() => 'ConversationRecipient(<redacted>)';
}

/// A classified response from the recipient-search contract.
sealed class RecipientSearchResponse {
  const RecipientSearchResponse(this.request);

  final RecipientSearchRequest request;
  int get statusCode;
}

/// HTTP 200 with OCS success and validated recipients.
final class RecipientSearchSuccess extends RecipientSearchResponse {
  RecipientSearchSuccess._({
    required RecipientSearchRequest request,
    required this.recipients,
  }) : super(request);

  @override
  int get statusCode => 200;

  final List<ConversationRecipient> recipients;

  @override
  String toString() =>
      'RecipientSearchSuccess(recipientCount: ${recipients.length})';
}

/// HTTP 401. The account must reauthenticate before another authenticated call.
final class RecipientSearchReauthenticationRequired
    extends RecipientSearchResponse {
  const RecipientSearchReauthenticationRequired._({
    required RecipientSearchRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;

  @override
  String toString() => 'RecipientSearchReauthenticationRequired()';
}

/// HTTP 200 carrying an OCS-level failure instead of recipient data.
final class RecipientSearchOcsFailure extends RecipientSearchResponse {
  const RecipientSearchOcsFailure._({
    required RecipientSearchRequest request,
    required this.ocsStatusCode,
  }) : super(request);

  final int ocsStatusCode;

  @override
  int get statusCode => 200;

  @override
  String toString() =>
      'RecipientSearchOcsFailure(ocsStatusCode: $ocsStatusCode)';
}

RecipientSearchResponse decodeRecipientSearchResponse({
  required RecipientSearchRequest request,
  required int statusCode,
  required Object? json,
}) {
  switch (statusCode) {
    case 401:
      _parseOcsEnvelope(json);
      return RecipientSearchReauthenticationRequired._(request: request);
    case 200:
      return _decodeSuccessOrOcsFailure(request: request, json: json);
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

RecipientSearchResponse _decodeSuccessOrOcsFailure({
  required RecipientSearchRequest request,
  required Object? json,
}) {
  final envelope = _parseOcsEnvelope(json);
  final itemsJson = requireList(
    envelope.data,
    path: r'$.ocs.data',
    code: _responseCode,
  );
  if (itemsJson.length > _recipientSearchMaximumResults) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  if (envelope.status != 'ok' || envelope.statusCode != 200) {
    return RecipientSearchOcsFailure._(
      request: request,
      ocsStatusCode: envelope.statusCode,
    );
  }

  final session = JsonFreezeSession(
    errorCode: _responseCode,
    errorPath: r'$.ocs.data',
  );
  final recipients = <ConversationRecipient>[];
  final seenRecipients = <String>{};
  for (var index = 0; index < itemsJson.length; index++) {
    final path = '\$.ocs.data[$index]';
    final frozen = session.freeze(itemsJson[index]);
    final item = requireObject(frozen, path: path, code: _responseCode);
    final id = requireString(
      item['id'],
      path: '$path.id',
      code: _responseCode,
      minLength: 1,
      maxLength: 256,
    );
    final label = requireString(
      item['label'],
      path: '$path.label',
      code: _responseCode,
      minLength: 1,
      maxLength: 512,
    );
    final rawSource = requireString(
      item['source'],
      path: '$path.source',
      code: _responseCode,
    );
    final RecipientShareType shareType;
    if (rawSource == 'users') {
      shareType = RecipientShareType.user;
    } else if (rawSource == 'groups') {
      shareType = RecipientShareType.group;
    } else {
      protocolFailure(_responseCode, '$path.source');
    }
    String? subline;
    if (item.containsKey('subline') && item['subline'] != null) {
      subline = requireString(
        item['subline'],
        path: '$path.subline',
        code: _responseCode,
        maxLength: 1024,
      );
    }
    if (!seenRecipients.add('${shareType.name}:$id')) {
      protocolFailure(_responseCode, path);
    }
    recipients.add(
      ConversationRecipient._(
        id: id,
        label: label,
        shareType: shareType,
        subline: subline,
        wire: item,
      ),
    );
  }
  return RecipientSearchSuccess._(
    request: request,
    recipients: List<ConversationRecipient>.unmodifiable(recipients),
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
