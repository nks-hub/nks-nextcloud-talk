import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });

  tearDown(() => database.close());

  test(
    'runtime reconstruction preserves many isolated thread scopes',
    () async {
      const threadCount = 1200;
      const firstThreadId = 1000;
      const stride = 10;
      final lastThreadId = firstThreadId + ((threadCount - 1) * stride);
      await database.batch((batch) {
        batch.insert(
          database.chatScopes,
          ChatScopesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            scopeKey: 'root',
            historyCursor: '$firstThreadId',
            futureCursor: '${lastThreadId + 2}',
            lastCommonRead: '0',
            lastReadMessage: 0,
            unreadMessages: 0,
            hasHistory: true,
            futureConverged: true,
            blocksJson: '[["$firstThreadId","${lastThreadId + 2}"]]',
          ),
        );
        for (var thread = 0; thread < threadCount; thread++) {
          final threadId = firstThreadId + (thread * stride);
          batch.insert(
            database.chatScopes,
            ChatScopesCompanion.insert(
              accountId: 'account-a',
              roomToken: 'rooma123',
              scopeKey: 'network-thread:$threadId',
              threadId: Value(threadId),
              historyCursor: '$threadId',
              futureCursor: '${threadId + 2}',
              lastCommonRead: '0',
              lastReadMessage: 0,
              unreadMessages: 0,
              hasHistory: true,
              futureConverged: true,
              blocksJson: '[["$threadId","${threadId + 2}"]]',
            ),
          );
          for (var offset = 0; offset < 3; offset++) {
            final messageId = threadId + offset;
            batch.insert(
              database.cachedChatMessages,
              CachedChatMessagesCompanion.insert(
                accountId: 'account-a',
                roomToken: 'rooma123',
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
        }
      });

      final watch = Stopwatch()..start();
      final snapshot = await repository.loadRuntimeForTesting('account-a');
      watch.stop();
      debugPrint(
        'Restored $threadCount thread scopes in '
        '${watch.elapsedMilliseconds} ms.',
      );
      final accountState = snapshot.accounts[AccountId.parse('account-a')]!;
      final rootKey = ChatScopeKey(
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        threadId: null,
      );
      final lastThreadKey = ChatScopeKey(
        roomToken: rootKey.roomToken,
        threadId: lastThreadId,
      );

      expect(accountState.scopes, hasLength(threadCount + 1));
      expect(accountState.scopes[rootKey]!.messageIds, hasLength(threadCount));
      expect(accountState.scopes[rootKey]!.messageIds.first, firstThreadId);
      expect(accountState.scopes[rootKey]!.messageIds.last, lastThreadId);
      expect(accountState.scopes[lastThreadKey]!.messageIds, [
        lastThreadId,
        lastThreadId + 1,
        lastThreadId + 2,
      ]);
    },
  );
}
