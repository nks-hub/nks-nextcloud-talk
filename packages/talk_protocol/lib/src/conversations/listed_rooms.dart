import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

/// Conversations the server publishes as open to everyone on it.
///
/// `GET /ocs/v2.php/apps/spreed/api/v4/listed-room` is the only Talk endpoint
/// that returns rooms the account is NOT in yet, which is exactly what makes
/// them worth a separate contract: everything else in this package describes
/// rooms the account already has.
const String listedRoomPath = '/ocs/v2.php/apps/spreed/api/v4/listed-room';

const String listedRoomsContractUserAgent =
    'com.nkshub.nextcloudtalk listed-rooms-contract/0.1';

const int listedRoomsMaximumSearchTermCharacters = 256;
const int listedRoomsMaximumResponseBytes = 2 * 1024 * 1024;
const int listedRoomsMaximumRooms = 200;

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidListedRoomsRequest;
const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidListedRoomsResponse;

final class ListedRoomsRequest {
  ListedRoomsRequest({
    required this.accountId,
    required this.server,
    this.searchTerm = '',
    this.userAgent = listedRoomsContractUserAgent,
  }) {
    if (searchTerm.length > listedRoomsMaximumSearchTermCharacters ||
        searchTerm.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
      protocolFailure(_requestCode, r'$.query.searchTerm');
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(_requestCode, r'$.headers.userAgent');
    }
  }

  final AccountId accountId;
  final ServerBase server;

  /// Empty asks for everything the server lists.
  final String searchTerm;
  final String userAgent;

  String get httpMethod => 'GET';

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$listedRoomPath',
    queryParameters: {
      'format': 'json',
      if (searchTerm.isNotEmpty) 'searchTerm': searchTerm,
    },
  );

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  @override
  String toString() =>
      'ListedRoomsRequest(hasSearchTerm: ${searchTerm.isNotEmpty})';
}

/// One open conversation as advertised to somebody who is not in it.
///
/// Deliberately thin: a room the account has not joined has no unread count,
/// no read marker and no participant state, and inventing those fields here
/// would let the rest of the app treat it like a joined room.
final class ListedRoom {
  const ListedRoom({
    required this.token,
    required this.displayName,
    required this.description,
    required this.lastActivity,
    required this.hasPassword,
  });

  final ConversationToken token;
  final String displayName;
  final String description;

  /// Server time of the last message, or `null` when the server sent none.
  final DateTime? lastActivity;

  /// True when joining will ask for the conversation password.
  final bool hasPassword;

  @override
  String toString() => 'ListedRoom(hasPassword: $hasPassword)';
}

enum ListedRoomsOutcome {
  listed,

  /// HTTP 401: the account has to sign in again.
  reauthenticationRequired,

  /// The server does not publish open conversations at all.
  unavailable,

  /// HTTP 429 or 503: retry later.
  transientError,
}

final class ListedRoomsResponse {
  ListedRoomsResponse._({
    required this.request,
    required this.outcome,
    required List<ListedRoom> rooms,
  }) : rooms = UnmodifiableListView(rooms);

  final ListedRoomsRequest request;
  final ListedRoomsOutcome outcome;
  final List<ListedRoom> rooms;

  @override
  String toString() =>
      'ListedRoomsResponse(outcome: ${outcome.name}, rooms: ${rooms.length})';
}

ListedRoomsResponse decodeListedRoomsResponse({
  required ListedRoomsRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  ListedRoomsResponse plain(ListedRoomsOutcome outcome) =>
      ListedRoomsResponse._(
        request: request,
        outcome: outcome,
        rooms: const <ListedRoom>[],
      );

  switch (statusCode) {
    case 200:
      break;
    case 401:
      return plain(ListedRoomsOutcome.reauthenticationRequired);
    case 403:
    case 404:
      return plain(ListedRoomsOutcome.unavailable);
    case 429:
    case 503:
      return plain(ListedRoomsOutcome.transientError);
    default:
      protocolFailure(_responseCode, r'$.statusCode');
  }
  if (body.length > listedRoomsMaximumResponseBytes) {
    protocolFailure(_responseCode, r'$.body.length');
  }

  final String source;
  try {
    source = utf8.decode(body);
  } on FormatException {
    protocolFailure(_responseCode, r'$.body');
  }
  final decoded = decodeJsonRejectingDuplicateMembers(
    source,
    code: _responseCode,
    path: r'$.body',
  );
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: _responseCode,
  );
  final status = meta['statuscode'];
  if (status != 200 && status != 100) {
    protocolFailure(_responseCode, r'$.ocs.meta.statuscode');
  }
  final data = ocs['data'];
  if (data is! List) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  if (data.length > listedRoomsMaximumRooms) {
    protocolFailure(_responseCode, r'$.ocs.data.length');
  }

  final rooms = <ListedRoom>[
    for (var index = 0; index < data.length; index++)
      _decodeRoom(
        data[index],
        r'$.ocs.data['
        '$index]',
      ),
  ];
  return ListedRoomsResponse._(
    request: request,
    outcome: ListedRoomsOutcome.listed,
    rooms: rooms,
  );
}

