import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final listRequest = FederationInvitationListRequest(
    accountId: AccountId.parse('acc-1'),
    server: server,
  );

  Uint8List body(Object json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  Map<String, Object?> invitation({int id = 7, int state = 0}) => {
    'id': id,
    'state': state,
    'localCloudId': 'me@cloud.example.invalid',
    'localToken': 'localtok1',
    'remoteAttendeeId': 12,
    'remoteServerUrl': 'talk2.example.invalid',
    'remoteToken': 'remotetok1',
    'roomName': 'Federated room',
    'userId': 'me',
    'inviterCloudId': 'other@talk2.example.invalid',
    'inviterDisplayName': 'Other Person',
  };

  Map<String, Object?> ocs(Object? data) => {
    'ocs': {
      'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
      'data': data,
    },
  };

  test('the list request targets the federation invitation route', () {
    expect(
      listRequest.uri.toString(),
      'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v1/'
      'federation/invitation?format=json',
    );
    expect(listRequest.headers['OCS-APIRequest'], 'true');
  });

  test('pending invitations decode with the fields the person decides on', () {
    final response = decodeFederationInvitationListResponse(
      request: listRequest,
      statusCode: 200,
      body: body(ocs([invitation(), invitation(id: 8)])),
    );
    expect(response.outcome, FederationInvitationOutcome.listed);
    expect(response.invitations, hasLength(2));
    final first = response.invitations.first;
    expect(first.id, 7);
    expect(first.isPending, isTrue);
    expect(first.roomName, 'Federated room');
    expect(first.inviterDisplayName, 'Other Person');
    expect(first.remoteServerUrl, 'talk2.example.invalid');
    expect(first.localToken, 'localtok1');
  });

  test('duplicate ids and missing tokens are rejected', () {
    expect(
      () => decodeFederationInvitationListResponse(
        request: listRequest,
        statusCode: 200,
        body: body(ocs([invitation(), invitation()])),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    final missingToken = invitation()..['localToken'] = '';
    expect(
      () => decodeFederationInvitationListResponse(
        request: listRequest,
        statusCode: 200,
        body: body(ocs([missingToken])),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('HTTP outcomes map without guessing', () {
    for (final (status, outcome) in [
      (401, FederationInvitationOutcome.reauthenticationRequired),
      (404, FederationInvitationOutcome.unavailable),
      (503, FederationInvitationOutcome.transientError),
    ]) {
      expect(
        decodeFederationInvitationListResponse(
          request: listRequest,
          statusCode: status,
          body: Uint8List(0),
        ).outcome,
        outcome,
      );
    }
    expect(
      () => decodeFederationInvitationListResponse(
        request: listRequest,
        statusCode: 500,
        body: Uint8List(0),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('accept returns the local room, reject needs no body', () {
    final accept = FederationInvitationDecisionRequest(
      accountId: AccountId.parse('acc-1'),
      server: server,
      invitationId: 7,
      accept: true,
    );
    expect(accept.httpMethod, 'POST');
    expect(accept.uri.path, endsWith('/federation/invitation/7'));
    final accepted = decodeFederationInvitationDecisionResponse(
      request: accept,
      statusCode: 200,
      body: body(ocs({'token': 'localtok1', 'type': 2})),
    );
    expect(accepted.outcome, FederationInvitationDecisionOutcome.applied);
    expect(accepted.roomToken?.value, 'localtok1');

    final reject = FederationInvitationDecisionRequest(
      accountId: AccountId.parse('acc-1'),
      server: server,
      invitationId: 7,
      accept: false,
    );
    expect(reject.httpMethod, 'DELETE');
    final rejected = decodeFederationInvitationDecisionResponse(
      request: reject,
      statusCode: 200,
      body: Uint8List(0),
    );
    expect(rejected.outcome, FederationInvitationDecisionOutcome.applied);
    expect(rejected.roomToken, isNull);
    expect(
      decodeFederationInvitationDecisionResponse(
        request: accept,
        statusCode: 410,
        body: Uint8List(0),
      ).outcome,
      FederationInvitationDecisionOutcome.remoteGone,
    );
    expect(
      () => FederationInvitationDecisionRequest(
        accountId: AccountId.parse('acc-1'),
        server: server,
        invitationId: 0,
        accept: true,
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });
}
