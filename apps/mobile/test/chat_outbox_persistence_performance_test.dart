import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';

void main() {
  late AppDatabase database;
  late ChatRepository repository;
  late _OutboxWriteCounter writes;

  setUp(() async {
    writes = _OutboxWriteCounter();
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
  });

  tearDown(() => database.close());

  test(
    'restart recovery persists all interrupted sends as one batch',
    () async {
      const operationCount = 40;
      await database.batch((batch) {
        for (var index = 0; index < operationCount; index++) {
          final suffix = index.toRadixString(16).padLeft(12, '0');
          final roomToken = 'room${index.toString().padLeft(4, '0')}';
          batch.insert(
            database.textSendOperations,
            TextSendOperationsCompanion.insert(
              accountId: 'account-a',
              operationId: '00000000-0000-4000-8000-$suffix',
              roomToken: roomToken,
              referenceId: '11111111-1111-4111-8111-$suffix',
              message: 'Pending message $index',
              replayContractRevision: 'fixture-revision',
              enqueueSequence: index + 1,
              outboxState: 'sending',
              attemptCount: 1,
              messageIdsJson: '[]',
              duplicateRiskAcknowledged: false,
              createdAtMillis: index,
              updatedAtMillis: index,
            ),
          );
        }
      });
      writes.enabled = true;

      await repository.recoverInterruptedTextSends('account-a', now: 1000);

      expect(writes.outboxBatchExecutions, 1);
      expect(writes.directOutboxInserts, 0);
      final rows = await database.select(database.textSendOperations).get();
      expect(rows, hasLength(operationCount));
      expect(
        rows.every((row) => row.outboxState == 'awaitingConfirmation'),
        isTrue,
      );
      expect(
        rows.every((row) => row.errorClass == 'process-interrupted'),
        isTrue,
      );
    },
  );
}

final class _OutboxWriteCounter extends QueryInterceptor {
  bool enabled = false;
  int outboxBatchExecutions = 0;
  int directOutboxInserts = 0;

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    if (enabled &&
        statements.statements.any(
          (statement) =>
              statement.toLowerCase().contains('into "text_send_operations"'),
        )) {
      outboxBatchExecutions++;
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
        statement.toLowerCase().contains('into "text_send_operations"')) {
      directOutboxInserts++;
    }
    return super.runInsert(executor, statement, args);
  }
}
