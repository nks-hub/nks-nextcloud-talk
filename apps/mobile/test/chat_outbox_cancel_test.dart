import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';

import 'test_support.dart';

/// The cancel gate from `docs/architecture/chat-messages-api.md`: an outbox
/// operation may only be dropped when the client can prove the server never
/// stored it. Everything the contract calls ambiguous has to survive.
void main() {
  late AppDatabase database;
  late ChatRepository chat;

  setUp(() async {
    database = openTestDatabase();
    chat = ChatRepository(database);
    await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  var sequence = 0;

  Future<void> insertOperation({
    required String operationId,
    required String outboxState,
    int attemptCount = 0,
    String messageIdsJson = '[]',
    String? errorClass,
  }) {
    sequence++;
    return database
        .into(database.textSendOperations)
        .insert(
          TextSendOperationsCompanion.insert(
            accountId: 'account-a',
            operationId: operationId,
            roomToken: 'rooma123',
            referenceId: 'reference-$operationId',
            message: 'Synthetic outbox text',
            replayContractRevision: 'fixture-revision',
            enqueueSequence: sequence,
            outboxState: outboxState,
            attemptCount: attemptCount,
            messageIdsJson: messageIdsJson,
            duplicateRiskAcknowledged: false,
            errorClass: Value(errorClass),
            createdAtMillis: 1,
            updatedAtMillis: 1,
          ),
        );
  }

  Future<bool> rowExists(String operationId) async {
    final row =
        await (database.select(database.textSendOperations)..where(
              (operation) =>
                  operation.accountId.equals('account-a') &
                  operation.operationId.equals(operationId),
            ))
            .getSingleOrNull();
    return row != null;
  }

  test('drops operations the server provably never received', () async {
    const states = <String, int>{'queued': 0, 'retryable': 1, 'failed': 1};
    for (final entry in states.entries) {
      await insertOperation(
        operationId: entry.key,
        outboxState: entry.key,
        attemptCount: entry.value,
      );

      expect(
        await chat.cancelTextSend(
          accountId: 'account-a',
          operationId: entry.key,
        ),
        isTrue,
        reason: 'state ${entry.key} is safe to cancel',
      );
      expect(await rowExists(entry.key), isFalse);
    }
  });

  test('keeps every operation whose body may already be stored', () async {
    await insertOperation(
      operationId: 'sending',
      outboxState: 'sending',
      attemptCount: 1,
    );
    await insertOperation(
      operationId: 'ambiguous',
      outboxState: 'awaitingConfirmation',
      attemptCount: 1,
      errorClass: 'unconfirmed-response',
    );
    await insertOperation(
      operationId: 'completed',
      outboxState: 'completed',
      attemptCount: 1,
      messageIdsJson: '[42]',
    );
    // Quarantined out of an ambiguous state by a newer replay contract, so
    // the failed label does not mean the server refused the message.
    await insertOperation(
      operationId: 'quarantined',
      outboxState: 'failed',
      attemptCount: 1,
      errorClass: 'obsolete-replay-contract',
    );
    // Several server matches for one reference: the ambiguity is recorded as
    // message IDs, and dropping the operation would hide real messages.
    await insertOperation(
      operationId: 'ambiguous-match',
      outboxState: 'awaitingConfirmation',
      attemptCount: 1,
      messageIdsJson: '[7,8]',
    );

    for (final operationId in const [
      'sending',
      'ambiguous',
      'completed',
      'quarantined',
      'ambiguous-match',
    ]) {
      expect(
        await chat.cancelTextSend(
          accountId: 'account-a',
          operationId: operationId,
        ),
        isFalse,
        reason: '$operationId may exist on the server',
      );
      expect(await rowExists(operationId), isTrue);
    }
  });

  test('a repeated cancel of an already dropped operation succeeds', () async {
    await insertOperation(operationId: 'queued', outboxState: 'queued');

    expect(
      await chat.cancelTextSend(
        accountId: 'account-a',
        operationId: 'queued',
      ),
      isTrue,
    );
    expect(
      await chat.cancelTextSend(
        accountId: 'account-a',
        operationId: 'queued',
      ),
      isTrue,
    );
  });

  test('another account cannot cancel this account operation', () async {
    await insertOperation(operationId: 'queued', outboxState: 'queued');

    expect(
      await chat.cancelTextSend(
        accountId: 'account-b',
        operationId: 'queued',
      ),
      isTrue,
    );
    expect(await rowExists('queued'), isTrue);
  });
}
