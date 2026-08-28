import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late ChatRepository repository;

  setUp(() async {
    database = openTestDatabase();
    repository = ChatRepository(database);
    final accounts = AccountRepository(database);
    for (final account in const <({String id, String server})>[
      (id: 'account-a', server: 'https://cloud.example.invalid'),
      (id: 'account-b', server: 'https://other.example.invalid'),
    ]) {
      await accounts.upsertAccount(
        accountId: account.id,
        serverUrl: account.server,
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: DateTime.utc(2026, 1, 1),
      );
    }
    await repository.recordCapabilities(
      accountId: 'account-a',
      talkFeatures: const {'chat-v2', 'chat-replies'},
      observedAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  test('a cached reaction is not counted on a later recount', () async {
    // The first fix stopped a reaction from being counted as it arrived.
    // Reactions are cached like any other message, so a recount that reads
    // them back out of the database inflated the number again - which is
    // why a wrong "1 reply" survived on a device that had already synced.
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'root',
      threadId: null,
      cursor: 20,
    );
    await _insertMessage(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            messageId: 25,
            actorType: 'users',
            actorId: 'fixture-user',
            actorDisplayName: 'Fixture User',
            timestamp: 25,
            systemMessage: 'reaction',
            messageType: 'system',
            referenceId: 'reference-25',
            displayText: 'thumbs-up',
            deleted: false,
            threadId: const Value(20),
            rawJson: jsonEncode(
              _messageJson(id: 25, roomToken: 'rooma123', threadId: 20)
                ..['systemMessage'] = 'reaction',
            ),
          ),
        );

    expect(
      await repository.applyChatGetResponse(_threadReplyResponse()),
      ChatMergeOutcome.applied,
    );

    final row =
        await (database.select(database.cachedChatMessages)..where(
              (r) =>
                  r.accountId.equals('account-a') &
                  r.roomToken.equals('rooma123') &
                  r.messageId.equals(20),
            ))
            .getSingleOrNull();
    expect(row, isA<CachedChatMessage>());
    final wire = jsonDecode(row!.rawJson) as Map<String, Object?>;
    expect(
      wire['threadReplies'],
      1,
      reason: 'one real reply, and the cached reaction is not a second',
    );
  });

  test('a reaction does not turn into a thread reply', () async {
    // Talk delivers a reaction as a SYSTEM message that carries the thread it
    // belongs to. Counting those made a bubble claim "1 reply" the moment
    // somebody reacted to it - reported from a real device.
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'root',
      threadId: null,
      cursor: 20,
    );
    await _insertMessage(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
    );

    expect(
      await repository.applyChatGetResponse(_reactionResponse()),
      ChatMergeOutcome.applied,
    );

    final row =
        await (database.select(database.cachedChatMessages)..where(
              (r) =>
                  r.accountId.equals('account-a') &
                  r.roomToken.equals('rooma123') &
                  r.messageId.equals(20),
            ))
            .getSingleOrNull();
    expect(row, isA<CachedChatMessage>());
    final wire = jsonDecode(row!.rawJson) as Map<String, Object?>;
    expect(
      wire['threadReplies'],
      anyOf(equals(null), equals(0)),
      reason: 'a reaction is not a reply',
    );
  });


  test("someone else's reaction reaches the message it is about", () async {
    // The notice is stored like any other message, but nothing used to touch
    // the row it is about, so the pill only ever showed reactions this device
    // had added itself. Reproduced live 2026-08-28: the server confirmed both
    // reactions, the app showed none, not even after reopening the room.
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'root',
      threadId: null,
      cursor: 20,
    );
    await _insertMessage(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
    );

    expect(
      await repository.applyChatGetResponse(_reactionCountsResponse()),
      ChatMergeOutcome.applied,
    );

    final row =
        await (database.select(database.cachedChatMessages)..where(
              (r) =>
                  r.accountId.equals('account-a') &
                  r.roomToken.equals('rooma123') &
                  r.messageId.equals(20),
            ))
            .getSingle();
    final wire = jsonDecode(row.rawJson) as Map<String, Object?>;
    expect(wire['reactions'], {'👍': 2, '🔥': 1});
    expect(wire['reactionsSelf'], <String>['🔥']);
  });


  test('a silent send stays silent across a process restart', () async {
    // The whole point of the durable column: the flag lives with the
    // operation, not in the composer, so an outbox replayed after process
    // death cannot send loudly what the switch promised to send quietly.
    final operation = await repository.admitTextSend(
      accountId: 'account-a',
      roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
      authority: _silentAuthority(),
      operationId: ChatOperationId.parse(
        '11111111-1111-4111-8111-111111111111',
      ),
      referenceId: ChatReferenceId.parse(
        '22222222-2222-4222-8222-222222222222',
      ),
      message: 'Quiet one',
      silent: true,
    );
    expect(operation.silent, isTrue);

    // A fresh repository over the same file is what a restart looks like:
    // the flag has to come back off disk, not out of the object above.
    final restored = ChatRepository(database);
    final replayed = await restored
        .watchTextSendOperations(
          accountId: 'account-a',
          roomToken: 'rooma123',
        )
        .first;
    expect(replayed.single.silent, isTrue);
  });

  test('root merge projects only into the matching account and room', () async {
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'network-root',
      threadId: null,
      cursor: 20,
    );
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'root',
      threadId: null,
      cursor: 20,
    );
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'thread:20',
      threadId: 20,
      cursor: 20,
    );
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'roomb123',
      scopeKey: 'root',
      threadId: null,
      cursor: 777,
    );
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'roomb123',
      scopeKey: 'thread:20',
      threadId: 20,
      cursor: 777,
    );
    await _insertScope(
      database,
      accountId: 'account-b',
      roomToken: 'rooma123',
      scopeKey: 'root',
      threadId: null,
      cursor: 888,
    );
    await _insertScope(
      database,
      accountId: 'account-b',
      roomToken: 'rooma123',
      scopeKey: 'thread:20',
      threadId: 20,
      cursor: 888,
    );
    await _insertMessage(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
    );

    final response = _rootReplyResponse();
    expect(
      await repository.applyChatGetResponse(response),
      ChatMergeOutcome.applied,
    );

    final matchingRoot = await _scope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'root',
    );
    final matchingView = await _scope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'thread:20',
    );
    final otherRoomRoot = await _scope(
      database,
      accountId: 'account-a',
      roomToken: 'roomb123',
      scopeKey: 'root',
    );
    final otherRoomView = await _scope(
      database,
      accountId: 'account-a',
      roomToken: 'roomb123',
      scopeKey: 'thread:20',
    );
    final otherAccountRoot = await _scope(
      database,
      accountId: 'account-b',
      roomToken: 'rooma123',
      scopeKey: 'root',
    );
    final otherAccountView = await _scope(
      database,
      accountId: 'account-b',
      roomToken: 'rooma123',
      scopeKey: 'thread:20',
    );

    expect(matchingRoot.futureCursor, '30');
    expect(matchingView.futureCursor, '30');
    expect(jsonDecode(matchingView.blocksJson), [
      ['20', '30'],
    ]);
    expect(otherRoomRoot.futureCursor, '777');
    expect(otherRoomView.futureCursor, '777');
    expect(otherAccountRoot.futureCursor, '888');
    expect(otherAccountView.futureCursor, '888');
  });
}

