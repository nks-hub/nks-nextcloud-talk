import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';

/// Hard client-side cap on decoded results, independent of the OCS payload.
const int messageSearchMaximumResults = 200;

const int _searchMaximumJsonDepth = 32;
const int _searchMaximumJsonNodes = 20000;

enum MessageSearchClassification {
  /// HTTP 200, OCS success, at least one result.
  results,

  /// HTTP 200, OCS success, zero results.
  empty,

  /// HTTP 401. The account must reauthenticate before searching again.
  reauthenticationRequired,

  /// HTTP 404. The requested provider id is not registered on this server.
  providerNotFound,

  /// HTTP 429 or 503. Retry later; no results were returned.
  transientError,

  /// HTTP 200 carrying an OCS-level failure instead of search data.
  ocsError,
}

/// A classified, validated response from a Talk message search provider.
final class MessageSearchResponse {
  const MessageSearchResponse._({
    required this.request,
    required this.classification,
    required this.results,
    required this.providerName,
    required this.isPaginated,
    required this.nextCursor,
  });

  final MessageSearchRequest request;
  final MessageSearchClassification classification;
  final List<MessageSearchResult> results;
  final String? providerName;
  final bool? isPaginated;
  final int? nextCursor;

  @override
  String toString() =>
      'MessageSearchResponse(classification: ${classification.name}, '
      'resultCount: ${results.length})';
}

MessageSearchResponse decodeMessageSearchResponse({
  required MessageSearchRequest request,
  required int statusCode,
  required Object? json,
}) {
  switch (statusCode) {
    case 401:
      return _empty(
        request,
        MessageSearchClassification.reauthenticationRequired,
      );
    case 404:
      return _empty(request, MessageSearchClassification.providerNotFound);
    case 429:
    case 503:
      return _empty(request, MessageSearchClassification.transientError);
    case 200:
      return _decodeSuccessOrOcsFailure(request: request, json: json);
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

MessageSearchResponse _decodeSuccessOrOcsFailure({
  required MessageSearchRequest request,
  required Object? json,
}) {
  const code = TalkProtocolErrorCode.invalidSearchResponse;
  final session = JsonFreezeSession(
    maximumDepth: _searchMaximumJsonDepth,
    maximumNodes: _searchMaximumJsonNodes,
    errorCode: code,
    errorPath: r'$',
  );
  final frozen = session.freeze(json);
  final root = requireObject(frozen, path: r'$', code: code);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: code);
  final meta = requireObject(ocs['meta'], path: r'$.ocs.meta', code: code);
  final status = requireString(
    meta['status'],
    path: r'$.ocs.meta.status',
    code: code,
    minLength: 1,
    maxLength: 128,
  );
  final ocsStatusCode = requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: code,
    minimum: 0,
    maximum: 999,
  );
  if (status != 'ok' || ocsStatusCode != 200) {
    return _empty(request, MessageSearchClassification.ocsError);
  }

  final data = requireObject(ocs['data'], path: r'$.ocs.data', code: code);
  final providerName = requireString(
    data['name'],
    path: r'$.ocs.data.name',
    code: code,
    maxLength: 256,
  );
  final rawEntries = requireList(
    data['entries'],
    path: r'$.ocs.data.entries',
    code: code,
  );
  if (rawEntries.length > messageSearchMaximumResults) {
    protocolFailure(code, r'$.ocs.data.entries');
  }

  final results = <MessageSearchResult>[];
  for (var index = 0; index < rawEntries.length; index++) {
    final result = parseMessageSearchResult(
      rawEntries[index],
      path: '\$.ocs.data.entries[$index]',
    );
    if (request.scope == MessageSearchScope.currentRoom &&
        result.roomToken != request.roomToken) {
      protocolFailure(
        code,
        '\$.ocs.data.entries[$index].attributes.conversation',
      );
    }
    results.add(result);
  }

  bool? isPaginated;
  if (data['isPaginated'] != null) {
    isPaginated = requireBool(
      data['isPaginated'],
      path: r'$.ocs.data.isPaginated',
      code: code,
    );
  }
  int? nextCursor;
  if (data['cursor'] != null) {
    nextCursor = requireInt(
      data['cursor'],
      path: r'$.ocs.data.cursor',
      code: code,
      minimum: 0,
    );
  }

  return MessageSearchResponse._(
    request: request,
    classification: results.isEmpty
        ? MessageSearchClassification.empty
        : MessageSearchClassification.results,
    results: List.unmodifiable(results),
    providerName: providerName,
    isPaginated: isPaginated,
    nextCursor: nextCursor,
  );
}

MessageSearchResponse _empty(
  MessageSearchRequest request,
  MessageSearchClassification classification,
) => MessageSearchResponse._(
  request: request,
  classification: classification,
  results: const [],
  providerName: null,
  isPaginated: null,
  nextCursor: null,
);
