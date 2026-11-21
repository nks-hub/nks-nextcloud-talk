import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late ChatRepository repository;
  late _ConversationPreviewCounter writes;

  setUp(() async {
    writes = _ConversationPreviewCounter();
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
    await _insertConversation(database);
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

  test('one message batch persists one conversation preview batch', () async {
    writes.enabled = true;

    expect(
      await repository.applyChatGetResponse(_rootFutureResponse()),
      ChatMergeOutcome.applied,
    );

    expect(writes.keyedConversationSelects, 1);
    expect(writes.directConversationUpdates, 0);
    expect(writes.conversationBatchExecutions, 1);
    expect(writes.directMessageInserts, 0);
    expect(writes.messageBatchExecutions, 1);
    final conversation = await repository.getConversation(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(conversation?.lastMessageTimestamp, 1039);
    expect(conversation?.lastMessageText, 'Message 1039');
  });

  test(
    'a reaction can update a preceding message from the same page',
    () async {
      expect(
        await repository.applyChatGetResponse(_rootAndReactionResponse()),
        ChatMergeOutcome.applied,
      );

      final row =
          await (database.select(database.cachedChatMessages)..where(
                (message) =>
                    message.accountId.equals('account-a') &
                    message.roomToken.equals('rooma123') &
                    message.messageId.equals(2000),
              ))
              .getSingle();
      final stored = ChatMessage.fromJson(jsonDecode(row.rawJson));
      expect(stored.reactions, {'thumbs-up': 2});
      expect(stored.reactionsSelf, ['thumbs-up']);
    },
  );

  test('a page of cached reactions reads all targets together', () async {
    const reactionCount = 40;
    await database.batch((batch) {
      for (var index = 0; index < reactionCount; index++) {
        final message = _messageJson(4000 + index);
        batch.insert(
          database.cachedChatMessages,
          _cachedMessageCompanion(message),
        );
      }
    });
    writes.enabled = true;

    expect(
      await repository.applyChatGetResponse(
        _cachedReactionsResponse(reactionCount),
      ),
      ChatMergeOutcome.applied,
    );

    expect(writes.keyedMessageSelects, 0);
    expect(writes.boundedMessageSelects, 1);
    final rows = await (database.select(
      database.cachedChatMessages,
    )..where((message) => message.messageId.isBetweenValues(4000, 4039))).get();
    expect(rows, hasLength(reactionCount));
    expect(
      rows.every((row) {
        final stored = ChatMessage.fromJson(jsonDecode(row.rawJson));
        return stored.reactions['thumbs-up'] == 1;
      }),
      isTrue,
    );
  });

  test('a concurrent cached edit survives the prefetched reaction', () async {
    final original = _messageJson(7000);
    await database
        .into(database.cachedChatMessages)
        .insert(_cachedMessageCompanion(original));
    final concurrentlyEdited = Map<String, Object?>.of(original)
      ..['message'] = 'Concurrent edit';
    writes
      ..enabled = true
      ..reactionConflictRawJson = jsonEncode(concurrentlyEdited);

    expect(
      await repository.applyChatGetResponse(
        _singleCachedReactionResponse(original),
      ),
      ChatMergeOutcome.applied,
    );

    expect(writes.reactionConflictInjected, isTrue);
    final row = await (database.select(
      database.cachedChatMessages,
    )..where((message) => message.messageId.equals(7000))).getSingle();
    final stored = ChatMessage.fromJson(jsonDecode(row.rawJson));
    expect(stored.message, 'Concurrent edit');
    expect(stored.reactions, {'heart': 1});
  });

  test(
    'a mutation updates an earlier quoted parent from the same page',
    () async {
      expect(
        await repository.applyChatGetResponse(_rootQuoteAndMutationResponse()),
        ChatMergeOutcome.applied,
      );

      final row =
          await (database.select(database.cachedChatMessages)..where(
                (message) =>
                    message.accountId.equals('account-a') &
                    message.roomToken.equals('rooma123') &
                    message.messageId.equals(3001),
              ))
              .getSingle();
      final stored = ChatMessage.fromJson(jsonDecode(row.rawJson));
      expect(stored.parent, isA<ChatFullParent>());
      final parent = stored.parent as ChatFullParent;
      expect(parent.message.message, 'Edited message');
    },
  );

  test('reaction cache follows a mutation before the next reaction', () async {
    expect(
      await repository.applyChatGetResponse(
        _reactionMutationReactionResponse(),
      ),
      ChatMergeOutcome.applied,
    );

    final row =
        await (database.select(database.cachedChatMessages)..where(
              (message) =>
                  message.accountId.equals('account-a') &
                  message.roomToken.equals('rooma123') &
                  message.messageId.equals(6000),
            ))
            .getSingle();
    final stored = ChatMessage.fromJson(jsonDecode(row.rawJson));
    expect(stored.message, 'Edited message');
    expect(stored.reactions, {'thumbs-up': 1, 'heart': 2});
  });
}

Future<void> _insertConversation(AppDatabase database) async {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final wire = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  wire['token'] = 'rooma123';
  (wire['lastMessage']! as Map<String, Object?>)['token'] = 'rooma123';
  final room = ConversationRoom.fromJson(wire);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: 'account-a',
          token: room.token.value,
          displayName: room.displayName,
          description: room.description,
          lastActivity: room.lastActivity,
          unreadMessages: room.unreadMessages,
          favorite: room.isFavorite,
          readOnly: Value(room.readOnly),
          roomType: Value(room.type),
          roomName: Value(room.name),
          objectType: Value(room.objectType),
          avatarVersion: Value(room.avatarVersion),
          isCustomAvatar: Value(room.isCustomAvatar),
          lastMessageText: const Value('Old message'),
          lastMessageTimestamp: const Value(1),
          rawJson: jsonEncode(wire),
        ),
      );
}

