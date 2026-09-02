import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/settings/reply_layout_preference.dart';
import 'package:nextcloudtalk/app_providers.dart';
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
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: 'account-a',
            token: 'rooma123',
            displayName: 'Room A',
            description: '',
            lastActivity: 1,
            unreadMessages: 0,
            favorite: false,
            rawJson: '{}',
          ),
        );
    await _insertMessages(database);
    await _insertOperations(database);
  });

  tearDown(() => database.close());

  test('root and two thread message streams stay isolated', () async {
    final root = await repository
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final thread20 = await repository
        .watchMessages(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 20,
        )
        .first;
    final thread30 = await repository
        .watchMessages(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 30,
        )
        .first;

    expect(root.map((message) => message.messageId), [10, 20, 30]);
    expect(thread20.map((message) => message.messageId), [20, 21]);
    expect(thread30.map((message) => message.messageId), [30, 31]);
  });

  test(
    'the inline reply layout keeps every reply in the room stream',
    () async {
      final inline = await repository
          .watchMessages(
            accountId: 'account-a',
            roomToken: 'rooma123',
            includeThreadReplies: true,
          )
          .first;
      final thread20 = await repository
          .watchMessages(
            accountId: 'account-a',
            roomToken: 'rooma123',
            threadId: 20,
            includeThreadReplies: true,
          )
          .first;

      expect(inline.map((message) => message.messageId), [10, 20, 21, 30, 31]);
      // A thread pane is still scoped to its own thread.
      expect(thread20.map((message) => message.messageId), [20, 21]);
    },
  );

  test(
    'runtime reconstruction excludes replies inside root ChatBlocks',
    () async {
      await database.delete(database.textSendOperations).go();
      await repository.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: const {'chat-v2', 'threads'},
        observedAt: DateTime.utc(2026, 1, 1),
      );
      await _insertScope(
        database,
        scopeKey: 'root',
        threadId: null,
        historyCursor: 10,
        futureCursor: 31,
      );
      await _insertScope(
        database,
        scopeKey: 'network-thread:20',
        threadId: 20,
        historyCursor: 20,
        futureCursor: 21,
      );

      final snapshot = await repository.loadRuntimeForTesting('account-a');
      final accountState = snapshot.accounts[AccountId.parse('account-a')]!;

      expect(
        accountState
            .scopes[ChatScopeKey(
              roomToken: ConversationToken.parse(
                'rooma123',
                path: r'$.roomToken',
              ),
              threadId: null,
            )]!
            .messageIds,
        [10, 20, 30],
      );
      expect(
        accountState
            .scopes[ChatScopeKey(
              roomToken: ConversationToken.parse(
                'rooma123',
                path: r'$.roomToken',
              ),
              threadId: 20,
            )]!
            .messageIds,
        [20, 21],
      );
    },
  );

  test(
    'embedded parent refreshes its thread original without leaking the reply '
    'into root',
    () async {
      await database.delete(database.textSendOperations).go();
      await repository.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: const {'chat-v2', 'threads'},
        observedAt: DateTime.utc(2026, 1, 1),
      );
      await _insertScope(
        database,
        scopeKey: 'root',
        threadId: null,
        historyCursor: 10,
        futureCursor: 31,
      );
      await _insertScope(
        database,
        scopeKey: 'network-thread:20',
        threadId: 20,
        historyCursor: 20,
        futureCursor: 21,
      );
      await AccountRepository(database).upsertAccount(
        accountId: 'account-b',
        serverUrl: 'https://other.example.invalid',
        loginName: 'fixture-other',
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: DateTime.utc(2026, 1, 2),
      );
      await _insertCachedThreadMessage(
        database,
        accountId: 'account-b',
        roomToken: 'rooma123',
        messageId: 90,
        threadId: 20,
      );
      await _insertCachedThreadMessage(
        database,
        accountId: 'account-a',
        roomToken: 'otherroom',
        messageId: 91,
        threadId: 20,
      );
      await (database.update(database.cachedChatMessages)..where(
            (row) =>
                row.accountId.equals('account-a') &
                row.roomToken.equals('rooma123') &
                row.messageId.equals(20),
          ))
          .write(
            CachedChatMessagesCompanion(
              rawJson: Value(
                jsonEncode(
                  _chatMessageJson(
                    id: 20,
                    threadId: 20,
                    message: 'Original before reply',
                    isThread: true,
                    threadReplies: 0,
                  ),
                ),
              ),
            ),
          );

      final request = ChatFetchRequest(
        accountId: AccountId.parse('account-a'),
        requestId: ChatRequestId.parse('embedded-parent-refresh'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
          'chat-v2',
          'threads',
        ], federated: false),
        direction: ChatFetchDirection.future,
        cursor: ChatCursor.parse('21'),
        lastCommonRead: ChatCursor.parse('0'),
        limit: 200,
        includeLastKnown: false,
        timeoutSeconds: 0,
        interactive: true,
        threadId: 20,
      );
      final response = decodeChatGetResponse(
        request: request,
        statusCode: 200,
        body: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
                'data': [
                  _chatMessageJson(
                    id: 32,
                    threadId: 20,
                    message: 'Thread reply',
                    parent: _chatMessageJson(
                      id: 20,
                      threadId: 20,
                      message: 'Original after reply',
                      isThread: true,
                      threadReplies: 7,
                    ),
                  ),
                ],
              },
            }),
          ),
        ),
        headers: ChatResponseHeaders.fromMap(const {
          'X-Chat-Last-Given': '32',
          'X-Chat-Last-Common-Read': '0',
        }),
      );
      final embeddedParent = response.messages.single.parent as ChatFullParent;
      expect(embeddedParent.messageId, 20);
      expect(embeddedParent.message.threadReplies, 7);

      expect(
        await repository.applyChatGetResponse(response),
        ChatMergeOutcome.applied,
      );

      final storedOriginal =
          await (database.select(database.cachedChatMessages)..where(
                (row) =>
                    row.accountId.equals('account-a') &
                    row.roomToken.equals('rooma123') &
                    row.messageId.equals(20),
              ))
              .getSingle();
      final refreshedOriginal = ChatMessage.fromJson(
        jsonDecode(storedOriginal.rawJson),
      );
      expect(refreshedOriginal.threadReplies, 7);
      expect(refreshedOriginal.message, 'Original after reply');
      expect(storedOriginal.threadId, 20);
      expect(storedOriginal.displayText, 'Original after reply');

      final rootMessages = await repository
          .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      final threadMessages = await repository
          .watchMessages(
            accountId: 'account-a',
            roomToken: 'rooma123',
            threadId: 20,
          )
          .first;
      expect(rootMessages.map((message) => message.messageId), [10, 20, 30]);
      expect(threadMessages.map((message) => message.messageId), [20, 21, 32]);

      final snapshot = await repository.loadRuntimeForTesting('account-a');
      final accountState = snapshot.accounts[AccountId.parse('account-a')]!;
      final rootScope =
          accountState.scopes[ChatScopeKey(
            roomToken: ConversationToken.parse(
              'rooma123',
              path: r'$.roomToken',
            ),
            threadId: null,
          )]!;
      final threadScope =
          accountState.scopes[ChatScopeKey(
            roomToken: ConversationToken.parse(
              'rooma123',
              path: r'$.roomToken',
            ),
            threadId: 20,
          )]!;
      expect(rootScope.messageIds, [10, 20, 30]);
      expect(rootScope.futureCursor.value, '31');
      expect(threadScope.messageIds, [20, 21, 32]);
      expect(threadScope.futureCursor.value, '32');
    },
  );

  test(
    'embedded parent fallback is order-independent for mixed replies',
    () async {
      await database.delete(database.textSendOperations).go();
      await repository.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: const {'chat-v2', 'threads'},
        observedAt: DateTime.utc(2026, 1, 1),
      );
      await _insertScope(
        database,
        scopeKey: 'network-thread:20',
        threadId: 20,
        historyCursor: 20,
        futureCursor: 21,
      );
      await (database.update(database.cachedChatMessages)..where(
            (row) =>
                row.accountId.equals('account-a') &
                row.roomToken.equals('rooma123') &
                row.messageId.equals(20),
          ))
          .write(
            CachedChatMessagesCompanion(
              displayText: const Value('Original before reply'),
              rawJson: Value(
                jsonEncode(
                  _chatMessageJson(
                    id: 20,
                    threadId: 20,
                    message: 'Original before reply',
                    isThread: true,
                    threadReplies: 3,
                  ),
                ),
              ),
            ),
          );

      final replay = _threadFutureResponse(
        requestId: 'derived-parent-reply-replay',
        cursor: ChatCursor.parse('21'),
        lastGiven: 21,
        messages: [
          _chatMessageJson(
            id: 21,
            threadId: 20,
            message: 'Repeated thread reply',
            parent:
                _chatMessageJson(
                    id: 20,
                    threadId: 20,
                    message: 'Original after replay',
                    isThread: true,
                  )
                  ..['actorDisplayName'] = 'Parent after replay'
                  ..['metaData'] = {'fixture': 'replay'},
          ),
        ],
      );
      final embeddedParent = replay.messages.single.parent as ChatFullParent;
      expect(embeddedParent.message.threadReplies, isNull);
      expect(
        await repository.applyChatGetResponse(replay),
        ChatMergeOutcome.applied,
      );

      var storedOriginal =
          await (database.select(database.cachedChatMessages)..where(
                (row) =>
                    row.accountId.equals('account-a') &
                    row.roomToken.equals('rooma123') &
                    row.messageId.equals(20),
              ))
              .getSingle();
      var refreshedOriginal = ChatMessage.fromJson(
        jsonDecode(storedOriginal.rawJson),
      );
      expect(refreshedOriginal.threadReplies, 3);
      expect(refreshedOriginal.message, 'Original after replay');
      expect(refreshedOriginal.metadata['fixture'], 'replay');
      expect(storedOriginal.actorDisplayName, 'Parent after replay');

      final response = _threadFutureResponse(
        requestId: 'derived-parent-reply-batch',
        cursor: ChatCursor.parse('21'),
        lastGiven: 35,
        messages: [
          _chatMessageJson(
            id: 32,
            threadId: 20,
            message: 'Thread reply 1',
            parent:
                _chatMessageJson(
                    id: 20,
                    threadId: 20,
                    message: 'Original after reply 1',
                    isThread: true,
                  )
                  ..['actorDisplayName'] = 'Parent after reply 1'
                  ..['metaData'] = {'fixture': 'reply-1'},
          ),
          _chatMessageJson(
            id: 33,
            threadId: 20,
            message: 'Thread reply 2',
            parent:
                _chatMessageJson(
                    id: 20,
                    threadId: 20,
                    message: 'Original after reply 2',
                    isThread: true,
                  )
                  ..['actorDisplayName'] = 'Parent after reply 2'
                  ..['metaData'] = {'fixture': 'reply-2'},
          ),
          _chatMessageJson(
            id: 34,
            threadId: 20,
            message: 'Thread reply without a parent',
          ),
          _chatMessageJson(
            id: 35,
            threadId: 20,
            message: 'Thread reply with a mismatched parent',
            parent: _chatMessageJson(
              id: 20,
              threadId: 30,
              message: 'Mismatched parent',
              isThread: true,
            ),
          ),
        ],
      );
      expect(
        (response.messages[0].parent as ChatFullParent).message.threadReplies,
        isNull,
      );
      expect(
        (response.messages[1].parent as ChatFullParent).message.threadReplies,
        isNull,
      );
      expect(response.messages[2].parent, isNull);
      expect(
        await repository.applyChatGetResponse(response),
        ChatMergeOutcome.applied,
      );

      storedOriginal =
          await (database.select(database.cachedChatMessages)..where(
                (row) =>
                    row.accountId.equals('account-a') &
                    row.roomToken.equals('rooma123') &
                    row.messageId.equals(20),
              ))
              .getSingle();
      refreshedOriginal = ChatMessage.fromJson(
        jsonDecode(storedOriginal.rawJson),
      );
      expect(refreshedOriginal.threadReplies, 5);
      expect(refreshedOriginal.message, 'Original after reply 2');
      expect(refreshedOriginal.metadata['fixture'], 'reply-2');
      expect(storedOriginal.actorDisplayName, 'Parent after reply 2');
      expect(storedOriginal.displayText, 'Original after reply 2');
    },
  );

  test(
    'embedded parent with a mismatched thread id does not replace the cached '
    'thread original',
    () async {
      await database.delete(database.textSendOperations).go();
      await repository.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: const {'chat-v2', 'threads'},
        observedAt: DateTime.utc(2026, 1, 1),
      );
      await _insertScope(
        database,
        scopeKey: 'root',
        threadId: null,
        historyCursor: 10,
        futureCursor: 31,
      );
      await _insertScope(
        database,
        scopeKey: 'network-thread:20',
        threadId: 20,
        historyCursor: 20,
        futureCursor: 21,
      );
      await (database.update(database.cachedChatMessages)..where(
            (row) =>
                row.accountId.equals('account-a') &
                row.roomToken.equals('rooma123') &
                row.messageId.equals(20),
          ))
          .write(
            CachedChatMessagesCompanion(
              displayText: const Value('Original before reply'),
              rawJson: Value(
                jsonEncode(
                  _chatMessageJson(
                    id: 20,
                    threadId: 20,
                    message: 'Original before reply',
                    isThread: true,
                    threadReplies: 0,
                  ),
                ),
              ),
            ),
          );

      final request = ChatFetchRequest(
        accountId: AccountId.parse('account-a'),
        requestId: ChatRequestId.parse('mismatched-parent-thread'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
          'chat-v2',
          'threads',
        ], federated: false),
        direction: ChatFetchDirection.future,
        cursor: ChatCursor.parse('21'),
        lastCommonRead: ChatCursor.parse('0'),
        limit: 200,
        includeLastKnown: false,
        timeoutSeconds: 0,
        interactive: true,
        threadId: 20,
      );
      final response = decodeChatGetResponse(
        request: request,
        statusCode: 200,
        body: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
                'data': [
                  _chatMessageJson(
                    id: 32,
                    threadId: 20,
                    message: 'Thread reply',
                    parent: _chatMessageJson(
                      id: 20,
                      threadId: 30,
                      message: 'Mismatched parent',
                      isThread: true,
                      threadReplies: 2,
                    ),
                  ),
                ],
              },
            }),
          ),
        ),
        headers: ChatResponseHeaders.fromMap(const {
          'X-Chat-Last-Given': '32',
          'X-Chat-Last-Common-Read': '0',
        }),
      );

      expect(
        await repository.applyChatGetResponse(response),
        ChatMergeOutcome.applied,
      );

      final storedOriginal =
          await (database.select(database.cachedChatMessages)..where(
                (row) =>
                    row.accountId.equals('account-a') &
                    row.roomToken.equals('rooma123') &
                    row.messageId.equals(20),
              ))
              .getSingle();
      final original = ChatMessage.fromJson(jsonDecode(storedOriginal.rawJson));
      expect(storedOriginal.threadId, 20);
      expect(storedOriginal.displayText, 'Original before reply');
      expect(original.threadId, 20);
      expect(original.threadReplies, 0);
      expect(original.message, 'Original before reply');

      final snapshot = await repository.loadRuntimeForTesting('account-a');
      final threadScope =
          snapshot.accounts[AccountId.parse('account-a')]!.scopes[ChatScopeKey(
            roomToken: ConversationToken.parse(
              'rooma123',
              path: r'$.roomToken',
            ),
            threadId: 20,
          )]!;
      expect(threadScope.messageIds, [20, 21, 32]);
      expect(threadScope.futureCursor.value, '32');
    },
  );

  test('room errors remain isolated between root and thread scopes', () async {
    await _insertScope(
      database,
      scopeKey: 'root',
      threadId: null,
      historyCursor: 10,
      futureCursor: 31,
    );
    await _insertScope(
      database,
      scopeKey: 'thread:20',
      threadId: 20,
      historyCursor: 20,
      futureCursor: 21,
    );

    await repository.recordRoomError(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 20,
      errorCode: 'network',
    );

    var scopes = await database.select(database.chatScopes).get();
    expect(
      scopes.singleWhere((scope) => scope.scopeKey == 'root').lastSyncError,
      isNull,
    );
    expect(
      scopes
          .singleWhere((scope) => scope.scopeKey == 'thread:20')
          .lastSyncError,
      'network',
    );

    await repository.recordRoomError(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: null,
      errorCode: 'invalidResponse',
    );

    scopes = await database.select(database.chatScopes).get();
    expect(
      scopes.singleWhere((scope) => scope.scopeKey == 'root').lastSyncError,
      'invalidResponse',
    );
    expect(
      scopes
          .singleWhere((scope) => scope.scopeKey == 'thread:20')
          .lastSyncError,
      'network',
    );
  });

  test('provider keys isolate cached messages and pending sends', () async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    const rootKey = (
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: null,
    );
    const thread20Key = (
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 20,
    );
    const thread30Key = (
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 30,
    );

    final rootMessages = await container.read(
      chatMessagesProvider(rootKey).future,
    );
    final thread20Messages = await container.read(
      chatMessagesProvider(thread20Key).future,
    );
    final thread30Messages = await container.read(
      chatMessagesProvider(thread30Key).future,
    );
    final rootOperations = await container.read(
      textSendOperationsProvider(rootKey).future,
    );
    final thread20Operations = await container.read(
      textSendOperationsProvider(thread20Key).future,
    );
    final thread30Operations = await container.read(
      textSendOperationsProvider(thread30Key).future,
    );

    // The default reply layout keeps replies in the room, so the root stream
    // carries them; a thread key is still scoped to its own thread.
    expect(rootMessages.map((message) => message.messageId), [
      10,
      20,
      21,
      30,
      31,
    ]);
    expect(thread20Messages.map((message) => message.messageId), [20, 21]);
    expect(thread30Messages.map((message) => message.messageId), [30, 31]);
    expect(rootOperations.map((operation) => operation.operationId), [
      '00000000-0000-4000-8000-000000000001',
    ]);
    expect(thread20Operations.map((operation) => operation.operationId), [
      '00000000-0000-4000-8000-000000000002',
    ]);
    expect(thread30Operations, isEmpty);

    // Switching to the thread layout takes the replies back out of the room.
    await container
        .read(replyLayoutProvider.notifier)
        .setReplyLayout(ReplyLayout.thread);
    final threadedRoot = await container.read(
      chatMessagesProvider(rootKey).future,
    );
    expect(threadedRoot.map((message) => message.messageId), [10, 20, 30]);
  });
}

