import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

/// Endpoint used to find people and groups when starting a new conversation.
///
/// Nextcloud Talk exposes two endpoints that both "search for something you
/// might open": `GET .../apps/spreed/api/v4/room?searchTerm=` searches
/// *existing* conversations the account can already see, while
/// `GET /ocs/v2.php/core/autocomplete/get` searches share recipients
/// (users, groups, ...) regardless of whether a room exists yet. Finding a
/// person or group to start a brand-new chat with is a recipient lookup,
/// not a room lookup, so this contract talks to `core/autocomplete/get`
/// with `itemType=call` and `itemId=new` -- the same request shape the
/// Talk web client uses for its "new conversation" recipient picker.
const String recipientAutocompletePath = '/ocs/v2.php/core/autocomplete/get';
const String recipientSearchContractUserAgent =
    'com.nkshub.nextcloudtalk recipient-search-contract/0.1';

/// The recipient kinds this contract is willing to invite into a room.
enum RecipientShareType {
  user(0),
  group(1);

  const RecipientShareType(this.wireValue);

  final int wireValue;
}

final class RecipientSearchRequest {
  RecipientSearchRequest({
    required this.accountId,
    required this.server,
    required this.searchTerm,
    this.userAgent = recipientSearchContractUserAgent,
  }) {
    if (searchTerm.isEmpty ||
        searchTerm.length > 256 ||
        _hasControlCharacter(searchTerm)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidRecipientSearchRequest,
        r'$.query.search',
      );
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidRecipientSearchRequest,
        r'$.headers.userAgent',
      );
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final String searchTerm;
  final String userAgent;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$recipientAutocompletePath',
    queryParameters: <String, Object>{
      'format': 'json',
      'itemType': 'call',
      'itemId': 'new',
      'search': searchTerm,
      'shareTypes[]': <String>[
        for (final type in RecipientShareType.values) type.wireValue.toString(),
      ],
    },
  );

  @override
  String toString() => 'RecipientSearchRequest()';
}

bool _hasControlCharacter(String value) =>
    value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
