import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final accountId = AccountId.parse('account-a');
  final room = ConversationToken.parse('roomtoken', path: r'$.token');

  test(
    'create poll sends bounded JSON and decodes server confirmation',
    () async {
      late http.Request sent;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode(_envelope(statusCode: 201)), 201);
        }),
      );
      addTearDown(api.close);
      final response = await api.createPoll(
        pollRequest: PollCreateRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('create-poll'),
          server: server,
          roomToken: room,
          pollsAvailable: true,
          question: 'Lunch?',
          options: const ['Pizza', 'Salad'],
          resultMode: PollResultMode.public,
          maxVotes: 1,
        ),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );

      expect(sent.method, 'POST');
      expect(sent.url.path, endsWith('/poll/roomtoken'));
      expect(sent.headers['OCS-APIRequest'], 'true');
      expect(sent.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(sent.body), containsPair('draft', false));
      expect(response.poll?.id, 7);
    },
  );

  test('vote sends optionIds exactly once', () async {
    var calls = 0;
    late Map<String, Object?> body;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        calls++;
        body = (jsonDecode(request.body) as Map).cast<String, Object?>();
        return http.Response(jsonEncode(_envelope(statusCode: 200)), 200);
      }),
    );
    addTearDown(api.close);
    await api.votePoll(
      pollRequest: PollVoteRequest(
        accountId: accountId,
        requestId: ChatRequestId.parse('vote-poll'),
        server: server,
        roomToken: room,
        pollsAvailable: true,
        pollId: 7,
        optionIds: const [1],
      ),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );

    expect(calls, 1);
    expect(body, {
      'optionIds': [1],
    });
  });

  test('show poll is a bodyless bounded GET', () async {
    late http.Request sent;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        sent = request;
        return http.Response(jsonEncode(_envelope(statusCode: 200)), 200);
      }),
    );
    addTearDown(api.close);
    final response = await api.getPoll(
      pollRequest: PollShowRequest(
        accountId: accountId,
        requestId: ChatRequestId.parse('show-poll'),
        server: server,
        roomToken: room,
        pollsAvailable: true,
        pollId: 7,
      ),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );

    expect(sent.method, 'GET');
    expect(sent.body, isEmpty);
    expect(sent.headers['content-type'], isNull);
    expect(response.poll?.id, 7);
  });

  test(
    'management routes distinguish closed polls, draft lists and 202 deletion',
    () async {
      final sent = <http.Request>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          sent.add(request);
          final envelope = _envelope(statusCode: 200);
          final data = ((envelope['ocs'] as Map)['data'] as Map)
            ..['status'] = 2;
          if (request.url.path.endsWith('/drafts')) {
            (envelope['ocs'] as Map)['data'] = [data];
          } else if (request.method == 'DELETE' &&
              request.url.path.endsWith('/8')) {
            (envelope['ocs'] as Map)['data'] = null;
            ((envelope['ocs'] as Map)['meta'] as Map)['statuscode'] = 202;
            return http.Response(jsonEncode(envelope), 202);
          } else if (request.method == 'DELETE') {
            data['status'] = 1;
          }
          return http.Response(jsonEncode(envelope), 200);
        }),
      );
      addTearDown(api.close);
      final closed = await api.closePoll(
        pollRequest: PollCloseRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('close'),
          server: server,
          roomToken: room,
          pollsAvailable: true,
          pollId: 7,
          canClose: true,
        ),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      expect(closed.poll?.status, PollStatus.closed);
      final created = await api.createPollDraft(
        pollRequest: PollDraftCreateRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('draft'),
          server: server,
          roomToken: room,
          pollsAvailable: true,
          draftsAvailable: true,
          isModerator: true,
          question: 'Lunch?',
          options: ['A', 'B'],
          resultMode: PollResultMode.public,
          maxVotes: 1,
        ),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      expect(created.poll?.status, PollStatus.draft);
      expect((jsonDecode(sent.last.body) as Map)['draft'], isTrue);
      await api.editPollDraft(
        pollRequest: PollDraftEditRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('edit'),
          server: server,
          roomToken: room,
          pollsAvailable: true,
          draftsAvailable: true,
          editDraftAvailable: true,
          canEditDraft: true,
          pollId: 7,
          question: 'Lunch?',
          options: ['A', 'B'],
          resultMode: PollResultMode.public,
          maxVotes: 1,
        ),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      expect(sent.last.url.path, endsWith('/draft/7'));
      final drafts = await api.getPollDrafts(
        pollRequest: PollDraftListRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('list'),
          server: server,
          roomToken: room,
          pollsAvailable: true,
          draftsAvailable: true,
          isModerator: true,
        ),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      expect(drafts.drafts.single.status, PollStatus.draft);
      final deleted = await api.deletePollDraft(
        pollRequest: PollDraftDeleteRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('delete'),
          server: server,
          roomToken: room,
          pollsAvailable: true,
          draftsAvailable: true,
          isModerator: true,
          pollId: 8,
        ),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      );
      expect(deleted.classification, PollResponseClassification.confirmed);
      expect(sent.map((r) => r.method), [
        'DELETE',
        'POST',
        'POST',
        'GET',
        'DELETE',
      ]);
    },
  );

  PollExportRequest exportRequest(PollExportFormat format) => PollExportRequest(
    accountId: accountId,
    requestId: ChatRequestId.parse('export'),
    server: server,
    roomToken: room,
    pollsAvailable: true,
    pollId: 7,
    format: format,
    canExport: true,
  );

  for (final format in PollExportFormat.values) {
    test(
      'export preserves ${format.name} bytes and uses a safe filename',
      () async {
        final bytes = format == PollExportFormat.csv
            ? utf8.encode('Choice,Votes\r\nA,1\r\n')
            : [0x50, 0x4b, 3, 4, 0, 0xff, 0x80];
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            expect(request.method, 'GET');
            expect(request.followRedirects, isFalse);
            expect(request.headers['Accept'], format.mimeType);
            return http.Response.bytes(
              bytes,
              200,
              headers: {
                'content-type': format.mimeType,
                'content-disposition':
                    'attachment; filename="../../unsafe.exe"',
              },
            );
          }),
        );
        addTearDown(api.close);
        final result = await api.exportPoll(
          pollRequest: exportRequest(format),
          loginName: 'fixture-user',
          appPassword: 'fixture-password',
        );
        expect(result.bytes, bytes);
        expect(result.fileName, 'poll-7.${format.name}');
      },
    );
  }

  test('export refuses bodies over its ten MiB bound', () async {
    final api = HttpNextcloudApi(
      client: MockClient(
        (_) async => http.Response.bytes(
          List.filled(pollMaximumExportBytes + 1, 65),
          200,
          headers: {'content-type': 'text/csv'},
        ),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.exportPoll(
        pollRequest: exportRequest(PollExportFormat.csv),
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

  test(
    'export keeps authorization and missing-poll failures distinct',
    () async {
      final statuses = {
        401: PollResponseClassification.reauthenticationRequired,
        403: PollResponseClassification.permissionDenied,
        404: PollResponseClassification.notFound,
        429: PollResponseClassification.rateLimited,
      };
      for (final entry in statuses.entries) {
        final api = HttpNextcloudApi(
          client: MockClient(
            (_) async => http.Response('not a spreadsheet', entry.key),
          ),
        );
        final result = await api.exportPoll(
          pollRequest: exportRequest(PollExportFormat.csv),
          loginName: 'fixture-user',
          appPassword: 'fixture-password',
        );
        expect(result.classification, entry.value);
        expect(result.bytes, isNull);
        api.close();
      }
    },
  );

  test(
    'a stalled export completes at its deadline and aborts the request',
    () async {
      final stalled = StreamController<List<int>>();
      final requestAborted = Completer<void>();
      final api = HttpNextcloudApi(
        requestTimeout: const Duration(milliseconds: 40),
        client: MockClient.streaming((request, _) async {
          (request as http.Abortable).abortTrigger!.then(
            (_) => requestAborted.complete(),
          );
          return http.StreamedResponse(
            stalled.stream,
            200,
            headers: {'content-type': 'text/csv'},
          );
        }),
      );
      addTearDown(() async {
        api.close();
        await stalled.close();
      });
      await expectLater(
        api
            .exportPoll(
              pollRequest: exportRequest(PollExportFormat.csv),
              loginName: 'fixture-user',
              appPassword: 'fixture-password',
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(
          isA<NextcloudApiException>().having(
            (e) => e.code,
            'code',
            NextcloudApiError.timeout,
          ),
        ),
      );
      await requestAborted.future.timeout(const Duration(seconds: 1));
    },
  );
  test('slow progress cannot extend the overall export deadline', () async {
    Timer? feeding;
    late StreamController<List<int>> body;
    body = StreamController<List<int>>(
      onListen: () {
        feeding = Timer.periodic(const Duration(milliseconds: 5), (timer) {
          body.add([65]);
          if (timer.tick == 40) {
            timer.cancel();
            unawaited(body.close());
          }
        });
      },
      onCancel: () => feeding?.cancel(),
    );
    final api = HttpNextcloudApi(
      requestTimeout: const Duration(milliseconds: 40),
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          body.stream,
          200,
          headers: {'content-type': 'text/csv'},
        ),
      ),
    );
    addTearDown(() async {
      api.close();
      feeding?.cancel();
      await body.close();
    });
    await expectLater(
      api.exportPoll(
        pollRequest: exportRequest(PollExportFormat.csv),
        loginName: 'fixture-user',
        appPassword: 'fixture-password',
      ),
      throwsA(
        isA<NextcloudApiException>().having(
          (e) => e.code,
          'code',
          NextcloudApiError.timeout,
        ),
      ),
    );
  });
}

Map<String, Object?> _envelope({required int statusCode}) => {
  'ocs': <String, Object?>{
    'meta': {'status': 'ok', 'statuscode': statusCode},
    'data': {
      'id': 7,
      'question': 'Lunch?',
      'options': ['Pizza', 'Salad'],
      'actorType': 'users',
      'actorId': 'fixture-user',
      'actorDisplayName': 'Fixture User',
      'status': 0,
      'resultMode': 0,
      'maxVotes': 1,
      'votedSelf': [1],
      'votes': statusCode == 201 ? <Object?>[] : {'option-1': 1},
      'numVoters': 1,
    },
  },
};