Future<void> _insertScope(
  AppDatabase database, {
  required String accountId,
  required String roomToken,
  required String scopeKey,
  required int? threadId,
  required int cursor,
}) {
  return database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          scopeKey: scopeKey,
          threadId: Value(threadId),
          historyCursor: '$cursor',
          futureCursor: '$cursor',
          lastCommonRead: '0',
          lastReadMessage: 0,
          unreadMessages: 0,
          hasHistory: true,
          futureConverged: true,
          blocksJson: '[["$cursor","$cursor"]]',
        ),
      );
}

Future<void> _insertMessage(
  AppDatabase database, {
  required String accountId,
  required String roomToken,
}) {
  final raw = _messageJson(id: 20, roomToken: roomToken, threadId: null);
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          messageId: 20,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 20,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-20',
          displayText: 'Message 20',
          deleted: false,
          rawJson: jsonEncode(raw),
        ),
      );
}

ChatGetResponse _threadReplyResponse() {
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('projection-thread-reply'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
      'chat-v2',
      'chat-replies',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse('20'),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
  );
  final root = _messageJson(id: 20, roomToken: 'rooma123', threadId: 20)
    ..['isThread'] = true;
  final reply = _messageJson(id: 30, roomToken: 'rooma123', threadId: 20)
    ..['parent'] = root;
  return decodeChatGetResponse(
    request: request,
    statusCode: 200,
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': [reply],
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap(const {
      'X-Chat-Last-Given': '30',
      'X-Chat-Last-Common-Read': '0',
    }),
  );
}


