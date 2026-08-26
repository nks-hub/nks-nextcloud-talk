import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
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
    final accounts = AccountRepository(database);
    for (final id in <String>['account-a', 'account-b']) {
      await accounts.upsertAccount(
        accountId: id,
        serverUrl: 'https://$id.example.invalid',
        loginName: id,
        serverProductName: 'Nextcloud',
        talkFeatures: const {'clear-history'},
        createdAt: DateTime.utc(2026, 8, 26),
      );
    }
  });

  tearDown(() => database.close());

  test(
    'atomically replaces only the target room and preserves durable work',
    () async {
      await _seedMessage(database, 'account-a', 'rooma123', 4);
      await _seedMessage(database, 'account-a', 'rooma123', 5, threadId: 5);
      await _seedMessage(database, 'account-a', 'other123', 6);
      await _seedMessage(database, 'account-b', 'rooma123', 7);
      await _seedScope(database, 'account-a', 'rooma123', 'root');
      await _seedScope(database, 'account-a', 'rooma123', 'network-root');
      await _seedScope(
        database,
        'account-a',
        'rooma123',
        'thread:5',
        threadId: 5,
      );
      await _seedScope(
        database,
        'account-a',
        'rooma123',
        'network-thread:5',
        threadId: 5,
      );
      await _seedScope(database, 'account-a', 'other123', 'root');
      await _seedScope(database, 'account-b', 'rooma123', 'root');
      await _seedOutbox(database);
      await database
          .into(database.chatDrafts)
          .insert(
            ChatDraftsCompanion.insert(
              accountId: 'account-a',
              roomToken: 'rooma123',
              scopeKey: 'thread:5',
              draftText: 'keep draft',
              updatedAtMillis: 1,
            ),
          );

      final success = _success();
      await repository.applyClearRoomHistorySuccess(success);

      final targetMessages =
          await (database.select(database.cachedChatMessages)..where(
                (row) =>
                    row.accountId.equals('account-a') &
                    row.roomToken.equals('rooma123'),
              ))
              .get();
      expect(targetMessages, hasLength(1));
      expect(targetMessages.single.messageId, 42);
      expect(targetMessages.single.systemMessage, 'history_cleared');
      expect(targetMessages.single.threadId, isNull);

      final targetScopes =
          await (database.select(database.chatScopes)..where(
                (row) =>
                    row.accountId.equals('account-a') &
                    row.roomToken.equals('rooma123'),
              ))
              .get();
      expect(targetScopes.map((row) => row.scopeKey).toSet(), {
        'root',
        'network-root',
      });
      for (final scope in targetScopes) {
        expect(scope.historyCursor, '42');
        expect(scope.futureCursor, '42');
        expect(scope.lastCommonRead, '41');
        expect(scope.lastReadMessage, 0);
        expect(scope.unreadMessages, 1);
        expect(scope.hasHistory, isFalse);
        expect(scope.futureConverged, isTrue);
      }

      expect(
        await (database.select(
          database.cachedChatMessages,
        )..where((row) => row.roomToken.equals('other123'))).get(),
        hasLength(1),
      );
      expect(
        await (database.select(
          database.cachedChatMessages,
        )..where((row) => row.accountId.equals('account-b'))).get(),
        hasLength(1),
      );
      expect(
        await database.select(database.textSendOperations).get(),
        hasLength(1),
      );
      expect(
        (await database.select(database.textSendOperations).getSingle())
            .messageIdsJson,
        '[5]',
      );
      expect(await database.select(database.chatDrafts).get(), hasLength(1));
    },
  );
}

Future<void> _seedMessage(
  AppDatabase database,
  String accountId,
  String roomToken,
  int messageId, {
  int? threadId,
}) {
  final wire = _message(
    roomToken: roomToken,
    id: messageId,
    threadId: threadId,
  );
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          messageId: messageId,
          actorType: 'users',
          actorId: 'user',
          actorDisplayName: 'User',
          timestamp: messageId,
          systemMessage: '',
          messageType: 'comment',
          referenceId: '',
          displayText: 'message $messageId',
          deleted: false,
          threadId: Value(threadId),
          rawJson: jsonEncode(wire),
        ),
      );
}

Future<void> _seedScope(
  AppDatabase database,
  String accountId,
  String roomToken,
  String scopeKey, {
  int? threadId,
}) {
  return database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          scopeKey: scopeKey,
          threadId: Value(threadId),
          historyCursor: '4',
          futureCursor: '5',
          lastCommonRead: '4',
          lastReadMessage: 4,
          unreadMessages: 1,
          hasHistory: true,
          futureConverged: true,
          blocksJson: '[{"start":"4","end":"5"}]',
        ),
      );
}

Future<void> _seedOutbox(AppDatabase database) {
  return database
      .into(database.textSendOperations)
      .insert(
        TextSendOperationsCompanion.insert(
          accountId: 'account-a',
          operationId: '123e4567-e89b-42d3-a456-426614174000',
          roomToken: 'rooma123',
          referenceId: '123e4567-e89b-12d3-a456-426614174000',
          message: 'pending',
          replayContractRevision: 'test',
          enqueueSequence: 1,
          outboxState: 'awaitingConfirmation',
          attemptCount: 1,
          messageIdsJson: '[5]',
          duplicateRiskAcknowledged: false,
          createdAtMillis: 1,
          updatedAtMillis: 1,
        ),
      );
}

ClearRoomHistorySuccess _success() {
  return decodeClearRoomHistoryResponse(
        request: ClearRoomHistoryRequest(
          accountId: AccountId.parse('account-a'),
          server: ServerBase.parse('https://account-a.example.invalid'),
          roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
          capabilities: _capabilities(),
        ),
        statusCode: 200,
        body: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
                'data': _message(roomToken: 'rooma123', id: 42, cleared: true),
              },
            }),
          ),
        ),
        headers: ChatResponseHeaders.fromMap({'X-Chat-Last-Common-Read': '41'}),
      )
      as ClearRoomHistorySuccess;
}

CapabilitySnapshot _capabilities() => CapabilitySnapshot.fromJson({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': {
      'version': {
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': {
        'spreed': {
          'features': ['clear-history'],
        },
      },
    },
  },
}, context: CapabilityContext.authenticated);

Map<String, Object?> _message({
  required String roomToken,
  required int id,
  int? threadId,
  bool cleared = false,
}) => <String, Object?>{
  'id': id,
  'token': roomToken,
  'actorType': 'users',
  'actorId': 'moderator',
  'actorDisplayName': 'Moderator',
  'timestamp': 1787695200,
  'systemMessage': cleared ? 'history_cleared' : '',
  'messageType': cleared ? 'system' : 'comment',
  'isReplyable': !cleared,
  'referenceId': '',
  'message': cleared
      ? 'You cleared the history of the conversation'
      : 'message $id',
  'messageParameters': <String, Object?>{},
  'threadId': ?threadId,
};
