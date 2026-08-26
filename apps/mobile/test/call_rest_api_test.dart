import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  test('GET v4 parses peers under the bound account and room', () async {
    late http.Request captured;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          _ocs(<Object?>[
            <String, Object?>{
              'actorType': 'users',
              'actorId': 'alice',
              'displayName': 'Alice',
              'token': 'rooma123',
              'lastPing': 1770000000,
              'sessionId': 'session-a',
            },
          ]),
          200,
        );
      }),
    );
    addTearDown(api.close);

    final response = await api.getCallPeers(
      peersRequest: CallPeersRequest(
        context: CallRequestContext(
          authority: _authority(),
          mutationSequence: 0,
        ),
      ),
      loginName: 'alice',
      appPassword: 'fixture-password',
    );

    expect(captured.method, 'GET');
    expect(
      captured.url.path,
      '/nextcloud/ocs/v2.php/apps/spreed/api/v4/call/rooma123',
    );
    expect(captured.url.queryParameters['format'], 'json');
    expect(captured.headers['OCS-APIRequest'], 'true');
    expect(captured.headers['Authorization'], startsWith('Basic '));
    expect(response.ownSessionPresent, isTrue);
  });

  test(
    'POST encodes repeated silentFor fields without losing entries',
    () async {
      late http.Request captured;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          captured = request;
          return http.Response(_ocs(null), 200);
        }),
      );
      addTearDown(api.close);
      final context = CallRequestContext(
        authority: _authority(),
        mutationSequence: 1,
      );

      final response = await api.joinCall(
        joinRequest: JoinCallRequest(
          context: context,
          flags: CallInCallFlags.audioVideo(),
          silent: true,
          recordingConsent: true,
          silentFor: <ConversationSessionId>[
            ConversationSessionId.parse('old-session-a'),
            ConversationSessionId.parse('old-session-b'),
          ],
        ),
        loginName: 'alice',
        appPassword: 'fixture-password',
      );

      expect(captured.method, 'POST');
      expect(
        captured.headers['Content-Type'],
        'application/x-www-form-urlencoded; charset=utf-8',
      );
      expect(
        captured.body,
        'flags=7&silent=1&recordingConsent=1&'
        'silentFor%5B%5D=old-session-a&silentFor%5B%5D=old-session-b',
      );
      expect(response.classification, CallResponseClassification.confirmed);
    },
  );

  test(
    'PUT and DELETE use their exact flags and all wire parameters',
    () async {
      final captured = <http.Request>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          captured.add(request);
          return http.Response(_ocs(null), 200);
        }),
      );
      addTearDown(api.close);
      final context = CallRequestContext(
        authority: _authority(),
        mutationSequence: 2,
      );

      await api.updateCallFlags(
        updateRequest: UpdateCallFlagsRequest(
          context: context,
          flags: CallInCallFlags.parse(3, requireJoined: true),
        ),
        loginName: 'alice',
        appPassword: 'fixture-password',
      );
      await api.leaveCall(
        leaveRequest: LeaveCallRequest(context: context, endForEveryone: true),
        loginName: 'alice',
        appPassword: 'fixture-password',
      );

      expect(captured[0].method, 'PUT');
      expect(captured[0].body, 'flags=3');
      expect(captured[1].method, 'DELETE');
      expect(captured[1].url.queryParameters['all'], '1');
    },
  );

  test(
    'transport preserves all deterministic and transient statuses',
    () async {
      const expected = <int, CallResponseClassification>{
        400: CallResponseClassification.rejected,
        401: CallResponseClassification.reauthenticationRequired,
        403: CallResponseClassification.forbidden,
        404: CallResponseClassification.sessionMissing,
        409: CallResponseClassification.conflict,
        429: CallResponseClassification.rateLimited,
        500: CallResponseClassification.serverFailure,
        503: CallResponseClassification.serverFailure,
        599: CallResponseClassification.serverFailure,
      };
      for (final entry in expected.entries) {
        final api = HttpNextcloudApi(
          client: MockClient(
            (request) async => http.Response('not trusted JSON', entry.key),
          ),
        );
        final response = await api.joinCall(
          joinRequest: JoinCallRequest(
            context: CallRequestContext(
              authority: _authority(),
              mutationSequence: 1,
            ),
            flags: CallInCallFlags.audioVideo(),
            silent: false,
            recordingConsent: false,
          ),
          loginName: 'alice',
          appPassword: 'fixture-password',
        );
        api.close();
        expect(response.classification, entry.value, reason: '${entry.key}');
      }
    },
  );

  test('rejects an oversized peer body before JSON decoding', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (request) async => http.Response(
          List<String>.filled(1024 * 1024 + 1, 'x').join(),
          200,
        ),
      ),
    );
    addTearDown(api.close);

    expect(
      () => api.getCallPeers(
        peersRequest: CallPeersRequest(
          context: CallRequestContext(
            authority: _authority(),
            mutationSequence: 0,
          ),
        ),
        loginName: 'alice',
        appPassword: 'fixture-password',
      ),
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.responseTooLarge,
        ),
      ),
    );
  });
}

CallLifecycleAuthority _authority() => CallLifecycleAuthority(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
  nextcloudSessionId: ConversationSessionId.parse('session-a'),
  credentialGeneration: 1,
  capabilityGeneration: 1,
  capabilityRevision: 'call-v4:1:1:1:2',
);

String _ocs(Object? data) => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': data,
  },
});