Future<void> _insertMessages(AppDatabase database) async {
  for (final message in <({int id, int? threadId})>[
    (id: 10, threadId: null),
    (id: 20, threadId: 20),
    (id: 21, threadId: 20),
    (id: 30, threadId: 30),
    (id: 31, threadId: 30),
  ]) {
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            messageId: message.id,
            actorType: 'users',
            actorId: 'fixture-user',
            actorDisplayName: 'Fixture User',
            timestamp: message.id,
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'reference-${message.id}',
            displayText: 'Message ${message.id}',
            deleted: false,
            threadId: Value(message.threadId),
            rawJson: '{}',
          ),
        );
  }
}

Future<void> _insertOperations(AppDatabase database) async {
  for (final operation in <({String id, int sequence, int? replyTo})>[
    (id: '00000000-0000-4000-8000-000000000001', sequence: 1, replyTo: null),
    (id: '00000000-0000-4000-8000-000000000002', sequence: 2, replyTo: 20),
  ]) {
    await database
        .into(database.textSendOperations)
        .insert(
          TextSendOperationsCompanion.insert(
            accountId: 'account-a',
            operationId: operation.id,
            roomToken: 'rooma123',
            referenceId: operation.id,
            message: 'Pending ${operation.id}',
            replayContractRevision: 'fixture-revision',
            enqueueSequence: operation.sequence,
            outboxState: 'queued',
            attemptCount: 0,
            messageIdsJson: '[]',
            replyTo: Value(operation.replyTo),
            duplicateRiskAcknowledged: false,
            createdAtMillis: operation.sequence,
            updatedAtMillis: operation.sequence,
          ),
        );
  }
}

