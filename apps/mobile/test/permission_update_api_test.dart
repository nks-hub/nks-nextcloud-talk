import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  final policy = _policy();
  final accountId = AccountId.parse('account-a');
  final server = ServerBase.parse('https://cloud.example.invalid/cloud');
  final token = ConversationToken.parse('rooma123', path: r'$.token');
  final requests = <PermissionUpdateRequest>[
    SetRoomDefaultPermissionsRequest(
      accountId: accountId,
      server: server,
      roomToken: token,
      policy: policy,
      permissions: 129,
    ),
    SetParticipantPermissionsRequest(
      accountId: accountId,
      server: server,
      roomToken: token,
      policy: policy,
      permissions: 0,
      attendeeId: 17,
    ),
    SetRoomMentionPermissionsRequest(
      accountId: accountId,
      server: server,
      roomToken: token,
      policy: policy,
      mentionPermissions: 1,
    ),
  ];

  for (final expected in requests) {
    test(
      'sends authenticated ${expected.kind.name} mutation and decodes its actual payload shape',
      () async {
        late http.Request captured;
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            captured = request;
            return _response(
              200,
              expected.kind == PermissionEditKind.attendee
                  ? [_attendee()]
                  : _room(),
            );
          }),
        );
        addTearDown(api.close);
        final result = await api.updateConversationPermissions(
          permissionRequest: expected,
          loginName: 'fixture-user',
          appPassword: 'fixture-password',
        );
        expect(captured.method, 'PUT');
        expect(captured.url, expected.uri);
        expect(captured.bodyFields, expected.formBody);
        expect(captured.headers['OCS-APIRequest'], 'true');
        expect(
          captured.headers['authorization'],
          'Basic ${base64Encode(utf8.encode('fixture-user:fixture-password'))}',
        );
        expect(
          result,
          expected.kind == PermissionEditKind.attendee
              ? isA<AttendeePermissionsUpdated>()
              : isA<RoomPermissionsUpdated>(),
        );
      },
    );
  }

  test('returns a forced-policy refusal without replaying it', () async {
    var count = 0;
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        count++;
        return _response(400, {'error': 'forced', 'forced': 128});
      }),
    );
    addTearDown(api.close);
    final result =
        await api.updateConversationPermissions(
              permissionRequest: requests.first,
              loginName: 'fixture-user',
              appPassword: 'fixture-password',
            )
            as PermissionUpdateFailure;
    expect(result.reason, 'forced');
    expect(result.forcedValue, 128);
    expect(count, 1);
  });

  test('does not replay a server or transport failure', () async {
    for (final disconnect in [false, true]) {
      var count = 0;
      final api = HttpNextcloudApi(
        client: MockClient((_) async {
          count++;
          if (disconnect) throw http.ClientException('Disconnected');
          return http.Response('', 503);
        }),
      );
      addTearDown(api.close);
      final future = api.updateConversationPermissions(
        permissionRequest: requests.first,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      if (disconnect) {
        await expectLater(future, throwsA(isA<NextcloudApiException>()));
      } else {
        expect(
          (await future as PermissionUpdateFailure).kind,
          PermissionUpdateFailureKind.serviceUnavailable,
        );
      }
      expect(count, 1);
    }
  });

  test('rejects a successful response for a different attendee', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => _response(200, [
          {..._attendee(), 'attendeeId': 18},
        ]),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.updateConversationPermissions(
        permissionRequest: requests[1],
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('bounds permission responses at the transport', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async =>
            http.Response(' ' * (permissionUpdateMaximumBytes + 1), 200),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.updateConversationPermissions(
        permissionRequest: requests.first,
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      throwsA(
        isA<NextcloudApiException>().having(
          (e) => e.code,
          'code',
          NextcloudApiError.responseTooLarge,
        ),
      ),
    );
  });
}

RoomPermissionPolicy _policy() {
  final root =
      readFixtureJson(
            'client-bootstrap/fixtures/capabilities-authenticated.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  capabilities['spreed'] = {
    'features': [
      'conversation-permissions',
      'publishing-permissions',
      'mention-permissions',
      'react-permission',
    ],
  };
  return RoomPermissionPolicy.fromCapabilities(
    CapabilitySnapshot.fromJson(root, context: CapabilityContext.authenticated),
  );
}

Map<String, Object?> _room() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  return {
    ...(ocs['data']! as List<Object?>).first! as Map<String, Object?>,
    'token': 'rooma123',
  };
}

Map<String, Object?> _attendee() => {
  'attendeeId': 17,
  'actorType': 'users',
  'actorId': 'person-a',
  'displayName': 'Person A',
  'participantType': 3,
  'lastPing': 0,
  'sessionIds': <String>[],
  'permissions': 502,
  'attendeePermissions': 0,
  'inCall': 0,
};

http.Response _response(int status, Object? data) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {
        'status': status == 200 ? 'ok' : 'failure',
        'statuscode': status,
      },
      'data': data,
    },
  }),
  status,
);
