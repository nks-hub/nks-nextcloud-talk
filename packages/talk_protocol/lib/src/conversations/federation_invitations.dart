import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

/// Invitations into conversations hosted on another Nextcloud server.
///
/// Talk federation v1 keeps them on the invited account's own server:
/// `GET /ocs/v2.php/apps/spreed/api/v1/federation/invitation` lists what is
/// pending, `POST …/invitation/{id}` accepts (the server then creates the
/// local proxy room and returns it) and `DELETE …/invitation/{id}` rejects.
/// The room list's `X-Nextcloud-Talk-Federation-Invites` header carries only
/// the count; the invitations themselves come from this endpoint.
const String federationInvitationPath =
    '/ocs/v2.php/apps/spreed/api/v1/federation/invitation';

const String federationInvitationContractUserAgent =
    'com.nkshub.nextcloudtalk federation-invitations-contract/0.1';

const int federationInvitationMaximumResponseBytes = 2 * 1024 * 1024;
const int federationInvitationMaximumInvitations = 200;
const int federationInvitationMaximumTextCharacters = 512;

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidFederationInvitationRequest;
const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidFederationInvitationResponse;

final class FederationInvitationListRequest {
  FederationInvitationListRequest({
    required this.accountId,
    required this.server,
    this.userAgent = federationInvitationContractUserAgent,
  }) {
    _checkUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final String userAgent;

  String get httpMethod => 'GET';

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$federationInvitationPath',
    queryParameters: const {'format': 'json'},
  );

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  @override
  String toString() => 'FederationInvitationListRequest()';
}

/// One pending invitation as the invited account's server describes it.
///
/// `remoteServerUrl` and `inviterCloudId` are shown to the person deciding,
/// never used as an origin to talk to: accepting goes through the account's
/// own server, which is the only one holding credentials.
final class FederationInvitation {
  const FederationInvitation({
    required this.id,
    required this.state,
    required this.localToken,
    required this.remoteServerUrl,
    required this.remoteToken,
    required this.roomName,
    required this.inviterCloudId,
    required this.inviterDisplayName,
  });

  final int id;

  /// 0 pending, 1 accepted; the list only ever returns pending ones, and
  /// anything else is kept as data rather than turned into a guess.
  final int state;
  final String localToken;
  final String remoteServerUrl;
  final String remoteToken;
  final String roomName;
  final String inviterCloudId;
  final String inviterDisplayName;

  bool get isPending => state == 0;

  @override
  String toString() => 'FederationInvitation(id: $id, state: $state)';
}

enum FederationInvitationOutcome {
  listed,

  /// HTTP 401: the account has to sign in again.
  reauthenticationRequired,

  /// The server has no federation (HTTP 403/404).
  unavailable,

  /// HTTP 429 or 503: retry later.
  transientError,
}

final class FederationInvitationListResponse {
  FederationInvitationListResponse._({
    required this.request,
    required this.outcome,
    required List<FederationInvitation> invitations,
  }) : invitations = UnmodifiableListView(invitations);

  final FederationInvitationListRequest request;
  final FederationInvitationOutcome outcome;
  final List<FederationInvitation> invitations;

  @override
  String toString() =>
      'FederationInvitationListResponse(outcome: ${outcome.name}, '
      'invitations: ${invitations.length})';
}

