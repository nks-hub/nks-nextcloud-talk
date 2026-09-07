import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

final _account = AccountId.parse('poll-account');
final _requestId = ChatRequestId.parse('poll-operation');
final _server = ServerBase.parse('https://cloud.example.invalid/sub');
final _room = ConversationToken.parse('roomtoken', path: r'$.token');

void main() {
  test('draft operations use the stable paths and form bodies', () {
    final create = _create();
    expect(create.method, 'POST');
    expect(
      create.uri.path,
      '/sub/ocs/v2.php/apps/spreed/api/v1/poll/roomtoken',
    );
    expect(create.jsonBody, {
      'question': 'Lunch?',
      'options': ['Pizza', 'Salad'],
      'resultMode': 1,
      'maxVotes': 1,
      'draft': true,
    });
    final edit = _edit();
    expect(edit.method, 'POST');
    expect(edit.uri.path, endsWith('/poll/roomtoken/draft/7'));
    expect(
      edit.jsonBody.keys,
      unorderedEquals(['question', 'options', 'resultMode', 'maxVotes']),
    );
    final list = _list();
    expect(list.method, 'GET');
    expect(list.uri.path, endsWith('/poll/roomtoken/drafts'));
    expect(list.jsonBody, isNull);
    expect(_delete().method, 'DELETE');
    expect(_delete().uri.path, endsWith('/poll/roomtoken/7'));
    expect(_close().uri, _delete().uri);
  });

  test('draft gates distinguish feature and edit authority', () {
    for (final operation in <void Function()>[
      () => _create(drafts: false),
      () => _create(moderator: false),
      () => _list(drafts: false),
      () => _list(moderator: false),
      () => _delete(drafts: false),
      () => _delete(moderator: false),
      () => _edit(drafts: false),
      () => _edit(editing: false),
      () => _edit(allowed: false),
      () => _close(allowed: false),
      () => _delete(id: 0),
      () => _close(id: -1),
    ]) {
      expect(operation, throwsA(isA<TalkProtocolException>()));
    }
  });

  test('draft create and edit accept the reduced draft response', () {
    for (final request in [_create(), _edit()]) {
      final response = decodePollResponse(
        request: request,
        statusCode: 200,
        confirmedStatusCode: 200,
        body: _body(_poll()),
      );
      expect(response.classification, PollResponseClassification.confirmed);
      expect(response.poll!.status, PollStatus.draft);
      expect(response.poll!.votes, isEmpty);
      expect(response.poll!.numVoters, isNull);
    }
    expect(
      () => decodePollResponse(
        request: _edit(),
        statusCode: 200,
        confirmedStatusCode: 200,
        body: _body(_poll(id: 8)),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => decodePollResponse(
        request: _create(),
        statusCode: 201,
        confirmedStatusCode: 201,
        body: _body(_poll(status: 0), code: 201),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test(
    'using a draft creates a new normal poll without deleting the draft',
    () {
      final draft = TalkPoll.fromJson(_poll());
      final request = PollCreateRequest.fromDraft(
        accountId: _account,
        requestId: _requestId,
        server: _server,
        roomToken: _room,
        pollsAvailable: true,
        draftsAvailable: true,
        canPublishDraft: true,
        draft: draft,
        threadId: 42,
      );
      expect(request.jsonBody['draft'], false);
      expect(request.jsonBody['threadId'], 42);
      expect(request.jsonBody.containsKey('pollId'), false);
      expect(request.uri.path, endsWith('/poll/roomtoken'));
      expect(draft.status, PollStatus.draft);
      final response = decodePollResponse(
        request: request,
        statusCode: 201,
        confirmedStatusCode: 201,
        body: _body(_poll(id: 19, status: 0), code: 201),
      );
      expect(response.poll!.id, 19);
    },
  );

  test('draft reuse checks source status and fresh creation authority', () {
    for (final scenario in [
      (polls: false, drafts: true, allowed: true, status: 2),
      (polls: true, drafts: false, allowed: true, status: 2),
      (polls: true, drafts: true, allowed: false, status: 2),
      (polls: true, drafts: true, allowed: true, status: 0),
    ]) {
      expect(
        () => PollCreateRequest.fromDraft(
          accountId: _account,
          requestId: _requestId,
          server: _server,
          roomToken: _room,
          pollsAvailable: scenario.polls,
          draftsAvailable: scenario.drafts,
          canPublishDraft: scenario.allowed,
          draft: TalkPoll.fromJson(_poll(status: scenario.status)),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    }
  });

  test(
    'draft form validation bounds UTF-8 content, choices and vote count',
    () {
      for (final form in [
        (question: ' ', options: ['A', 'B'], maxVotes: 1),
        (question: 'é' * 16001, options: ['A', 'B'], maxVotes: 1),
        (question: 'Question', options: ['A'], maxVotes: 1),
        (question: 'Question', options: ['A', ' '], maxVotes: 1),
        (question: 'Question', options: ['A', 'B'], maxVotes: 3),
        (question: 'Question', options: ['A' * 60000, 'B'], maxVotes: 0),
      ]) {
        expect(
          () => PollDraftEditRequest(
            accountId: _account,
            requestId: _requestId,
            server: _server,
            roomToken: _room,
            pollsAvailable: true,
            draftsAvailable: true,
            editDraftAvailable: true,
            canEditDraft: true,
            pollId: 7,
            question: form.question,
            options: form.options,
            resultMode: PollResultMode.public,
            maxVotes: form.maxVotes,
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
    },
  );

  test(
    'draft listing rejects wrong status, duplicate ids and foreign shapes',
    () {
      final request = _list();
      PollDraftListResponse decode(Object? data) => decodePollDraftListResponse(
        request: request,
        statusCode: 200,
        body: _body(data),
      );
      expect(decode([]).drafts, isEmpty);
      expect(decode([_poll(), _poll(id: 8)]).drafts.map((p) => p.id), [7, 8]);
      for (final data in <Object?>[
        null,
        {},
        [_poll(), _poll()],
        [_poll(status: 0)],
        List.generate(1001, (index) => _poll(id: index + 1)),
      ]) {
        expect(() => decode(data), throwsA(isA<TalkProtocolException>()));
      }
    },
  );

  test('close and delete confirmations cannot be confused', () {
    final closed = decodePollResponse(
      request: _close(),
      statusCode: 200,
      confirmedStatusCode: 200,
      body: _body(_poll(status: 1)),
    );
    expect(closed.poll!.status, PollStatus.closed);
    final deleted = decodePollDraftDeleteResponse(
      request: _delete(),
      statusCode: 202,
      body: _body(null, code: 202),
    );
    expect(deleted.classification, PollResponseClassification.confirmed);
    expect(
      () => decodePollResponse(
        request: _close(),
        statusCode: 200,
        confirmedStatusCode: 200,
        body: _body(_poll()),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => decodePollResponse(
        request: _close(),
        statusCode: 202,
        confirmedStatusCode: 202,
        body: _body(null, code: 202),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => decodePollDraftDeleteResponse(
        request: _delete(),
        statusCode: 200,
        body: _body(_poll(status: 1)),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => decodePollDraftDeleteResponse(
        request: _delete(),
        statusCode: 202,
        body: _body({}, code: 202),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => decodePollDraftDeleteResponse(
        request: _delete(),
        statusCode: 202,
        body: _body(null, code: 200),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      decodePollResponse(
        request: _close(),
        statusCode: 400,
        confirmedStatusCode: 200,
        body: Uint8List(0),
      ).classification,
      PollResponseClassification.invalidInput,
    );
  });

  test('management parsers bound and validate successful OCS bodies', () {
    for (final body in [
      Uint8List(0),
      Uint8List(pollMaximumResponseBytes + 1),
      Uint8List.fromList([0xff]),
      Uint8List.fromList(
        utf8.encode(
          '{"ocs":{"meta":{"status":"ok",'
          '"statuscode":200,"statuscode":403},"data":[]}}',
        ),
      ),
      _body([], code: 403),
    ]) {
      expect(
        () => decodePollDraftListResponse(
          request: _list(),
          statusCode: 200,
          body: body,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    }
    final denied = decodePollDraftListResponse(
      request: _list(),
      statusCode: 403,
      body: Uint8List(0),
    );
    expect(denied.classification, PollResponseClassification.permissionDenied);
    expect(denied.drafts, isEmpty);
    expect(
      decodePollDraftDeleteResponse(
        request: _delete(),
        statusCode: 404,
        body: Uint8List(0),
      ).classification,
      PollResponseClassification.notFound,
    );
  });
}

PollDraftCreateRequest _create({bool drafts = true, bool moderator = true}) =>
    PollDraftCreateRequest(
      accountId: _account,
      requestId: _requestId,
      server: _server,
      roomToken: _room,
      pollsAvailable: true,
      draftsAvailable: drafts,
      isModerator: moderator,
      question: ' Lunch? ',
      options: [' Pizza ', ' Salad '],
      resultMode: PollResultMode.hiddenUntilClosed,
      maxVotes: 1,
    );

PollDraftEditRequest _edit({
  bool drafts = true,
  bool editing = true,
  bool allowed = true,
}) => PollDraftEditRequest(
  accountId: _account,
  requestId: _requestId,
  server: _server,
  roomToken: _room,
  pollsAvailable: true,
  draftsAvailable: drafts,
  editDraftAvailable: editing,
  canEditDraft: allowed,
  pollId: 7,
  question: 'Lunch?',
  options: ['Pizza', 'Salad'],
  resultMode: PollResultMode.hiddenUntilClosed,
  maxVotes: 1,
);

PollDraftListRequest _list({bool drafts = true, bool moderator = true}) =>
    PollDraftListRequest(
      accountId: _account,
      requestId: _requestId,
      server: _server,
      roomToken: _room,
      pollsAvailable: true,
      draftsAvailable: drafts,
      isModerator: moderator,
    );

PollDraftDeleteRequest _delete({
  bool drafts = true,
  bool moderator = true,
  int id = 7,
}) => PollDraftDeleteRequest(
  accountId: _account,
  requestId: _requestId,
  server: _server,
  roomToken: _room,
  pollsAvailable: true,
  draftsAvailable: drafts,
  isModerator: moderator,
  pollId: id,
);

PollCloseRequest _close({bool allowed = true, int id = 7}) => PollCloseRequest(
  accountId: _account,
  requestId: _requestId,
  server: _server,
  roomToken: _room,
  pollsAvailable: true,
  canClose: allowed,
  pollId: id,
);

Map<String, Object?> _poll({int id = 7, int status = 2}) => {
  'id': id,
  'question': 'Lunch?',
  'options': ['Pizza', 'Salad'],
  'actorType': 'users',
  'actorId': 'fixture-user',
  'actorDisplayName': 'Fixture User',
  'status': status,
  'resultMode': 1,
  'maxVotes': 1,
};

Uint8List _body(Object? data, {int code = 200}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'ocs': {
        'meta': {'status': 'ok', 'statuscode': code},
        'data': data,
      },
    }),
  ),
);
