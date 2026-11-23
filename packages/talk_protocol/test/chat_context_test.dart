import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

/// A context fetch caches the messages around one old message without moving
/// the scope's cursors, so paging still continues where it left off and the
/// fetched range stays a separate block until history reaches it.
void main() {
  final room = ConversationToken.parse('rooma123', path: r'$.roomToken');
  final account = AccountId.parse('account-a');
  final server = ServerBase.parse('https://cloud.example.invalid');
  final profile = ChatCapabilityProfile.fromTalkFeatures(const <String>[
    'chat-v2',
    'chat-get-context',
    'threads',
  ], federated: false);

  ChatContextRequest request({int messageId = 50, int? threadId}) =>
      ChatContextRequest(
        accountId: account,
        requestId: ChatRequestId.parse('context-request'),
        server: server,
        roomToken: room,
        profile: profile,
        messageId: messageId,
        limit: 100,
        threadId: threadId,
      );

  ChatRuntimeSnapshot snapshot() => ChatRuntimeSnapshot(
    accounts: {
      account: ChatAccountState(
        accountId: account,
        server: server,
        lane: ChatAccountLane.ready,
        credentialGeneration: 1,
        capabilityGeneration: 1,
        scopes: {
          ChatScopeKey(roomToken: room, threadId: null): ChatScopeState(
            messageIds: const <int>[1000, 1001],
            historyCursor: _cursor(1000),
            futureCursor: _cursor(1100),
            lastCommonRead: _cursor(1100),
            lastReadMessage: 1100,
            unreadMessages: 0,
            hasHistory: true,
            futureConverged: true,
            blocks: <ChatBlock>[
              ChatBlock(start: _cursor(1000), end: _cursor(1100)),
            ],
          ),
        },
        operations: const {},
      ),
    },
  );

  test('asks for the messages around one id, with no read side effects', () {
    final uri = request(threadId: 7).uri;
    expect(uri.path, '/ocs/v2.php/apps/spreed/api/v1/chat/rooma123/50/context');
    expect(uri.queryParameters, <String, String>{
      'format': 'json',
      'limit': '100',
      'threadId': '7',
    });
  });

  test('is refused without the chat-get-context capability', () {
    expect(
      () => ChatContextRequest(
        accountId: account,
        requestId: ChatRequestId.parse('context-request'),
        server: server,
        roomToken: room,
        profile: ChatCapabilityProfile.fromTalkFeatures(const <String>[
          'chat-v2',
        ], federated: false),
        messageId: 50,
        limit: 100,
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('decodes the oldest-first answer the server sends', () {
    final response = _decode(request(), ids: [48, 49, 50, 52], lastGiven: 53);
    expect(response.classification, ChatGetClassification.messages);
    expect(response.messages.map((message) => message.messageId), [
      48,
      49,
      50,
      52,
    ]);
    expect(response.lastGiven, _cursor(53));
  });

  test('rejects an answer out of order or ending past its last-given id', () {
    expect(
      () => _decode(request(), ids: [50, 49], lastGiven: 50),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => _decode(request(), ids: [49, 50], lastGiven: 49),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('adds the fetched range as an island and leaves the cursors alone', () {
    final source = snapshot();
    final result = planChatContextMerge(
      source,
      _decode(request(), ids: [40, 45, 50, 60], lastGiven: 62),
    );

    expect(result.outcome, ChatMergeOutcome.applied);
    final plan = result.plan!;
    expect(plan.island, ChatBlock(start: _cursor(40), end: _cursor(62)));
    expect(plan.messageUpserts.map((message) => message.messageId), [
      40,
      45,
      50,
      60,
    ]);
    final scope = plan
        .commit(source)
        .accounts[account]!
        .scopes[ChatScopeKey(roomToken: room, threadId: null)]!;
    expect(scope.historyCursor, _cursor(1000));
    expect(scope.futureCursor, _cursor(1100));
    expect(scope.hasHistory, isTrue);
    expect(scope.blocks, [ChatBlock(start: _cursor(1000), end: _cursor(1100))]);
    expect(scope.messageIds, [1000, 1001]);

    // How a view combines it with what it already shows: a far island stays
    // apart from the newest block, while an overlapping or adjacent one joins.
    final newest = ChatBlock(start: _cursor(1000), end: _cursor(1100));
    expect(mergeChatBlocks([newest, plan.island!]), [plan.island, newest]);
    expect(
      mergeChatBlocks([
        newest,
        ChatBlock(start: _cursor(55), end: _cursor(90)),
        plan.island!,
      ]),
      [ChatBlock(start: _cursor(40), end: _cursor(90)), newest],
    );
    expect(
      mergeChatBlocks([
        newest,
        ChatBlock(start: _cursor(950), end: _cursor(999)),
      ]),
      [ChatBlock(start: _cursor(950), end: _cursor(1100))],
    );
  });

  test('an island reaching the oldest history joins it', () {
    final source = snapshot();
    final plan = planChatContextMerge(
      source,
      _decode(request(messageId: 950), ids: [900, 950, 999], lastGiven: 999),
    ).plan!;
    expect(plan.islandJoined, isTrue);
    final scope = plan
        .commit(source)
        .accounts[account]!
        .scopes[ChatScopeKey(roomToken: room, threadId: null)]!;
    expect(scope.historyCursor, _cursor(900));
    expect(scope.blocks, [ChatBlock(start: _cursor(900), end: _cursor(1100))]);
    expect(scope.futureCursor, _cursor(1100));
  });

  group('a page from an island edge', () {
    final island = ChatBlock(start: _cursor(40), end: _cursor(62));
    ChatFetchRequest page(ChatFetchDirection direction, int cursor) =>
        ChatFetchRequest(
          accountId: account,
          requestId: ChatRequestId.parse('island-page'),
          server: server,
          roomToken: room,
          profile: profile,
          direction: direction,
          cursor: _cursor(cursor),
          lastCommonRead: _cursor(0),
          limit: 100,
          includeLastKnown: false,
          timeoutSeconds: 0,
          interactive: true,
        );
    ChatGetResponse answer(
      ChatFetchRequest request,
      List<int> ids,
      int lastGiven,
    ) => decodeChatGetResponse(
      request: request,
      statusCode: 200,
      body: _ocs([for (final id in ids) _messageWire(id)]),
      headers: ChatResponseHeaders.fromMap(<String, String>{
        'X-Chat-Last-Given': '$lastGiven',
      }),
    );

    test('grows the island older and newer, scope untouched', () {
      final source = snapshot();
      final older = planChatIslandPageMerge(
        source,
        answer(page(ChatFetchDirection.history, 40), [39, 35, 31], 30),
        island,
      ).plan!;
      expect(older.island, ChatBlock(start: _cursor(30), end: _cursor(62)));
      expect(older.islandJoined, isFalse);
      expect(older.messageUpserts, hasLength(3));
      final newer = planChatIslandPageMerge(
        source,
        answer(page(ChatFetchDirection.future, 62), [63, 70], 71),
        island,
      ).plan!;
      expect(newer.island, ChatBlock(start: _cursor(40), end: _cursor(71)));
      final scope = newer
          .commit(source)
          .accounts[account]!
          .scopes[ChatScopeKey(roomToken: room, threadId: null)]!;
      expect(scope.historyCursor, _cursor(1000));
      expect(scope.blocks, [
        ChatBlock(start: _cursor(1000), end: _cursor(1100)),
      ]);
    });

    test('joins the history once the newer page reaches it', () {
      final source = snapshot();
      final plan = planChatIslandPageMerge(
        source,
        answer(page(ChatFetchDirection.future, 62), [63, 999, 1000], 1000),
        island,
      ).plan!;
      expect(plan.islandJoined, isTrue);
      final scope = plan
          .commit(source)
          .accounts[account]!
          .scopes[ChatScopeKey(roomToken: room, threadId: null)]!;
      expect(scope.historyCursor, _cursor(40));
      expect(scope.blocks, [ChatBlock(start: _cursor(40), end: _cursor(1100))]);
    });

    test('an empty answer says the edge is the end, a moved edge is stale', () {
      final empty = planChatIslandPageMerge(
        snapshot(),
        decodeChatGetResponse(
          request: page(ChatFetchDirection.history, 40),
          statusCode: 304,
          body: Uint8List(0),
        ),
        island,
      );
      expect(empty.outcome, ChatMergeOutcome.historyExhausted);
      expect(empty.plan, isNull);
      final stale = planChatIslandPageMerge(
        snapshot(),
        answer(page(ChatFetchDirection.history, 41), [39], 39),
        island,
      );
      expect(stale.outcome, ChatMergeOutcome.stale);
    });
  });

  test('plans nothing for an empty answer or an unknown scope', () {
    final empty = planChatContextMerge(
      snapshot(),
      decodeChatContextResponse(
        request: request(),
        statusCode: 304,
        body: Uint8List(0),
      ),
    );
    expect(empty.outcome, ChatMergeOutcome.stale);
    expect(empty.plan, isNull);

    final unknownScope = planChatContextMerge(
      snapshot(),
      _decode(request(threadId: 7), ids: [50], lastGiven: 50, threadId: 7),
    );
    expect(unknownScope.outcome, ChatMergeOutcome.rejected);
    expect(unknownScope.plan, isNull);
  });

  test('reads a 503 from a proxy as a transient failure', () {
    final response = decodeChatContextResponse(
      request: request(),
      statusCode: 503,
      body: Uint8List.fromList(utf8.encode('<html>Service Unavailable</html>')),
    );
    expect(response.classification, ChatGetClassification.transientError);
  });

  test('moves the account to re-login on a 401', () {
    final source = snapshot();
    final result = planChatContextMerge(
      source,
      decodeChatContextResponse(
        request: request(),
        statusCode: 401,
        body: _ocs(const <Object?>[], status: 'failure', code: 401),
      ),
    );
    expect(result.outcome, ChatMergeOutcome.reauthenticationRequired);
    expect(result.plan!.island, isNull);
    expect(
      result.plan!.commit(source).accounts[account]!.lane,
      ChatAccountLane.reauthenticationRequired,
    );
  });
}

Map<String, Object?> _messageWire(int id, {int? threadId}) => <String, Object?>{
  'id': id,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'someone-else',
  'actorDisplayName': 'Other person',
  'timestamp': 1724300000 + id,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-$id',
  'message': 'Message $id',
  'messageParameters': <String, Object?>{},
  'markdown': false,
  'reactions': <String, Object?>{},
  'threadId': ?threadId,
};

ChatContextResponse _decode(
  ChatContextRequest request, {
  required List<int> ids,
  required int lastGiven,
  int? threadId,
}) => decodeChatContextResponse(
  request: request,
  statusCode: 200,
  body: _ocs([
    for (final id in ids)
      <String, Object?>{
        'id': id,
        'token': 'rooma123',
        'actorType': 'users',
        'actorId': 'someone-else',
        'actorDisplayName': 'Other person',
        'timestamp': 1724300000 + id,
        'systemMessage': '',
        'messageType': 'comment',
        'isReplyable': true,
        'referenceId': 'reference-$id',
        'message': 'Message $id',
        'messageParameters': <String, Object?>{},
        'markdown': false,
        'reactions': <String, Object?>{},
        'threadId': ?threadId,
      },
  ]),
  headers: ChatResponseHeaders.fromMap(<String, String>{
    'X-Chat-Last-Given': '$lastGiven',
  }),
);

Uint8List _ocs(List<Object?> data, {String status = 'ok', int code = 200}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': status,
              'statuscode': code,
              'message': '',
            },
            'data': data,
          },
        }),
      ),
    );

ChatCursor _cursor(int value) => ChatCursor.parse(value.toString());
