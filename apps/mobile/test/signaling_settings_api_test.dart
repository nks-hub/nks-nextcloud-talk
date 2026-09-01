import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  SignalingSettingsRequest request({String accountId = 'account-a'}) {
    return SignalingSettingsRequest(
      context: SignalingRequestContext(
        accountId: AccountId.parse(accountId),
        requestId: SignalingRequestId.parse('request-a'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        credentialGeneration: 1,
        capabilityGeneration: 1,
        settingsRevision: 'revision-a',
        connectionEpoch: 1,
        roomEpoch: 1,
      ),
    );
  }

  test('an authorized settings fetch resolves the internal transport', () async {
    late http.BaseRequest captured;
    // The fixture file is a case list, so the request is answered with the
    // first case payload instead of the whole file.
    final cases =
        readFixtureJson('signaling/fixtures/settings.cases.json')
            as List<Object?>;
    final internal =
        (cases.first! as Map<String, Object?>)['data']! as Map<String, Object?>;
    final scopedApi = HttpNextcloudApi(
      client: MockClient((incoming) async {
        captured = incoming;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'ok',
                  'statuscode': 200,
                  'message': 'OK',
                },
                'data': internal,
              },
            }),
          ),
          200,
        );
      }),
    );
    addTearDown(scopedApi.close);

    final response = await scopedApi.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-app-password',
    );

    expect(captured.method, 'GET');
    expect(captured.url.path, endsWith('/signaling/settings'));
    expect(captured.url.queryParameters['token'], 'rooma123');
    expect(captured.headers['OCS-APIRequest'], 'true');
    expect(
      captured.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('fixture-user:fixture-app-password'))}',
    );
    expect(response.classification, SignalingSettingsClassification.confirmed);
    expect(response.settings!.transport, SignalingTransportKind.internal);
  });

  test('an unauthorized settings fetch asks for reauthentication', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'failure',
                  'statuscode': 401,
                  'message': 'Unauthorised',
                },
                'data': <String, Object?>{},
              },
            }),
          ),
          401,
        ),
      ),
    );
    addTearDown(api.close);

    final response = await api.getSignalingSettings(
      settingsRequest: request(),
      loginName: 'fixture-user',
      appPassword: 'fixture-app-password',
    );

    expect(
      response.classification,
      SignalingSettingsClassification.reauthenticationRequired,
    );
    expect(response.settings, isNull);
  });

  test('room session cookies stay isolated by account', () async {
    final requests = <http.BaseRequest>[];
    final cases =
        readFixtureJson('signaling/fixtures/settings.cases.json')
            as List<Object?>;
    final internal =
        (cases.first! as Map<String, Object?>)['data']! as Map<String, Object?>;
    final conversations =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )!
            as Map<String, Object?>;
    final room = Map<String, Object?>.from(
      ((conversations['ocs']! as Map<String, Object?>)['data']! as List).first
          as Map<String, Object?>,
    )..['sessionId'] = 'active-session';
    var activeResponses = 0;
    final api = HttpNextcloudApi(
      client: MockClient((incoming) async {
        requests.add(incoming);
        if (incoming.url.path.endsWith('/participants/active')) {
          activeResponses++;
          final cookie = activeResponses == 1 ? 'session-a' : 'session-b';
          return http.Response(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'ok',
                  'statuscode': 200,
                  'message': 'OK',
                },
                'data': room,
              },
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json',
              'set-cookie': 'nc_session=$cookie; Path=/; HttpOnly',
            },
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': internal,
            },
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final server = ServerBase.parse('https://cloud.example.invalid');
    final roomToken = ConversationToken.parse('rooma123', path: r'$.roomToken');

    for (final accountId in <String>['account-a', 'account-b']) {
      final response = await api.activateRoomSession(
        activeRequest: ActiveRoomSessionRequest(
          accountId: AccountId.parse(accountId),
          server: server,
          roomToken: roomToken,
        ),
        loginName: '$accountId-user',
        appPassword: 'fixture-password',
      );
      expect(response, isA<ActiveRoomSessionSuccess>());
    }
    await api.getSignalingSettings(
      settingsRequest: request(accountId: 'account-a'),
      loginName: 'account-a-user',
      appPassword: 'fixture-password',
    );
    await api.getSignalingSettings(
      settingsRequest: request(accountId: 'account-b'),
      loginName: 'account-b-user',
      appPassword: 'fixture-password',
    );

    expect(requests[0].headers['Cookie'], isNull);
    expect(requests[1].headers['Cookie'], isNull);
    expect(requests[2].headers['Cookie'], 'nc_session=session-a');
    expect(requests[3].headers['Cookie'], 'nc_session=session-b');
    api.clearAccountSession('account-a');
    await api.getSignalingSettings(
      settingsRequest: request(accountId: 'account-a'),
      loginName: 'account-a-user',
      appPassword: 'fixture-password',
    );
    expect(requests[4].headers['Cookie'], isNull);
  });
}
