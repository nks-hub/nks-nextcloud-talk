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
      createdAt: DateTime.utc(2026, 1, 1),
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