ChatGetResponse _threadFutureResponse({
  required String requestId,
  required ChatCursor cursor,
  required int lastGiven,
  required List<Map<String, Object?>> messages,
}) {
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse(requestId),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
      'chat-v2',
      'threads',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: cursor,
    lastCommonRead: ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
    threadId: 20,
  );
  return decodeChatGetResponse(
    request: request,
    statusCode: 200,
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': messages,
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap({
      'X-Chat-Last-Given': '$lastGiven',
      'X-Chat-Last-Common-Read': '0',
    }),
  );
}

Future<void> _insertCachedThreadMessage(
  AppDatabase database, {
  required String accountId,
  required String roomToken,
  required int messageId,
  required int threadId,
}) {
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          messageId: messageId,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: messageId,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-$messageId',
          displayText: 'Message $messageId',
          deleted: false,
          threadId: Value(threadId),
          rawJson: '{}',
        ),
      );
}

Map<String, Object?> _chatMessageJson({
  required int id,
  required int? threadId,
  required String message,
  bool? isThread,
  int? threadReplies,
  Map<String, Object?>? parent,
}) {
  return {
    'id': id,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'fixture-user',
    'actorDisplayName': 'Fixture User',
    'timestamp': id,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$id',
    'message': message,
    'messageParameters': <String, Object?>{},
    'reactions': <String, Object?>{},
    'threadId': ?threadId,
    'isThread': ?isThread,
    'threadReplies': ?threadReplies,
    'parent': ?parent,
  };
}

Future<void> _insertScope(
  AppDatabase database, {
  required String scopeKey,
  required int? threadId,
  required int historyCursor,
  required int futureCursor,
}) {
  return database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          scopeKey: scopeKey,
          threadId: Value(threadId),
          historyCursor: '$historyCursor',
          futureCursor: '$futureCursor',
          lastCommonRead: '0',
          lastReadMessage: 0,
          unreadMessages: 0,
          hasHistory: true,
          futureConverged: true,
          blocksJson: '[["$historyCursor","$futureCursor"]]',
        ),
      );
}
