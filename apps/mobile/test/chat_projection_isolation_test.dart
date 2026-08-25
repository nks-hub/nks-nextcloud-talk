import 'dart:convert';
import 'package:drift/drift.dart';
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
    for (final account in const <({String id, String server})>[
      (id: 'account-a', server: 'https://cloud.example.invalid'),
      (id: 'account-b', server: 'https://other.example.invalid'),
    ]) {
      await accounts.upsertAccount(
        accountId: account.id,
        serverUrl: account.server,
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: DateTime.utc(2026, 1, 1),
      );
    }
    await repository.recordCapabilities(
      accountId: 'account-a',
      talkFeatures: const {'chat-v2', 'chat-replies'},
      observedAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  test('root merge projects only into the matching account and room', () async {
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'network-root',
      threadId: null,
      cursor: 20,
    );
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'root',
      threadId: null,
      cursor: 20,
    );
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'thread:20',
      threadId: 20,
      cursor: 20,
    );
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'roomb123',
      scopeKey: 'root',
      threadId: null,
      cursor: 777,
    );
    await _insertScope(
      database,
      accountId: 'account-a',
      roomToken: 'roomb123',
      scopeKey: 'thread:20',
      threadId: 20,
      cursor: 777,
    );
    await _insertScope(
      database,
      accountId: 'account-b',
      roomToken: 'rooma123',
      scopeKey: 'root',
      threadId: null,
      cursor: 888,
    );
    await _insertScope(
      database,
      accountId: 'account-b',
      roomToken: 'rooma123',
      scopeKey: 'thread:20',
      threadId: 20,
      cursor: 888,
    );
    await _insertMessage(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
    );

    final response = _rootReplyResponse();
    expect(
      await repository.applyChatGetResponse(response),
      ChatMergeOutcome.applied,
    );

    final matchingRoot = await _scope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'root',
    );
    final matchingView = await _scope(
      database,
      accountId: 'account-a',
      roomToken: 'rooma123',
      scopeKey: 'thread:20',
    );
    final otherRoomRoot = await _scope(
      database,
      accountId: 'account-a',
      roomToken: 'roomb123',
      scopeKey: 'root',
    );
    final otherRoomView = await _scope(
      database,
      accountId: 'account-a',
      roomToken: 'roomb123',
      scopeKey: 'thread:20',
    );
    final otherAccountRoot = await _scope(
      database,
      accountId: 'account-b',
      roomToken: 'rooma123',
      scopeKey: 'root',
    );
    final otherAccountView = await _scope(
      database,
      accountId: 'account-b',
      roomToken: 'rooma123',
      scopeKey: 'thread:20',
    );

    expect(matchingRoot.futureCursor, '30');
    expect(matchingView.futureCursor, '30');
    expect(jsonDecode(matchingView.blocksJson), [
      ['20', '30'],
    ]);
    expect(otherRoomRoot.futureCursor, '777');
    expect(otherRoomView.futureCursor, '777');
    expect(otherAccountRoot.futureCursor, '888');
    expect(otherAccountView.futureCursor, '888');
  });
}

Future<void> _insertScope(
  AppDatabase database, {
  required String accountId,
  required String roomToken,
  required String scopeKey,
  required int? threadId,
  required int cursor,
}) {
  return database
      .into(database.chatScopes)
      .insert(
        ChatScopesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          scopeKey: scopeKey,
          threadId: Value(threadId),
          historyCursor: '$cursor',
          futureCursor: '$cursor',
          lastCommonRead: '0',
          lastReadMessage: 0,
          unreadMessages: 0,
          hasHistory: true,
          futureConverged: true,
          blocksJson: '[["$cursor","$cursor"]]',
        ),
      );
}

Future<void> _insertMessage(
  AppDatabase database, {
  required String accountId,
  required String roomToken,
}) {
  final raw = _messageJson(id: 20, roomToken: roomToken, threadId: null);
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          messageId: 20,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 20,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-20',
          displayText: 'Message 20',
          deleted: false,
          rawJson: jsonEncode(raw),
        ),
      );
}

ChatGetResponse _rootReplyResponse() {
  final request = ChatFetchRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('projection-isolation'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
      'chat-v2',
      'chat-replies',
    ], federated: false),
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse('20'),
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
            'data': [_messageJson(id: 30, roomToken: 'rooma123', threadId: 20)],
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap(const {
      'X-Chat-Last-Given': '30',
      'X-Chat-Last-Common-Read': '0',
    }),
  );
}

Map<String, Object?> _messageJson({
  required int id,
  required String roomToken,
  required int? threadId,
}) {
  return <String, Object?>{
    'id': id,
    'token': roomToken,
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
    'threadId': ?threadId,
  };
}

Future<StoredChatScope> _scope(
  AppDatabase database, {
  required String accountId,
  required String roomToken,
  required String scopeKey,
}) {
  return (database.select(database.chatScopes)..where(
        (row) =>
            row.accountId.equals(accountId) &
            row.roomToken.equals(roomToken) &
            row.scopeKey.equals(scopeKey),
      ))
      .getSingle();
}