ChatGetResponse _rootFutureResponse() {
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('message-preview-batch'),
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
            'data': [for (var id = 1000; id < 1040; id++) _messageJson(id)],
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap({
      'X-Chat-Last-Given': '1039',
      'X-Chat-Last-Common-Read': '0',
    }),
  );
}

ChatGetResponse _rootAndReactionResponse() {
  final original = _messageJson(2000);
  final reacted = Map<String, Object?>.of(original)
    ..['reactions'] = {'thumbs-up': 2}
    ..['reactionsSelf'] = <String>['thumbs-up'];
  final notice = _messageJson(2001)
    ..['systemMessage'] = 'reaction'
    ..['messageType'] = 'system'
    ..['message'] = 'thumbs-up'
    ..['parent'] = reacted;
  return _futureResponse(
    requestId: 'message-reaction-order',
    lastGiven: 2001,
    messages: [original, notice],
  );
}

ChatGetResponse _rootQuoteAndMutationResponse() {
  final original = _messageJson(3000);
  final quoted = _messageJson(3001)
    ..['message'] = 'Quoted reply'
    ..['parent'] = original;
  final edited = Map<String, Object?>.of(original)
    ..['message'] = 'Edited message';
  final notice = _messageJson(3002)
    ..['systemMessage'] = 'message_edited'
    ..['messageType'] = 'system'
    ..['message'] = '{actor} edited a message'
    ..['parent'] = edited;
  return _futureResponse(
    requestId: 'message-mutation-order',
    lastGiven: 3002,
    messages: [original, quoted, notice],
  );
}

ChatGetResponse _cachedReactionsResponse(int count) {
  final notices = <Map<String, Object?>>[];
  for (var index = 0; index < count; index++) {
    final parent = Map<String, Object?>.of(_messageJson(4000 + index))
      ..['reactions'] = <String, Object?>{'thumbs-up': 1}
      ..['reactionsSelf'] = const <String>[];
    notices.add(
      _messageJson(5000 + index)
        ..['systemMessage'] = 'reaction'
        ..['messageType'] = 'system'
        ..['message'] = 'thumbs-up'
        ..['parent'] = parent,
    );
  }
  return _futureResponse(
    requestId: 'cached-reaction-batch',
    lastGiven: 4999 + count,
    messages: notices,
  );
}

ChatGetResponse _reactionMutationReactionResponse() {
  final original = _messageJson(6000);
  final firstReaction = Map<String, Object?>.of(original)
    ..['reactions'] = <String, Object?>{'thumbs-up': 1}
    ..['reactionsSelf'] = const <String>[];
  final edited = Map<String, Object?>.of(firstReaction)
    ..['message'] = 'Edited message';
  final finalReaction = Map<String, Object?>.of(edited)
    ..['reactions'] = <String, Object?>{'thumbs-up': 1, 'heart': 2};
  return _futureResponse(
    requestId: 'reaction-mutation-reaction-order',
    lastGiven: 6003,
    messages: <Map<String, Object?>>[
      original,
      _messageJson(6001)
        ..['systemMessage'] = 'reaction'
        ..['messageType'] = 'system'
        ..['message'] = 'thumbs-up'
        ..['parent'] = firstReaction,
      _messageJson(6002)
        ..['systemMessage'] = 'message_edited'
        ..['messageType'] = 'system'
        ..['message'] = '{actor} edited a message'
        ..['parent'] = edited,
      _messageJson(6003)
        ..['systemMessage'] = 'reaction'
        ..['messageType'] = 'system'
        ..['message'] = 'heart'
        ..['parent'] = finalReaction,
    ],
  );
}

