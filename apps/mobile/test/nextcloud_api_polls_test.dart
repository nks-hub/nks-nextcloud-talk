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
}

Map<String, Object?> _envelope({required int statusCode}) => {
  'ocs': {
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
