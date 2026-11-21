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

  test(
    'loads requested conversation names without crossing accounts',
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

      Future<void> insert(String accountId, String token, String name) {
        return database
            .into(database.cachedConversations)
            .insert(
              CachedConversationsCompanion.insert(
                accountId: accountId,
                token: token,
                displayName: name,
                description: '',
                lastActivity: 0,
                unreadMessages: 0,
                favorite: false,
                rawJson: '{}',
              ),
            );
      }

      await insert('account-a', 'room-a', 'Room A');
      await insert('account-a', 'room-b', 'Room B');
      await insert('account-b', 'room-a', 'Other account');

      final names = await repository.getConversationNames(
        accountId: 'account-a',
        tokens: const {'room-a', 'room-b', 'missing'},
      );

      expect(names, const {'room-a': 'Room A', 'room-b': 'Room B'});
      expect(
        await repository.getConversationNames(
          accountId: 'account-a',
          tokens: const {},
        ),
        isEmpty,
      );
    },
  );

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

  test('selected account exposes only its own server theme color', () async {
    await repository.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'alex',
      serverProductName: 'Nextcloud A',
      serverThemeColor: '#123456',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await repository.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://b.example.invalid',
      loginName: 'blair',
      serverProductName: 'Nextcloud B',
      serverThemeColor: '#abcdef',
      createdAt: DateTime.utc(2026, 1, 2),
    );

    expect(await repository.watchSelectedThemeColor().first, '#abcdef');

    await repository.selectAccount('account-a');
    expect(await repository.watchSelectedThemeColor().first, '#123456');
  });

  test('capability refresh removes a stale server theme color', () async {
    await repository.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://a.example.invalid',
      loginName: 'alex',
      serverProductName: 'Nextcloud A',
      serverThemeColor: '#123456',
      createdAt: DateTime.utc(2026, 1, 1),
    );

    await repository.updateCapabilities('account-a', const {
      'conversation-v4',
    }, serverThemeColor: null);

    expect(await repository.watchSelectedThemeColor().first, null);
  });

  test(
    'a sync that changes nothing visible wakes no account watcher',
    () async {
      await repository.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
        loginName: 'alex',
        serverProductName: 'Nextcloud A',
        talkFeatures: const {'conversation-v4'},
        serverThemeColor: '#123456',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final selected = <StoredAccount?>[];
      final all = <List<StoredAccount>>[];
      final colors = <String?>[];
      final subscriptions = [
        repository.watchSelectedAccount().listen(selected.add),
        repository.watchAccounts().listen(all.add),
        repository.watchSelectedThemeColor().listen(colors.add),
      ];
      addTearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      });
      Future<void> settle(bool Function() done) async {
        while (!done()) {
          await pumpEventQueue();
        }
        await pumpEventQueue();
      }

      await settle(
        () => selected.isNotEmpty && all.isNotEmpty && colors.isNotEmpty,
      );

      // What every conversation sync writes to the account row.
      await (database.update(
        database.accounts,
      )..where((account) => account.id.equals('account-a'))).write(
        const AccountsCompanion(
          conversationCursor: Value('cursor-2'),
          conversationHash: Value('hash-2'),
          lastSyncedAtMillis: Value(1234),
        ),
      );
      await repository.updateCapabilities('account-a', const {
        'conversation-v4',
      }, serverThemeColor: '#123456');
      await pumpEventQueue();
      await repository.recordSyncError('account-a', 'network');
      await settle(() => selected.length > 1 && all.length > 1);

      expect(selected, hasLength(2));
      expect(all, hasLength(2));
      expect(colors, ['#123456']);
      expect(selected.last!.lastSyncError, 'network');
      expect(selected.last!.conversationCursor, null);
      final exact = await repository.getAccount('account-a');
      expect(exact!.conversationCursor, 'cursor-2');
      expect(exact.lastSyncedAtMillis, 1234);
    },
  );
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
