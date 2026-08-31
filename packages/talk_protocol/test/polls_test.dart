import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final accountId = AccountId.parse('poll-account');
  final room = ConversationToken.parse('roomtoken', path: r'$.token');

  test('create request is capability and room scoped', () {
    final request = PollCreateRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('poll-request'),
      server: server,
      roomToken: room,
      pollsAvailable: true,
      question: ' Lunch? ',
      options: const [' Pizza ', ' Salad '],
      resultMode: PollResultMode.public,
      maxVotes: 1,
      threadId: 42,
    );

    expect(
      request.uri.toString(),
      'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v1/'
      'poll/roomtoken?format=json',
    );
    expect(request.jsonBody, {
      'question': 'Lunch?',
      'options': ['Pizza', 'Salad'],
      'resultMode': 0,
      'maxVotes': 1,
      'draft': false,
      'threadId': 42,
    });
    expect(request.headers['OCS-APIRequest'], 'true');
  });

  test('request fails closed without talk-polls capability', () {
    expect(
      () => PollCreateRequest(
        accountId: accountId,
        requestId: ChatRequestId.parse('poll-request'),
        server: server,
        roomToken: room,
        pollsAvailable: false,
        question: 'Lunch?',
        options: const ['Pizza', 'Salad'],
        resultMode: PollResultMode.public,
        maxVotes: 1,
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.path,
          'path',
          r'$.capabilities.talk-polls',
        ),
      ),
    );
  });

  test('decodes confirmed create and binds vote response to poll id', () {
    final create = PollCreateRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('poll-create'),
      server: server,
      roomToken: room,
      pollsAvailable: true,
      question: 'Lunch?',
      options: const ['Pizza', 'Salad'],
      resultMode: PollResultMode.public,
      maxVotes: 1,
    );
    final created = decodePollResponse(
      request: create,
      statusCode: 201,
      confirmedStatusCode: 201,
      body: _body(_pollEnvelope(statusCode: 201)),
    );
    expect(created.poll?.id, 7);
    expect(created.poll?.options, ['Pizza', 'Salad']);

    final vote = PollVoteRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('poll-vote'),
      server: server,
      roomToken: room,
      pollsAvailable: true,
      pollId: 8,
      optionIds: const [0],
    );
    expect(
      () => decodePollResponse(
        request: vote,
        statusCode: 200,
        confirmedStatusCode: 200,
        body: _body(_pollEnvelope(statusCode: 200)),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('service failure is classified without parsing an error body', () {
    final request = PollVoteRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('poll-vote'),
      server: server,
      roomToken: room,
      pollsAvailable: true,
      pollId: 7,
      optionIds: const [1],
    );
    final response = decodePollResponse(
      request: request,
      statusCode: 503,
      confirmedStatusCode: 200,
      body: Uint8List(0),
    );
    expect(
      response.classification,
      PollResponseClassification.serviceUnavailable,
    );
  });

  test('accepts upstream hidden votes [] and rejects a non-empty list', () {
    final hidden = Map<String, Object?>.from(_pollEnvelope(statusCode: 200));
    final hiddenPoll =
        ((hidden['ocs'] as Map<String, Object?>)['data']
            as Map<String, Object?>);
    hiddenPoll['votes'] = <Object?>[];
    expect(TalkPoll.fromJson(hiddenPoll).votes, isEmpty);

    hiddenPoll['votes'] = <Object?>[1];
    expect(
      () => TalkPoll.fromJson(hiddenPoll),
      throwsA(
        isA<TalkProtocolException>().having(
          (error) => error.path,
          'path',
          r'$.ocs.data.votes',
        ),
      ),
    );
  });

  test('show request is GET and binds the returned poll id', () {
    final request = PollShowRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('poll-show'),
      server: server,
      roomToken: room,
      pollsAvailable: true,
      pollId: 7,
    );
    expect(request.method, 'GET');
    expect(request.jsonBody, isNull);
    expect(
      decodePollResponse(
        request: request,
        statusCode: 200,
        confirmedStatusCode: 200,
        body: _body(_pollEnvelope(statusCode: 200)),
      ).poll?.id,
      7,
    );
  });
}

Uint8List _body(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, Object?> _pollEnvelope({required int statusCode}) => {
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
      'votedSelf': <int>[],
      'votes': <Object?>[],
      'numVoters': 0,
    },
  },
};