ListedRoom _decodeRoom(Object? value, String path) {
  final room = requireObject(value, path: path, code: _responseCode);
  final token = ConversationToken.parse(
    room['token'],
    path: '$path.token',
    code: _responseCode,
  );
  final activity = room['lastActivity'];
  if (activity != null && activity is! int) {
    protocolFailure(_responseCode, '$path.lastActivity');
  }
  final seconds = activity as int?;
  return ListedRoom(
    token: token,
    displayName: _text(room['displayName'], '$path.displayName'),
    description: _text(room['description'], '$path.description'),
    lastActivity: seconds == null || seconds <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
    hasPassword: room['hasPassword'] == true,
  );
}

String _text(Object? value, String path) {
  if (value == null) {
    return '';
  }
  if (value is! String || value.length > 512) {
    protocolFailure(_responseCode, path);
  }
  return value;
}

/// Joins a conversation the account is not in yet.
///
/// `POST .../room/{token}/participants/active` is what actually makes the
/// account a participant; listing a room only advertises it.
final class JoinListedRoomRequest {
  JoinListedRoomRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    String password = '',
    this.userAgent = listedRoomsContractUserAgent,
  }) : _password = password {
    if (password.length > 256) {
      protocolFailure(_requestCode, r'$.body.password');
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(_requestCode, r'$.headers.userAgent');
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;
  final String _password;

  String get httpMethod => 'POST';

  bool get hasPassword => _password.isNotEmpty;

  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/spreed/api/v4/room/'
        '${roomToken.value}/participants/active',
    queryParameters: const {'format': 'json'},
  );

  Map<String, String> get headers => UnmodifiableMapView({
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
  });

  Uint8List get bodyBytes => Uint8List.fromList(
    utf8.encode(
      _password.isEmpty
          ? ''
          : 'password=${Uri.encodeQueryComponent(_password)}',
    ),
  );

  @override
  String toString() => 'JoinListedRoomRequest(hasPassword: $hasPassword)';
}

enum JoinListedRoomOutcome {
  joined,

  /// The conversation needs a password, or the one given was wrong.
  passwordRequired,

  /// Gone, or not open to this account after all.
  unavailable,

  /// HTTP 401: the account has to sign in again.
  reauthenticationRequired,

  /// HTTP 429 or 503: retry later.
  transientError,
}

final class JoinListedRoomResponse {
  const JoinListedRoomResponse._({
    required this.request,
    required this.outcome,
  });

  final JoinListedRoomRequest request;
  final JoinListedRoomOutcome outcome;

  @override
  String toString() => 'JoinListedRoomResponse(outcome: ${outcome.name})';
}

JoinListedRoomResponse decodeJoinListedRoomResponse({
  required JoinListedRoomRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  JoinListedRoomResponse result(JoinListedRoomOutcome outcome) =>
      JoinListedRoomResponse._(request: request, outcome: outcome);

  switch (statusCode) {
    case 200:
      // The join only counts once OCS says so; an HTTP 200 carrying an OCS
      // failure would otherwise open a conversation the account is not in.
      final status = _ocsStatus(body);
      return result(
        status == 100 || status == 200
            ? JoinListedRoomOutcome.joined
            : JoinListedRoomOutcome.unavailable,
      );
    case 401:
      return result(JoinListedRoomOutcome.reauthenticationRequired);
    case 403:
      return result(JoinListedRoomOutcome.passwordRequired);
    case 404:
    case 409:
      return result(JoinListedRoomOutcome.unavailable);
    case 429:
    case 503:
      return result(JoinListedRoomOutcome.transientError);
    default:
      protocolFailure(_responseCode, r'$.statusCode');
  }
}

int? _ocsStatus(Uint8List body) {
  if (body.isEmpty) {
    return null;
  }
  final String source;
  try {
    source = utf8.decode(body);
  } on FormatException {
    protocolFailure(_responseCode, r'$.body');
  }
  final decoded = decodeJsonRejectingDuplicateMembers(
    source,
    code: _responseCode,
    path: r'$.body',
  );
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: _responseCode,
  );
  final status = meta['statuscode'];
  return status is int ? status : null;
}
