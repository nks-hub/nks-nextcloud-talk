import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  test('signaling settings enforces the signaling wire bound', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => http.Response('x' * (maximumSignalingWireBytes + 1), 200),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.getSignalingSettings(
        settingsRequest: SignalingSettingsRequest(
          context: _context('settings-request-a'),
        ),
        loginName: 'fixture-user',
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

  test(
    'internal pull preserves scoped URI, auth, headers and participants',
    () async {
      late http.BaseRequest captured;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          captured = request;
          return _response(200, <Object?>[
            <String, Object?>{
              'type': 'usersInRoom',
              'data': <Object?>[
                <String, Object?>{
                  'sessionId': 'peer-session-a',
                  'roomId': 42,
                  'lastPing': 1,
                  'userId': 'user-a',
                  'inCall': 1,
                  'participantPermissions': 7,
                  'actorType': 'users',
                  'actorId': 'user-a',
                },
              ],
            },
          ]);
        }),
      );
      addTearDown(api.close);

      final response = await api.pullInternalSignaling(
        pullRequest: _pullRequest(),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );

      expect(captured.method, 'GET');
      expect(
        captured.url.path,
        '/nextcloud/ocs/v2.php/apps/spreed/api/v3/signaling/rooma123',
      );
      expect(captured.url.queryParameters, const <String, String>{
        'format': 'json',
      });
      expect(captured.headers['OCS-APIRequest'], 'true');
      expect(captured.headers['User-Agent'], signalingContractUserAgent);
      expect(
        captured.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('fixture-user:fixture-password'))}',
      );
      expect(
        response.classification,
        InternalSignalingClassification.confirmed,
      );
      expect(response.participants.single.peerId.value, 'peer-session-a');
    },
  );

  test('internal batch sends the contract form body exactly once', () async {
    var requestCount = 0;
    late http.Request captured;
    final batch = _batchRequest();
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requestCount++;
        captured = request;
        return _response(200, const <Object?>[]);
      }),
    );
    addTearDown(api.close);

    final response = await api.sendInternalSignalingBatch(
      batchRequest: batch,
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );

    expect(requestCount, 1);
    expect(captured.method, 'POST');
    expect(captured.bodyFields, batch.formFields);
    expect(
      captured.headers['Content-Type'],
      startsWith('application/x-www-form-urlencoded'),
    );
    expect(response.classification, InternalSignalingClassification.confirmed);
  });

  test('internal status codes retain their protocol classification', () async {
    const cases = <int, InternalSignalingClassification>{
      400: InternalSignalingClassification.profileRefreshRequired,
      401: InternalSignalingClassification.reauthenticationRequired,
      404: InternalSignalingClassification.roomRefreshRequired,
      409: InternalSignalingClassification.sessionTerminated,
      503: InternalSignalingClassification.serverError,
    };

    for (final entry in cases.entries) {
      final api = HttpNextcloudApi(
        client: MockClient(
          (_) async => _response(entry.key, const <Object?>[]),
        ),
      );
      try {
        final response = await api.pullInternalSignaling(
          pullRequest: _pullRequest(requestId: 'request-${entry.key}'),
          loginName: 'fixture-user',
          appPassword: 'fixture-password',
        );
        expect(
          response.classification,
          entry.value,
          reason: 'HTTP ${entry.key}',
        );
        expect(response.messages, isEmpty);
        expect(response.participants, isEmpty);
      } finally {
        api.close();
      }
    }
  });

  test('internal signaling enforces the wire response bound', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => http.Response('x' * (maximumSignalingWireBytes + 1), 200),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.pullInternalSignaling(
        pullRequest: _pullRequest(),
        loginName: 'fixture-user',
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

  test('batch transport failure is surfaced without replay', () async {
    var attempts = 0;
    final api = HttpNextcloudApi(
      client: MockClient((_) async {
        attempts++;
        throw http.ClientException('synthetic transport failure');
      }),
    );
    addTearDown(api.close);

    await expectLater(
      api.sendInternalSignalingBatch(
        batchRequest: _batchRequest(),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.network,
        ),
      ),
    );
    expect(attempts, 1);
  });

  test('internal pull propagates abort as cancellation', () async {
    final started = Completer<void>();
    final cancellation = Completer<void>();
    final api = HttpNextcloudApi(client: _AbortClient(started));
    addTearDown(api.close);

    final pull = api.pullInternalSignaling(
      pullRequest: _pullRequest(),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
      abortTrigger: cancellation.future,
    );
    await started.future;
    cancellation.complete();

    await expectLater(
      pull,
      throwsA(
        isA<NextcloudApiException>().having(
          (error) => error.code,
          'code',
          NextcloudApiError.cancelled,
        ),
      ),
    );
  });
}

InternalSignalingPullRequest _pullRequest({String requestId = 'request-a'}) {
  return InternalSignalingPullRequest(
    context: _context(requestId),
    nextcloudSessionId: ConversationSessionId.parse('session-a'),
  );
}

InternalSignalingBatchRequest _batchRequest() {
  return InternalSignalingBatchRequest(
    context: _context('request-b'),
    nextcloudSessionId: ConversationSessionId.parse('session-a'),
    messages: <SignalingPeerMessage>[
      SignalingPeerMessage(
        type: 'offer',
        roomType: 'video',
        sid: 'stream-a',
        recipient: SignalingPeerId.parse('peer-b'),
        sender: null,
        payload: SignalingOpaquePayload.fromJson(<String, Object?>{
          'sdp': 'synthetic-sdp',
        }),
      ),
    ],
  );
}

SignalingRequestContext _context(String requestId) => SignalingRequestContext(
  accountId: AccountId.parse('account-a'),
  requestId: SignalingRequestId.parse(requestId),
  server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
  credentialGeneration: 1,
  capabilityGeneration: 1,
  settingsRevision: 'revision-a',
  connectionEpoch: 1,
  roomEpoch: 1,
);

http.Response _response(int statusCode, Object? data) => http.Response(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': statusCode >= 200 && statusCode < 300 ? 'ok' : 'failure',
        'statuscode': statusCode,
        'message': statusCode == 200 ? 'OK' : 'Synthetic failure',
      },
      'data': data,
    },
  }),
  statusCode,
  headers: const <String, String>{'content-type': 'application/json'},
);

final class _AbortClient extends http.BaseClient {
  _AbortClient(this.started);

  final Completer<void> started;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.Abortable;
    if (!started.isCompleted) {
      started.complete();
    }
    await abortable.abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}