ChatGetResponse _reactionCountsResponse() {
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('projection-reaction-counts'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
      'chat-v2',
      'chat-replies',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse('20'),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
  );
  // The parent a reaction notice carries is the reacted message with its
  // current tally, which is the only place those numbers ever arrive.
  final reacted = _messageJson(id: 20, roomToken: 'rooma123', threadId: null)
    ..['reactions'] = {'👍': 2, '🔥': 1}
    ..['reactionsSelf'] = <String>['🔥'];
  final notice = _messageJson(id: 32, roomToken: 'rooma123', threadId: null)
    ..['systemMessage'] = 'reaction'
    ..['message'] = 'thumbs-up'
    ..['parent'] = reacted;
  return decodeChatGetResponse(
    request: request,
    statusCode: 200,
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': [notice],
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap(const {
      'X-Chat-Last-Given': '32',
      'X-Chat-Last-Common-Read': '0',
    }),
  );
}

ChatGetResponse _reactionResponse() {
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('projection-reaction'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
      'chat-v2',
      'chat-replies',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse('20'),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
  );
  // The shape the server really sends: a system message that carries both
  // its thread and the full parent it reacted to. Without the parent the
  // reply accumulator never even looks at it, so a fixture missing it
  // passes whether or not the bug is fixed.
  final root = _messageJson(id: 20, roomToken: 'rooma123', threadId: 20)
    ..['isThread'] = true;
  final reaction = _messageJson(id: 31, roomToken: 'rooma123', threadId: 20)
    ..['systemMessage'] = 'reaction'
    ..['message'] = 'thumbs-up'
    ..['parent'] = root;
  return decodeChatGetResponse(
    request: request,
    statusCode: 200,
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': [reaction],
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap(const {
      'X-Chat-Last-Given': '31',
      'X-Chat-Last-Common-Read': '0',
    }),
  );
}

ChatGetResponse _rootReplyResponse() {
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('projection-isolation'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
      'chat-v2',
      'chat-replies',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse('20'),
    lastCommonRead: ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
  );
  return decodeChatGetResponse(
    request: request,
    statusCode: 200,
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': [_messageJson(id: 30, roomToken: 'rooma123', threadId: 20)],
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap(const {
      'X-Chat-Last-Given': '30',
      'X-Chat-Last-Common-Read': '0',
    }),
  );
}

Map<String, Object?> _messageJson({
  required int id,
  required String roomToken,
  required int? threadId,
}) {
  return <String, Object?>{
    'id': id,
    'token': roomToken,
    'actorType': 'users',
    'actorId': 'fixture-user',
    'actorDisplayName': 'Fixture User',
    'timestamp': id,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$id',
    'message': 'Message $id',
    'messageParameters': <String, Object?>{},
    'reactions': <String, Object?>{},
    'threadId': ?threadId,
  };
}

Future<StoredChatScope> _scope(
  AppDatabase database, {
  required String accountId,
  required String roomToken,
  required String scopeKey,
}) {
  return (database.select(database.chatScopes)..where(
        (row) =>
            row.accountId.equals(accountId) &
            row.roomToken.equals(roomToken) &
            row.scopeKey.equals(scopeKey),
      ))
      .getSingle();
}

ChatTextSendAuthority _silentAuthority() => ChatTextSendAuthority(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  capabilityGeneration: 1,
  profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
    'chat-v2',
    'chat-reference-id',
    'silent-send',
  ], federated: false),
  replayContractRevision: textSendReplayContractRevision,
);
