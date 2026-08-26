import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository repository;

  setUp(() {
    database = openTestDatabase();
    repository = AccountRepository(database);
  });

  tearDown(() => database.close());

  test(
    'keeps one selected account and scopes conversations by account',
    () async {
      await repository.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
        loginName: 'alex',
        serverProductName: 'Nextcloud A',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      await repository.upsertAccount(
        accountId: 'account-b',
        serverUrl: 'https://b.example.invalid',
        loginName: 'blair',
        serverProductName: 'Nextcloud B',
        createdAt: DateTime.utc(2026, 1, 2),
      );

      await database
          .into(database.cachedConversations)
          .insert(
            CachedConversationsCompanion.insert(
              accountId: 'account-a',
              token: 'room-a',
              displayName: 'Room A',
              description: '',
              lastActivity: 20,
              unreadMessages: 1,
              favorite: false,
              lastMessageText: const Value('Message A'),
              lastMessageTimestamp: const Value(20),
              rawJson: '{}',
            ),
          );
      await database
          .into(database.cachedConversations)
          .insert(
            CachedConversationsCompanion.insert(
              accountId: 'account-b',
              token: 'room-b',
              displayName: 'Room B',
              description: '',
              lastActivity: 30,
              unreadMessages: 0,
              favorite: true,
              lastMessageText: const Value('Message B'),
              lastMessageTimestamp: const Value(30),
              rawJson: '{}',
            ),
          );

      final selected = await repository.watchSelectedAccount().first;
      final accountA = await repository.watchConversations('account-a').first;
      final accountB = await repository.watchConversations('account-b').first;

      expect(selected?.id, 'account-b');
      expect(accountA.map((room) => room.token), ['room-a']);
      expect(accountB.map((room) => room.token), ['room-b']);
    },
  );

  test('rejects selecting an account that does not exist', () async {
    await expectLater(
      repository.selectAccount('missing'),
      throwsA(isA<StateError>()),
    );
  });

  test('returns the upserted account before its transaction commits', () async {
    final interceptor = _RejectOutsideTransactionAccountSelects();
    await database.close();
    database = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(interceptor),
    );
    await database.customSelect('SELECT 1').get();
    interceptor.enabled = true;
    repository = AccountRepository(database);

    final account = await repository.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'alex',
      serverProductName: 'Nextcloud A',
      createdAt: DateTime.utc(2026, 1, 1),
    );

    expect(account.id, 'account-a');
    expect(account.selected, isTrue);
    expect(interceptor.rejectedSelects, 0);
  });

  test('authenticated account upsert clears a durable sync error', () async {
    await repository.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'alex',
      serverProductName: 'Nextcloud A',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await repository.recordSyncError('account-a', 'reauthenticationRequired');

    final account = await repository.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'alex',
      serverProductName: 'Nextcloud A',
      createdAt: DateTime.utc(2026, 1, 1),
      talkFeatures: const {'conversation-v4'},
    );

    expect(account.lastSyncError, null);
  });
}

final class _RejectOutsideTransactionAccountSelects extends QueryInterceptor {
  bool enabled = false;
  int activeTransactions = 0;
  int rejectedSelects = 0;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    activeTransactions++;
    return super.beginTransaction(parent);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    try {
      await super.commitTransaction(inner);
    } finally {
      activeTransactions--;
    }
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) async {
    try {
      await super.rollbackTransaction(inner);
    } finally {
      activeTransactions--;
    }
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (enabled &&
        activeTransactions == 0 &&
        statement.toLowerCase().contains('from "accounts"')) {
      rejectedSelects++;
      throw StateError('account select escaped the transaction');
    }
    return super.runSelect(executor, statement, args);
  }
}