ChatGetResponse _singleCachedReactionResponse(Map<String, Object?> original) {
  final parent = Map<String, Object?>.of(original)
    ..['reactions'] = <String, Object?>{'heart': 1}
    ..['reactionsSelf'] = const <String>[];
  return _futureResponse(
    requestId: 'cached-reaction-conflict',
    lastGiven: 7001,
    messages: <Map<String, Object?>>[
      _messageJson(7001)
        ..['systemMessage'] = 'reaction'
        ..['messageType'] = 'system'
        ..['message'] = 'heart'
        ..['parent'] = parent,
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

Map<String, Object?> _messageJson(int id) => <String, Object?>{
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
};

CachedChatMessagesCompanion _cachedMessageCompanion(
  Map<String, Object?> wire,
) => CachedChatMessagesCompanion.insert(
  accountId: 'account-a',
  roomToken: 'rooma123',
  messageId: wire['id']! as int,
  actorType: wire['actorType']! as String,
  actorId: wire['actorId']! as String,
  actorDisplayName: wire['actorDisplayName']! as String,
  timestamp: wire['timestamp']! as int,
  systemMessage: wire['systemMessage']! as String,
  messageType: wire['messageType']! as String,
  referenceId: wire['referenceId']! as String,
  displayText: wire['message']! as String,
  deleted: false,
  threadId: const Value(null),
  rawJson: jsonEncode(wire),
);

final class _ConversationPreviewCounter extends QueryInterceptor {
  bool enabled = false;
  int keyedConversationSelects = 0;
  int directConversationUpdates = 0;
  int conversationBatchExecutions = 0;
  int directMessageInserts = 0;
  int messageBatchExecutions = 0;
  int keyedMessageSelects = 0;
  int boundedMessageSelects = 0;
  String? reactionConflictRawJson;
  bool reactionConflictInjected = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    final sql = statement.toLowerCase();
    if (enabled &&
        sql.contains('from "cached_conversations"') &&
        RegExp(r'"token"\s*=\s*\?').hasMatch(sql)) {
      keyedConversationSelects++;
    }
    if (enabled && sql.contains('from "cached_chat_messages"')) {
      if (RegExp(r'"message_id"\s*=\s*\?').hasMatch(sql)) {
        keyedMessageSelects++;
      }
      if (RegExp(r'"message_id"\s+in\s*\(').hasMatch(sql)) {
        boundedMessageSelects++;
      }
    }
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    if (enabled &&
        statements.statements.any((statement) {
          final sql = statement.toLowerCase();
          return sql.contains('update "cached_conversations"') &&
              sql.contains('"last_message_timestamp"');
        })) {
      conversationBatchExecutions++;
    }
    if (enabled &&
        statements.statements.any(
          (statement) =>
              statement.toLowerCase().contains('into "cached_chat_messages"'),
        )) {
      messageBatchExecutions++;
    }
    return super.runBatched(executor, statements);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (enabled &&
        statement.toLowerCase().contains('into "cached_chat_messages"')) {
      directMessageInserts++;
    }
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final sql = statement.toLowerCase();
    if (enabled &&
        sql.contains('update "cached_conversations"') &&
        sql.contains('"last_message_timestamp"')) {
      directConversationUpdates++;
    }
    final conflictRawJson = reactionConflictRawJson;
    if (enabled &&
        !reactionConflictInjected &&
        conflictRawJson != null &&
        sql.contains('update "cached_chat_messages"') &&
        sql.contains('"raw_json" = ?')) {
      reactionConflictInjected = true;
      await executor.runUpdate(
        'UPDATE "cached_chat_messages" '
        'SET "raw_json" = ?, "display_text" = ? '
        'WHERE "account_id" = ? AND "room_token" = ? AND "message_id" = ?',
        <Object?>[
          conflictRawJson,
          'Concurrent edit',
          'account-a',
          'rooma123',
          7000,
        ],
      );
      return 0;
    }
    return super.runUpdate(executor, statement, args);
  }
}
