import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('foreground chat polling', () {
    test('starts with catch-up and then polls from the committed cursor', () {
      var snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );

      final initial = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-initial'),
        nowMilliseconds: 1000,
      )!;
      expect(initial.request.timeoutSeconds, 0);
      expect(initial.request.cursor.value, '109');
      expect(initial.request.direction, ChatFetchDirection.future);
      expect(initial.request.includeLastKnown, isFalse);
      session = initial.commit(session);

      final response = decodeChatGetResponse(
        request: initial.request,
        statusCode: 200,
        body: _fixtureBytes('chat-future.response.json'),
        headers: ChatResponseHeaders.fromMap(const {
          'X-Chat-Last-Given': '112',
          'X-Chat-Last-Common-Read': '100',
        }),
      );
      final completion = completeChatForegroundPollHttp(
        snapshot,
        session,
        response: response,
        nowMilliseconds: 1000,
        jitterPermille: 500,
      );
      final committed = completion.commit(snapshot, session);
      snapshot = committed.snapshot;
      session = committed.session;

      final scope = snapshot.accounts[_accountA]!.scopes[_scope()]!;
      expect(scope.futureCursor.value, '112');
      expect(scope.messageIds, <int>[109, 110, 112]);
      expect(scope.blocks, <ChatBlock>[
        ChatBlock(start: ChatCursor.parse('109'), end: ChatCursor.parse('112')),
      ]);

      final longPoll = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-long'),
        nowMilliseconds: 1001,
      )!;
      expect(longPoll.request.timeoutSeconds, 30);
      expect(longPoll.request.cursor.value, '112');
    });

    test('304 enables long polling without advancing the cursor', () {
      var snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );
      final initial = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-304'),
        nowMilliseconds: 0,
      )!;
      session = initial.commit(session);

      final completion = completeChatForegroundPollHttp(
        snapshot,
        session,
        response: decodeChatGetResponse(
          request: initial.request,
          statusCode: 304,
          body: Uint8List(0),
        ),
        nowMilliseconds: 0,
        jitterPermille: 500,
      );
      final committed = completion.commit(snapshot, session);
      snapshot = committed.snapshot;
      session = committed.session;

      expect(
        snapshot.accounts[_accountA]!.scopes[_scope()]!.futureCursor.value,
        '109',
      );
      expect(session.phase, ChatForegroundPollPhase.longPollRequired);
      expect(
        planNextChatForegroundPoll(
          snapshot,
          session,
          requestId: ChatRequestId.parse('poll-after-304'),
          nowMilliseconds: 1,
        )!.request.timeoutSeconds,
        30,
      );
    });

    test('binds polling independently to account room and thread', () {
      final snapshot = _snapshot(withThread: true, withSecondAccount: true);
      final session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: 55,
        profile: _profile(withThreads: true),
      );
      final request = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-thread'),
        nowMilliseconds: 0,
      )!.request;

      expect(request.threadId, 55);
      expect(request.cursor.value, '205');
      expect(request.accountId, _accountA);
      expect(request.server, _serverA);
      expect(
        () => startChatForegroundPoll(
          snapshot,
          accountId: _accountA,
          server: _serverB,
          roomToken: _room,
          threadId: 55,
          profile: _profile(withThreads: true),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('401 enters reauthentication without scheduling a retry', () {
      final snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );
      final requestPlan = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-reauth'),
        nowMilliseconds: 0,
      )!;
      session = requestPlan.commit(session);

      final completion = completeChatForegroundPollHttp(
        snapshot,
        session,
        response: decodeChatGetResponse(
          request: requestPlan.request,
          statusCode: 401,
          body: _ocsBody(const <Object?>[]),
        ),
        nowMilliseconds: 0,
        jitterPermille: 500,
      );
      final committed = completion.commit(snapshot, session);

      expect(
        completion.outcome,
        ChatForegroundPollOutcome.reauthenticationRequired,
      );
      expect(
        committed.session.phase,
        ChatForegroundPollPhase.reauthenticationRequired,
      );
      expect(committed.session.nextAttemptAtMilliseconds, isNull);
      expect(
        committed.snapshot.accounts[_accountA]!.lane,
        ChatAccountLane.reauthenticationRequired,
      );
      expect(
        planNextChatForegroundPoll(
          committed.snapshot,
          committed.session,
          requestId: ChatRequestId.parse('poll-no-reauth-loop'),
          nowMilliseconds: 100000,
        ),
        isNull,
      );
    });

    test('transport failure uses bounded jitter and preserves poll mode', () {
      final snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );
      final requestPlan = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-failure'),
        nowMilliseconds: 1000,
      )!;
      session = requestPlan.commit(session);

      final failure = completeChatForegroundPollTransportFailure(
        snapshot,
        session,
        nowMilliseconds: 1000,
        jitterPermille: 0,
      );
      final committed = failure.commit(snapshot, session);
      expect(failure.outcome, ChatForegroundPollOutcome.retryScheduled);
      expect(committed.session.nextAttemptAtMilliseconds, 1800);
      expect(
        planNextChatForegroundPoll(
          snapshot,
          committed.session,
          requestId: ChatRequestId.parse('poll-too-early'),
          nowMilliseconds: 1799,
        ),
        isNull,
      );
      final retry = planNextChatForegroundPoll(
        snapshot,
        committed.session,
        requestId: ChatRequestId.parse('poll-retry'),
        nowMilliseconds: 1800,
      )!;
      expect(retry.request.timeoutSeconds, 0);

      expect(
        chatForegroundPollBackoffMilliseconds(99, jitterPermille: 1000),
        36000,
      );
    });

    test('HTTP 503 uses the same bounded retry as a transport failure', () {
      final snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );
      final requestPlan = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-503'),
        nowMilliseconds: 2000,
      )!;
      session = requestPlan.commit(session);

      final failure = completeChatForegroundPollHttp(
        snapshot,
        session,
        response: decodeChatGetResponse(
          request: requestPlan.request,
          statusCode: 503,
          body: _ocsBody(const <Object?>[]),
        ),
        nowMilliseconds: 2000,
        jitterPermille: 1000,
      );
      final committed = failure.commit(snapshot, session);

      expect(failure.outcome, ChatForegroundPollOutcome.retryScheduled);
      expect(committed.session.phase, ChatForegroundPollPhase.waitingToRetry);
      expect(committed.session.nextAttemptAtMilliseconds, 3200);
      expect(committed.snapshot, same(snapshot));
    });

    test('HTTP 412 lobby waits with the retry backoff and changes nothing', () {
      // Measured live 2026-09-03: a lobby answered every poll with 412 and the
      // pane showed "latest chat response was rejected" next to the lobby
      // notice. The room is closed, not broken.
      final snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );
      final requestPlan = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-412'),
        nowMilliseconds: 2000,
      )!;
      session = requestPlan.commit(session);

      final response = decodeChatGetResponse(
        request: requestPlan.request,
        statusCode: 412,
        body: _ocsBody(const <Object?>[]),
      );
      expect(response.classification, ChatGetClassification.lobby);
      expect(
        planChatGetMerge(snapshot, response).outcome,
        ChatMergeOutcome.lobby,
      );

      final completion = completeChatForegroundPollHttp(
        snapshot,
        session,
        response: response,
        nowMilliseconds: 2000,
        jitterPermille: 1000,
      );
      final committed = completion.commit(snapshot, session);
      expect(completion.outcome, ChatForegroundPollOutcome.retryScheduled);
      expect(committed.session.phase, ChatForegroundPollPhase.waitingToRetry);
      expect(committed.snapshot, same(snapshot));
    });

    test('long-poll retry keeps the 30 second server timeout', () {
      final snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );
      final catchUp = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-catch-up'),
        nowMilliseconds: 0,
      )!;
      session = catchUp.commit(session);
      final catchUpCompletion = completeChatForegroundPollHttp(
        snapshot,
        session,
        response: decodeChatGetResponse(
          request: catchUp.request,
          statusCode: 304,
          body: Uint8List(0),
        ),
        nowMilliseconds: 0,
        jitterPermille: 500,
      ).commit(snapshot, session);
      session = catchUpCompletion.session;

      final longPoll = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-long-failure'),
        nowMilliseconds: 1,
      )!;
      expect(longPoll.request.timeoutSeconds, 30);
      session = longPoll.commit(session);
      final failure = completeChatForegroundPollTransportFailure(
        snapshot,
        session,
        nowMilliseconds: 1000,
        jitterPermille: 500,
      ).commit(snapshot, session);

      final retry = planNextChatForegroundPoll(
        snapshot,
        failure.session,
        requestId: ChatRequestId.parse('poll-long-retry'),
        nowMilliseconds: 2000,
      )!;
      expect(retry.request.timeoutSeconds, 30);
      expect(retry.request.cursor.value, '109');
    });

    test('rejects a second request while one is in flight', () {
      final snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );
      final requestPlan = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-single-flight'),
        nowMilliseconds: 0,
      )!;
      session = requestPlan.commit(session);

      expect(
        planNextChatForegroundPoll(
          snapshot,
          session,
          requestId: ChatRequestId.parse('poll-overlap'),
          nowMilliseconds: 1,
        ),
        isNull,
      );
    });

    test('rejects completion after cursor or generation changes', () {
      final snapshot = _snapshot();
      var session = startChatForegroundPoll(
        snapshot,
        accountId: _accountA,
        server: _serverA,
        roomToken: _room,
        threadId: null,
        profile: _profile(),
      );
      final requestPlan = planNextChatForegroundPoll(
        snapshot,
        session,
        requestId: ChatRequestId.parse('poll-stale'),
        nowMilliseconds: 0,
      )!;
      session = requestPlan.commit(session);
      final response = decodeChatGetResponse(
        request: requestPlan.request,
        statusCode: 304,
        body: Uint8List(0),
      );
      final account = snapshot.accounts[_accountA]!;
      final advancedScope = account.scopes[_scope()]!.copyWith(
        futureCursor: ChatCursor.parse('110'),
        blocks: <ChatBlock>[
          ChatBlock(
            start: ChatCursor.parse('109'),
            end: ChatCursor.parse('110'),
          ),
        ],
      );
      final advancedSnapshot = snapshot.replaceAccount(
        account.copyWith(
          scopes: <ChatScopeKey, ChatScopeState>{
            ...account.scopes,
            _scope(): advancedScope,
          },
        ),
      );
      final refreshedSnapshot = snapshot.replaceAccount(
        account.copyWith(capabilityGeneration: 2),
      );

      expect(
        () => completeChatForegroundPollHttp(
          advancedSnapshot,
          session,
          response: response,
          nowMilliseconds: 0,
          jitterPermille: 500,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => completeChatForegroundPollHttp(
          refreshedSnapshot,
          session,
          response: response,
          nowMilliseconds: 0,
          jitterPermille: 500,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test(
      'lifecycle cancellation is terminal and stale completion is rejected',
      () {
        final snapshot = _snapshot();
        var session = startChatForegroundPoll(
          snapshot,
          accountId: _accountA,
          server: _serverA,
          roomToken: _room,
          threadId: null,
          profile: _profile(),
        );
        final requestPlan = planNextChatForegroundPoll(
          snapshot,
          session,
          requestId: ChatRequestId.parse('poll-cancel'),
          nowMilliseconds: 0,
        )!;
        session = requestPlan.commit(session);
        final cancelled = cancelChatForegroundPoll(session);

        expect(cancelled.phase, ChatForegroundPollPhase.stopped);
        expect(cancelled.pendingRequest, isNull);
        expect(cancelled.consecutiveFailures, 0);
        expect(
          planNextChatForegroundPoll(
            snapshot,
            cancelled,
            requestId: ChatRequestId.parse('poll-after-cancel'),
            nowMilliseconds: 999999,
          ),
          isNull,
        );
        expect(
          () => completeChatForegroundPollHttp(
            snapshot,
            cancelled,
            response: decodeChatGetResponse(
              request: requestPlan.request,
              statusCode: 304,
              body: Uint8List(0),
            ),
            nowMilliseconds: 0,
            jitterPermille: 500,
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      },
    );
  });
}

final _accountA = AccountId.parse('poll-account-a');
final _accountB = AccountId.parse('poll-account-b');
final _serverA = ServerBase.parse('https://a.example.invalid');
final _serverB = ServerBase.parse('https://b.example.invalid');
final _room = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidChatState,
);

ChatScopeKey _scope({int? threadId}) =>
    ChatScopeKey(roomToken: _room, threadId: threadId);

ChatCapabilityProfile _profile({bool withThreads = false}) =>
    ChatCapabilityProfile.fromTalkFeatures(<Object?>[
      'chat-v2',
      if (withThreads) 'threads',
    ], federated: false);

ChatRuntimeSnapshot _snapshot({
  bool withThread = false,
  bool withSecondAccount = false,
}) {
  final scopes = <ChatScopeKey, ChatScopeState>{
    _scope(): _scopeState('109'),
    if (withThread) _scope(threadId: 55): _scopeState('205'),
  };
  final accounts = <AccountId, ChatAccountState>{
    _accountA: _account(_accountA, _serverA, scopes),
    if (withSecondAccount)
      _accountB: _account(_accountB, _serverB, <ChatScopeKey, ChatScopeState>{
        _scope(): _scopeState('999'),
      }),
  };
  return ChatRuntimeSnapshot(accounts: accounts);
}

ChatAccountState _account(
  AccountId accountId,
  ServerBase server,
  Map<ChatScopeKey, ChatScopeState> scopes,
) => ChatAccountState(
  accountId: accountId,
  server: server,
  lane: ChatAccountLane.ready,
  credentialGeneration: 1,
  capabilityGeneration: 1,
  scopes: scopes,
  operations: const {},
);

ChatScopeState _scopeState(String cursor) {
  final parsed = ChatCursor.parse(cursor);
  return ChatScopeState(
    messageIds: <int>[int.parse(cursor)],
    historyCursor: parsed,
    futureCursor: parsed,
    lastCommonRead: ChatCursor.parse('100'),
    lastReadMessage: int.parse(cursor),
    unreadMessages: 0,
    hasHistory: true,
    futureConverged: false,
    blocks: <ChatBlock>[ChatBlock(start: parsed, end: parsed)],
  );
}

Uint8List _fixtureBytes(String filename) => File(
  '${_repoRoot().path}/contracts/chat-messages/fixtures/$filename',
).readAsBytesSync();

Uint8List _ocsBody(Object? data) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'failure',
          'statuscode': 401,
          'message': 'Authentication required',
        },
        'data': data,
      },
    }),
  ),
);

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/chat-messages/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
