import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  late AppDatabase database;
  late ChatRepository repository;
  late _SingleRootSelectCounter queryCounter;

  setUp(() async {
    queryCounter = _SingleRootSelectCounter();
    database = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(queryCounter),
    );
    repository = ChatRepository(database);
    await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await repository.recordCapabilities(
      accountId: 'account-a',
      talkFeatures: const {'chat-v2', 'threads'},
      observedAt: DateTime.utc(2026, 1, 1),
    );
    await database
        .into(database.chatScopes)
        .insert(
          ChatScopesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            scopeKey: 'network-root',
            historyCursor: '0',
            futureCursor: '0',
            lastCommonRead: '0',
            lastReadMessage: 0,
            unreadMessages: 0,
            hasHistory: true,
            futureConverged: true,
            blocksJson: '[["0","0"]]',
          ),
        );
  });

  tearDown(() => database.close());

  test('root projection does not select each cached thread root', () async {
    const threadCount = 40;
    const firstThreadId = 1000;
    await database.batch((batch) {
      for (var index = 0; index < threadCount; index++) {
        final threadId = firstThreadId + index;
        final named = index.isOdd;
        batch.insert(
          database.chatScopes,
          ChatScopesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            scopeKey: 'thread:$threadId',
            threadId: Value(threadId),
            historyCursor: '$threadId',
            futureCursor: '$threadId',
            lastCommonRead: '0',
            lastReadMessage: 0,
            unreadMessages: 0,
            hasHistory: true,
            futureConverged: true,
            blocksJson: '[["$threadId","$threadId"]]',
          ),
        );
        batch.insert(
          database.cachedChatMessages,
          CachedChatMessagesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            messageId: threadId,
            actorType: 'users',
            actorId: 'fixture-user',
            actorDisplayName: 'Fixture User',
            timestamp: threadId,
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'reference-$threadId',
            displayText: 'Thread $threadId',
            deleted: false,
            threadId: Value(threadId),
            rawJson: jsonEncode(
              _messageJson(
                id: threadId,
                threadId: threadId,
                isThread: named,
                threadTitle: named ? 'Named thread $threadId' : null,
              ),
            ),
          ),
        );
      }
    });
    queryCounter.enabled = true;

    expect(
      await repository.applyChatGetResponse(_rootFutureResponse()),
      ChatMergeOutcome.applied,
    );

    expect(queryCounter.singleRootSelects, 0);
    expect(queryCounter.directScopeInserts, 0);
    expect(queryCounter.scopeBatchExecutions, 2);
    final scopes =
        await (database.select(database.chatScopes)..where(
              (row) =>
                  row.accountId.equals('account-a') &
                  row.roomToken.equals('rooma123') &
                  row.threadId.isNotNull(),
            ))
            .get();
    expect(scopes, hasLength(threadCount));
    for (final scope in scopes) {
      expect(
        scope.futureCursor,
        scope.threadId!.isEven ? '9000' : '${scope.threadId}',
      );
    }
  });
}

ChatGetResponse _rootFutureResponse() {
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('root-view-projection'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
      'chat-v2',
      'threads',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse('0'),
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
            'data': [_messageJson(id: 9000)],
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap({
      'X-Chat-Last-Given': '9000',
      'X-Chat-Last-Common-Read': '0',
    }),
  );
}

Map<String, Object?> _messageJson({
  required int id,
  int? threadId,
  bool? isThread,
  String? threadTitle,
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
    'message': 'Message $id',
    'messageParameters': <String, Object?>{},
    'reactions': <String, Object?>{},
    'threadId': ?threadId,
    'isThread': ?isThread,
    'threadTitle': ?threadTitle,
  };
}

final class _SingleRootSelectCounter extends QueryInterceptor {
  bool enabled = false;
  int singleRootSelects = 0;
  int directScopeInserts = 0;
  int scopeBatchExecutions = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    final sql = statement.toLowerCase();
    if (enabled &&
        sql.contains('from "cached_chat_messages"') &&
        RegExp(r'"message_id"\s*=\s*\?').hasMatch(sql)) {
      singleRootSelects++;
    }
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    if (enabled &&
        statements.statements.any(
          (statement) => statement.toLowerCase().contains('into "chat_scopes"'),
        )) {
      scopeBatchExecutions++;
    }
    return super.runBatched(executor, statements);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (enabled && statement.toLowerCase().contains('into "chat_scopes"')) {
      directScopeInserts++;
    }
    return super.runInsert(executor, statement, args);
  }
}
