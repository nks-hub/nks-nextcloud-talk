import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  late AppDatabase database;
  late ChatRepository repository;
  late _CachedThreadSelectCounter queryCounter;

  setUp(() async {
    queryCounter = _CachedThreadSelectCounter();
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

  test('one reply batch reads all cached thread counts in one query', () async {
    const threadCount = 40;
    const firstThreadId = 1000;
    const stride = 10;
    final messages = <Map<String, Object?>>[];
    await database.batch((batch) {
      for (var index = 0; index < threadCount; index++) {
        final threadId = firstThreadId + (index * stride);
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
                message: 'Thread $threadId',
                isThread: true,
                threadReplies: 0,
              ),
            ),
          ),
        );
        messages.add(
          _messageJson(
            id: threadId + 1,
            threadId: threadId,
            message: 'Reply ${threadId + 1}',
            parent: _messageJson(
              id: threadId,
              threadId: threadId,
              message: 'Thread $threadId',
              isThread: true,
            ),
          ),
        );
      }
    });
    queryCounter.enabled = true;

    final response = _rootFutureResponse(messages);
    expect(
      await repository.applyChatGetResponse(response),
      ChatMergeOutcome.applied,
    );

    expect(queryCounter.threadCountSelects, 1);
    final roots =
        await (database.select(database.cachedChatMessages)..where(
              (row) =>
                  row.accountId.equals('account-a') &
                  row.roomToken.equals('rooma123') &
                  row.messageId.equalsExp(row.threadId),
            ))
            .get();
    expect(roots, hasLength(threadCount));
    for (final root in roots) {
      final wire = jsonDecode(root.rawJson) as Map<String, Object?>;
      expect(wire['threadReplies'], 1);
    }
  });
}

ChatGetResponse _rootFutureResponse(List<Map<String, Object?>> messages) {
  final lastGiven = messages.last['id']! as int;
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('thread-count-batch'),
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

Map<String, Object?> _messageJson({
  required int id,
  required int threadId,
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
    'threadId': threadId,
    'isThread': ?isThread,
    'threadReplies': ?threadReplies,
    'parent': ?parent,
  };
}

final class _CachedThreadSelectCounter extends QueryInterceptor {
  bool enabled = false;
  int threadCountSelects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    final sql = statement.toLowerCase();
    if (enabled &&
        sql.contains('from "cached_chat_messages"') &&
        sql.contains('"message_id"') &&
        sql.contains('"raw_json"') &&
        !sql.contains('"actor_type"')) {
      threadCountSelects++;
    }
    return super.runSelect(executor, statement, args);
  }
}
