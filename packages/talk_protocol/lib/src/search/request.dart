import 'dart:collection';

import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';

const String searchProvidersPath = '/ocs/v2.php/search/providers';
const String searchContractUserAgent =
    'com.nkshub.nextcloudtalk message-search-contract/0.1';

/// Talk's unified search provider id for messages across every conversation.
const String messageSearchGlobalProviderId = 'talk-message';

/// Talk's unified search provider id for messages in the current room only.
const String messageSearchCurrentRoomProviderId = 'talk-message-current';

const int messageSearchMinimumLimit = 1;

/// ASSUMPTION (unverified against a live server): Nextcloud's unified search
/// controller does not publish a documented hard cap for `limit`. This is a
/// defensive client-side ceiling, not a confirmed server limit.
const int messageSearchMaximumLimit = 50;

/// ASSUMPTION (unverified): a defensive client-side ceiling on search term
/// length. Confirm the actual accepted length against a live server.
const int messageSearchMaximumTermLength = 500;

/// Which unified search provider a [MessageSearchRequest] targets.
enum MessageSearchScope {
  /// Searches messages across every conversation the account can read.
  global,

  /// Searches messages within a single, explicitly scoped conversation.
  currentRoom;

  String get providerId => switch (this) {
    MessageSearchScope.global => messageSearchGlobalProviderId,
    MessageSearchScope.currentRoom => messageSearchCurrentRoomProviderId,
  };
}

/// A validated request against Talk's unified search message providers.
///
/// `GET /ocs/v2.php/search/providers/{providerId}/search`
final class MessageSearchRequest {
  MessageSearchRequest({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.scope,
    required this.term,
    required this.limit,
    this.cursor,
    this.roomToken,
    this.userAgent = searchContractUserAgent,
  }) {
    if (term.trim().isEmpty ||
        term.length > messageSearchMaximumTermLength ||
        _hasControlCharacter(term)) {
      _requestFailure(r'$.query.term');
    }
    if (limit < messageSearchMinimumLimit ||
        limit > messageSearchMaximumLimit) {
      _requestFailure(r'$.query.limit');
    }
    if (cursor != null && cursor! < 0) {
      _requestFailure(r'$.query.cursor');
    }
    if (scope == MessageSearchScope.currentRoom && roomToken == null) {
      _requestFailure(r'$.query.roomToken');
    }
    if (scope == MessageSearchScope.global && roomToken != null) {
      _requestFailure(r'$.query.roomToken');
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      _requestFailure(r'$.headers.userAgent');
    }
  }

  final AccountId accountId;
  final SearchRequestId requestId;
  final ServerBase server;
  final MessageSearchScope scope;
  final String term;
  final int limit;
  final int? cursor;
  final ConversationToken? roomToken;
  final String userAgent;

  /// Route context sent as the unified search `from` parameter.
  ///
  /// ASSUMPTION (unverified against a live server): Nextcloud's unified
  /// search scopes a "current context" provider such as
  /// [messageSearchCurrentRoomProviderId] through the generic `from` route
  /// parameter rather than a Talk-specific room parameter. This builds that
  /// route from Talk's web frontend path (`/call/{token}`). Confirm this
  /// against a real server before relying on room-scoped results — if the
  /// assumption is wrong, the server may ignore the scoping hint and return
  /// conversation-wide results instead.
  String? get _fromRoute =>
      roomToken == null ? null : '/call/${roomToken!.value}';

  Map<String, String> get queryParameters => UnmodifiableMapView({
    'format': 'json',
    'term': term,
    'limit': limit.toString(),
    if (cursor != null) 'cursor': cursor.toString(),
    'from': ?_fromRoute,
  });

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$searchProvidersPath/${scope.providerId}/search',
    queryParameters: queryParameters,
  );

  @override
  String toString() =>
      'MessageSearchRequest(scope: ${scope.name}, limit: $limit, '
      'hasCursor: ${cursor != null}, term: <redacted>)';
}

bool _hasControlCharacter(String value) {
  return value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}

Never _requestFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSearchRequest, path);