FederationInvitationListResponse decodeFederationInvitationListResponse({
  required FederationInvitationListRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  FederationInvitationListResponse plain(FederationInvitationOutcome outcome) =>
      FederationInvitationListResponse._(
        request: request,
        outcome: outcome,
        invitations: const <FederationInvitation>[],
      );
  switch (statusCode) {
    case 200:
      break;
    case 401:
      return plain(FederationInvitationOutcome.reauthenticationRequired);
    case 403:
    case 404:
      return plain(FederationInvitationOutcome.unavailable);
    case 429:
    case 503:
      return plain(FederationInvitationOutcome.transientError);
    default:
      protocolFailure(_responseCode, r'$.statusCode');
  }
  final data = _ocsData(body);
  if (data is! List) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  if (data.length > federationInvitationMaximumInvitations) {
    protocolFailure(_responseCode, r'$.ocs.data.length');
  }
  final ids = <int>{};
  final invitations = <FederationInvitation>[
    for (var index = 0; index < data.length; index++)
      _decodeInvitation(data[index], '\$.ocs.data[$index]'),
  ];
  for (final invitation in invitations) {
    if (!ids.add(invitation.id)) {
      protocolFailure(_responseCode, r'$.ocs.data');
    }
  }
  return FederationInvitationListResponse._(
    request: request,
    outcome: FederationInvitationOutcome.listed,
    invitations: invitations,
  );
}

/// Accepts (`POST`) or rejects (`DELETE`) one invitation on the account's
/// own server.
final class FederationInvitationDecisionRequest {
  FederationInvitationDecisionRequest({
    required this.accountId,
    required this.server,
    required this.invitationId,
    required this.accept,
    this.userAgent = federationInvitationContractUserAgent,
  }) {
    if (invitationId < 1) {
      protocolFailure(_requestCode, r'$.path.id');
    }
    _checkUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final int invitationId;
  final bool accept;
  final String userAgent;

  String get httpMethod => accept ? 'POST' : 'DELETE';

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$federationInvitationPath/$invitationId',
    queryParameters: const {'format': 'json'},
  );

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  @override
  String toString() =>
      'FederationInvitationDecisionRequest(id: $invitationId, accept: $accept)';
}

enum FederationInvitationDecisionOutcome {
  /// The server confirmed the decision; for an accept `roomToken` names the
  /// local proxy room the account can open.
  applied,

  /// HTTP 404: the invitation is gone (already decided, or withdrawn).
  notFound,

  /// HTTP 410: the remote server no longer knows the conversation.
  remoteGone,

  /// HTTP 400: the server refused (for example an already accepted one).
  rejected,
  reauthenticationRequired,
  transientError,
}

final class FederationInvitationDecisionResponse {
  const FederationInvitationDecisionResponse._({
    required this.request,
    required this.outcome,
    required this.roomToken,
  });

  final FederationInvitationDecisionRequest request;
  final FederationInvitationDecisionOutcome outcome;

  /// Token of the local room after an accept, otherwise null.
  final ConversationToken? roomToken;

  @override
  String toString() =>
      'FederationInvitationDecisionResponse(outcome: ${outcome.name})';
}

FederationInvitationDecisionResponse
decodeFederationInvitationDecisionResponse({
  required FederationInvitationDecisionRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  FederationInvitationDecisionResponse plain(
    FederationInvitationDecisionOutcome outcome,
  ) => FederationInvitationDecisionResponse._(
    request: request,
    outcome: outcome,
    roomToken: null,
  );
  switch (statusCode) {
    case 200:
      break;
    case 400:
      return plain(FederationInvitationDecisionOutcome.rejected);
    case 401:
      return plain(
        FederationInvitationDecisionOutcome.reauthenticationRequired,
      );
    case 404:
      return plain(FederationInvitationDecisionOutcome.notFound);
    case 410:
      return plain(FederationInvitationDecisionOutcome.remoteGone);
    case 429:
    case 503:
      return plain(FederationInvitationDecisionOutcome.transientError);
    default:
      protocolFailure(_responseCode, r'$.statusCode');
  }
  if (!request.accept) {
    return plain(FederationInvitationDecisionOutcome.applied);
  }
  final data = requireObject(
    _ocsData(body),
    path: r'$.ocs.data',
    code: _responseCode,
  );
  return FederationInvitationDecisionResponse._(
    request: request,
    outcome: FederationInvitationDecisionOutcome.applied,
    roomToken: ConversationToken.parse(
      data['token'],
      path: r'$.ocs.data.token',
      code: _responseCode,
    ),
  );
}

Object? _ocsData(Uint8List body) {
  if (body.length > federationInvitationMaximumResponseBytes) {
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
  return ocs['data'];
}

FederationInvitation _decodeInvitation(Object? value, String path) {
  final invitation = requireObject(value, path: path, code: _responseCode);
  final id = invitation['id'];
  if (id is! int || id < 1) {
    protocolFailure(_responseCode, '$path.id');
  }
  final state = invitation['state'];
  if (state is! int || state < 0) {
    protocolFailure(_responseCode, '$path.state');
  }
  final remoteServer = _text(
    invitation['remoteServerUrl'],
    '$path.remoteServerUrl',
  );
  if (remoteServer.isEmpty) {
    protocolFailure(_responseCode, '$path.remoteServerUrl');
  }
  final localToken = _text(invitation['localToken'], '$path.localToken');
  final remoteToken = _text(invitation['remoteToken'], '$path.remoteToken');
  if (localToken.isEmpty || remoteToken.isEmpty) {
    protocolFailure(_responseCode, '$path.localToken');
  }
  return FederationInvitation(
    id: id,
    state: state,
    localToken: localToken,
    remoteServerUrl: remoteServer,
    remoteToken: remoteToken,
    roomName: _text(invitation['roomName'], '$path.roomName'),
    inviterCloudId: _text(invitation['inviterCloudId'], '$path.inviterCloudId'),
    inviterDisplayName: _text(
      invitation['inviterDisplayName'],
      '$path.inviterDisplayName',
    ),
  );
}

String _text(Object? value, String path) {
  if (value == null) {
    return '';
  }
  if (value is! String ||
      value.length > federationInvitationMaximumTextCharacters ||
      value.codeUnits.any((unit) => unit < 0x20 && unit != 0x09)) {
    protocolFailure(_responseCode, path);
  }
  return value;
}

void _checkUserAgent(String userAgent) {
  if (userAgent.isEmpty ||
      userAgent.length > 256 ||
      userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, r'$.headers.userAgent');
  }
}
