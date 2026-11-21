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
  late _ParentUpdateCounter writes;

  setUp(() async {
    writes = _ParentUpdateCounter();
    database = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(writes),
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
      talkFeatures: const {'chat-v2'},
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

  test('mutation projects into quoted parents as one batch', () async {
    const quoteCount = 40;
    final original = _messageWire(id: 20, message: 'Original message');
    await database.batch((batch) {
      batch.insert(database.cachedChatMessages, _messageCompanion(original));
      for (var index = 0; index < quoteCount; index++) {
        final quote = _messageWire(id: 100 + index, message: 'Quote $index')
          ..['parent'] = original;
        batch.insert(database.cachedChatMessages, _messageCompanion(quote));
      }
    });
    writes.enabled = true;
    final edited = ChatMessage.fromJson(
      _messageWire(id: 20, message: 'Edited message'),
    );

    await repository.applyMessageMutation(
      accountId: 'account-a',
      server: ServerBase.parse('https://cloud.example.invalid'),
      message: edited,
    );

    expect(writes.directParentUpdates, 0);
    expect(writes.parentBatchExecutions, 1);
    final rows = await (database.select(
      database.cachedChatMessages,
    )..where((row) => row.messageId.isBiggerOrEqualValue(100))).get();
    expect(rows, hasLength(quoteCount));
    expect(
      rows.every((row) {
        final message = ChatMessage.fromJson(jsonDecode(row.rawJson));
        final parent = message.parent;
        return parent is ChatFullParent &&
            parent.message.message == 'Edited message';
      }),
      isTrue,
    );
  });

  test('a page of mutations reads quoted parents together', () async {
    const mutationCount = 40;
    await database.batch((batch) {
      for (var index = 0; index < mutationCount; index++) {
        final original = _messageWire(
          id: 1000 + index,
          message: 'Original $index',
        );
        final quote = _messageWire(id: 2000 + index, message: 'Quote $index')
          ..['parent'] = original;
        batch
          ..insert(database.cachedChatMessages, _messageCompanion(original))
          ..insert(database.cachedChatMessages, _messageCompanion(quote));
      }
    });
    writes.enabled = true;

    expect(
      await repository.applyChatGetResponse(
        _mutationPageResponse(mutationCount),
      ),
      ChatMergeOutcome.applied,
    );

    expect(writes.mutationProjectionSelects, 1);
    expect(writes.directParentUpdates, 0);
    expect(writes.parentBatchExecutions, 2);
    final quotes = await (database.select(
      database.cachedChatMessages,
    )..where((row) => row.messageId.isBetweenValues(2000, 2039))).get();
    expect(quotes, hasLength(mutationCount));
    expect(
      quotes.every((row) {
        final message = ChatMessage.fromJson(jsonDecode(row.rawJson));
        final parent = message.parent;
        return parent is ChatFullParent &&
            parent.message.message.startsWith('Edited ');
      }),
      isTrue,
    );
  });

  test('repeated mutations project the last server state', () async {
    final original = _messageWire(id: 4000, message: 'Original');
    final quote = _messageWire(id: 4001, message: 'Quote')
      ..['parent'] = original;
    await database.batch((batch) {
      batch
        ..insert(database.cachedChatMessages, _messageCompanion(original))
        ..insert(database.cachedChatMessages, _messageCompanion(quote));
    });

    expect(
      await repository.applyChatGetResponse(_repeatedMutationResponse()),
      ChatMergeOutcome.applied,
    );

    final row = await (database.select(
      database.cachedChatMessages,
    )..where((candidate) => candidate.messageId.equals(4001))).getSingle();
    final stored = ChatMessage.fromJson(jsonDecode(row.rawJson));
    final parent = stored.parent;
    expect(parent, isA<ChatFullParent>());
    expect((parent! as ChatFullParent).message.message, 'Second edit');
  });

  test('a mutation reaches a quote whose original is not cached', () async {
    final original = _messageWire(id: 5000, message: 'Original');
    final quote = _messageWire(id: 5001, message: 'Quote')
      ..['parent'] = original;
    await database
        .into(database.cachedChatMessages)
        .insert(_messageCompanion(quote));

    expect(
      await repository.applyChatGetResponse(
        _futureResponse(
          requestId: 'uncached-original-mutation',
          lastGiven: 5002,
          messages: <Map<String, Object?>>[
            _messageWire(id: 5002, message: '{actor} edited a message')
              ..['systemMessage'] = 'message_edited'
              ..['messageType'] = 'system'
              ..['parent'] = _messageWire(
                id: 5000,
                message: 'Edited without original',
              ),
          ],
        ),
      ),
      ChatMergeOutcome.applied,
    );

    final row = await (database.select(
      database.cachedChatMessages,
    )..where((candidate) => candidate.messageId.equals(5001))).getSingle();
    final parent = ChatMessage.fromJson(jsonDecode(row.rawJson)).parent;
    expect(parent, isA<ChatFullParent>());
    expect(
      (parent! as ChatFullParent).message.message,
      'Edited without original',
    );
  });
}

ChatGetResponse _mutationPageResponse(int count) {
  final notices = <Map<String, Object?>>[];
  for (var index = 0; index < count; index++) {
    final edited = _messageWire(id: 1000 + index, message: 'Edited $index');
    notices.add(
      _messageWire(id: 3000 + index, message: '{actor} edited a message')
        ..['systemMessage'] = 'message_edited'
        ..['messageType'] = 'system'
        ..['parent'] = edited,
    );
  }
  return _futureResponse(
    requestId: 'mutation-projection-batch',
    lastGiven: 2999 + count,
    messages: notices,
  );
}

ChatGetResponse _repeatedMutationResponse() {
  final firstEdit = _messageWire(id: 4000, message: 'First edit');
  final secondEdit = _messageWire(id: 4000, message: 'Second edit');
  return _futureResponse(
    requestId: 'repeated-mutation-order',
    lastGiven: 4003,
    messages: <Map<String, Object?>>[
      _messageWire(id: 4002, message: '{actor} edited a message')
        ..['systemMessage'] = 'message_edited'
        ..['messageType'] = 'system'
        ..['parent'] = firstEdit,
      _messageWire(id: 4003, message: '{actor} edited a message')
        ..['systemMessage'] = 'message_edited'
        ..['messageType'] = 'system'
        ..['parent'] = secondEdit,
    ],
  );
}

ChatGetResponse _futureResponse({
  required String requestId,
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

CachedChatMessagesCompanion _messageCompanion(Map<String, Object?> wire) {
  final id = wire['id']! as int;
  return CachedChatMessagesCompanion.insert(
    accountId: 'account-a',
    roomToken: 'rooma123',
    messageId: id,
    actorType: 'users',
    actorId: 'fixture-user',
    actorDisplayName: 'Fixture User',
    timestamp: id,
    systemMessage: '',
    messageType: 'comment',
    referenceId: 'reference-$id',
    displayText: wire['message']! as String,
    deleted: false,
    threadId: const Value(null),
    rawJson: jsonEncode(wire),
  );
}

Map<String, Object?> _messageWire({required int id, required String message}) =>
    <String, Object?>{
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
      'markdown': false,
      'reactions': <String, Object?>{},
      'reactionsSelf': <String>[],
    };

final class _ParentUpdateCounter extends QueryInterceptor {
  bool enabled = false;
  int parentBatchExecutions = 0;
  int directParentUpdates = 0;
  int mutationProjectionSelects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    final sql = statement.toLowerCase();
    if (enabled &&
        sql.contains('from "cached_chat_messages"') &&
        sql.contains('"raw_json" like ?')) {
      mutationProjectionSelects++;
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
          (statement) =>
              statement.toLowerCase().contains('update "cached_chat_messages"'),
        )) {
      parentBatchExecutions++;
    }
    return super.runBatched(executor, statements);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (enabled &&
        statement.toLowerCase().contains('update "cached_chat_messages"')) {
      directParentUpdates++;
    }
    return super.runUpdate(executor, statement, args);
  }
}
