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
  late AccountRepository accounts;
  late ChatRepository chat;

  setUp(() {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
  });

  tearDown(() => database.close());

  test(
    'read and unread atomically update only root-backed account state',
    () async {
      final accountA = await _prepareAccount(
        database: database,
        accounts: accounts,
        chat: chat,
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
      );
      final accountB = await _prepareAccount(
        database: database,
        accounts: accounts,
        chat: chat,
        accountId: 'account-b',
        serverUrl: 'https://b.example.invalid',
      );

      await _prepareThreadViews(database, chat, accountA);
      await _prepareThreadViews(database, chat, accountB);

      final read = _readResponse(
        accountId: accountA.id,
        serverUrl: accountA.serverUrl,
        lastReadMessage: 120,
        lastCommonReadMessage: 118,
        unreadMessages: 0,
      );
      expect(
        await chat.applyChatReadResponse(read),
        ChatMergeOutcome.readApplied,
      );

      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: null,
        lastReadMessage: 120,
        lastCommonRead: '118',
        unreadMessages: 0,
      );
      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: 50,
        lastReadMessage: 120,
        lastCommonRead: '118',
        unreadMessages: 0,
      );
      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: 60,
        lastReadMessage: 0,
        lastCommonRead: '0',
        unreadMessages: 0,
      );
      await _expectNetworkMarkers(
        chat,
        accountId: accountA.id,
        threadId: 60,
        lastReadMessage: 0,
        lastCommonRead: '0',
        unreadMessages: 0,
      );
      await _expectMarkers(
        chat,
        accountId: accountB.id,
        threadId: null,
        lastReadMessage: 108,
        lastCommonRead: '106',
        unreadMessages: 3,
      );
      await _expectConversationMarker(
        database,
        accountId: accountA.id,
        lastReadMessage: 120,
        lastCommonReadMessage: 118,
        unreadMessages: 0,
      );

      final unread = _unreadResponse(
        accountId: accountA.id,
        serverUrl: accountA.serverUrl,
        lastReadMessage: -1,
        lastCommonReadMessage: 118,
        unreadMessages: 1,
      );
      expect(
        await chat.applyChatReadResponse(unread),
        ChatMergeOutcome.unreadApplied,
      );
      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: null,
        lastReadMessage: -1,
        lastCommonRead: '118',
        unreadMessages: 1,
      );
      await _expectConversationMarker(
        database,
        accountId: accountA.id,
        lastReadMessage: -1,
        lastCommonReadMessage: 118,
        unreadMessages: 1,
      );
    },
  );

  test(
    'conversation write failure rolls back every marker projection',
    () async {
      final account = await _prepareAccount(
        database: database,
        accounts: accounts,
        chat: chat,
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
      );
      await _prepareThreadViews(database, chat, account);
      await database.customStatement('''
      CREATE TRIGGER fail_read_marker_conversation_update
      BEFORE UPDATE ON cached_conversations
      BEGIN
        SELECT RAISE(ABORT, 'forced read marker rollback');
      END
    ''');

      await expectLater(
        chat.applyChatReadResponse(
          _readResponse(
            accountId: account.id,
            serverUrl: account.serverUrl,
            lastReadMessage: 120,
            lastCommonReadMessage: 118,
            unreadMessages: 0,
          ),
        ),
        throwsA(anything),
      );

      await _expectMarkers(
        chat,
        accountId: account.id,
        threadId: null,
        lastReadMessage: 108,
        lastCommonRead: '106',
        unreadMessages: 3,
      );
      await _expectMarkers(
        chat,
        accountId: account.id,
        threadId: 50,
        lastReadMessage: 0,
        lastCommonRead: '0',
        unreadMessages: 0,
      );
      await _expectConversationMarker(
        database,
        accountId: account.id,
        lastReadMessage: 108,
        lastCommonReadMessage: 106,
        unreadMessages: 3,
      );
    },
  );

  test(
    'private policy clears persisted common read until the server restores it',
    () async {
      final accountA = await _prepareAccount(
        database: database,
        accounts: accounts,
        chat: chat,
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
      );
      final accountB = await _prepareAccount(
        database: database,
        accounts: accounts,
        chat: chat,
        accountId: 'account-b',
        serverUrl: 'https://b.example.invalid',
      );
      await _prepareThreadViews(database, chat, accountA);

      expect(
        await chat.applyChatGetResponse(
          await _chatGetResponse(
            chat,
            accountA,
            profile: _commonReadProfile(readPrivacy: 1),
          ),
        ),
        ChatMergeOutcome.converged,
      );
      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: null,
        lastReadMessage: 108,
        lastCommonRead: '0',
        unreadMessages: 3,
      );
      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: 50,
        lastReadMessage: 108,
        lastCommonRead: '0',
        unreadMessages: 3,
      );
      await _expectMarkers(
        chat,
        accountId: accountB.id,
        threadId: null,
        lastReadMessage: 108,
        lastCommonRead: '106',
        unreadMessages: 3,
      );
      await _expectConversationMarker(
        database,
        accountId: accountA.id,
        lastReadMessage: 108,
        lastCommonReadMessage: 0,
        unreadMessages: 3,
      );

      expect(
        await chat.applyChatGetResponse(
          await _chatGetResponse(
            chat,
            accountA,
            profile: _commonReadProfile(readPrivacy: 0),
          ),
        ),
        ChatMergeOutcome.converged,
      );
      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: null,
        lastReadMessage: 108,
        lastCommonRead: '0',
        unreadMessages: 3,
      );

      expect(
        await chat.applyChatGetResponse(
          await _chatGetResponse(
            chat,
            accountA,
            profile: _commonReadProfile(readPrivacy: 0),
            marker: '118',
          ),
        ),
        ChatMergeOutcome.commonReadUpdated,
      );
      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: null,
        lastReadMessage: 108,
        lastCommonRead: '118',
        unreadMessages: 3,
      );
      await _expectMarkers(
        chat,
        accountId: accountA.id,
        threadId: 50,
        lastReadMessage: 108,
        lastCommonRead: '118',
        unreadMessages: 3,
      );
      await _expectConversationMarker(
        database,
        accountId: accountA.id,
        lastReadMessage: 108,
        lastCommonReadMessage: 118,
        unreadMessages: 3,
      );
    },
  );

  test(
    'common read invalidation rolls back with conversation persistence',
    () async {
      final account = await _prepareAccount(
        database: database,
        accounts: accounts,
        chat: chat,
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
      );
      await database.customStatement('''
      CREATE TRIGGER fail_common_read_invalidation
      BEFORE UPDATE ON cached_conversations
      BEGIN
        SELECT RAISE(ABORT, 'forced common read rollback');
      END
    ''');

      await expectLater(
        chat.applyChatGetResponse(
          await _chatGetResponse(
            chat,
            account,
            profile: _commonReadProfile(readPrivacy: 1),
          ),
        ),
        throwsA(anything),
      );

      await _expectMarkers(
        chat,
        accountId: account.id,
        threadId: null,
        lastReadMessage: 108,
        lastCommonRead: '106',
        unreadMessages: 3,
      );
      await _expectConversationMarker(
        database,
        accountId: account.id,
        lastReadMessage: 108,
        lastCommonReadMessage: 106,
        unreadMessages: 3,
      );
    },
  );
}

Future<ChatGetResponse> _chatGetResponse(
  ChatRepository chat,
  StoredAccount account, {
  required ChatCapabilityProfile profile,
  String? marker,
}) async {
  final scope = (await chat.getNetworkScope(
    accountId: account.id,
    roomToken: 'rooma123',
    threadId: null,
  ))!;
  final request = ChatFetchRequest(
    accountId: AccountId.parse(account.id),
    requestId: ChatRequestId.parse('common-read-${marker ?? 'absent'}'),
    server: ServerBase.parse(account.serverUrl),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: profile,
    direction: ChatFetchDirection.future,
    cursor: ChatCursor.parse(scope.futureCursor),
    lastCommonRead: ChatCursor.parse(scope.lastCommonRead),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: 0,
    interactive: true,
    futureConverged: true,
  );
  if (marker == null) {
    return decodeChatGetResponse(
      request: request,
      statusCode: 304,
      body: Uint8List(0),
    );
  }
  return decodeChatGetResponse(
    request: request,
    statusCode: 200,
    body: Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{
              'status': 'ok',
              'statuscode': 200,
              'message': 'OK',
            },
            'data': <Object?>[],
          },
        }),
      ),
    ),
    headers: ChatResponseHeaders.fromMap(<String, String>{
      'X-Chat-Last-Common-Read': marker,
    }),
  );
}

ChatCapabilityProfile _commonReadProfile({required int readPrivacy}) =>
    ChatCapabilityProfile.fromSnapshot(
      CapabilitySnapshot.fromJson(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': <String, Object?>{
            'version': <String, Object?>{
              'major': 34,
              'minor': 0,
              'micro': 1,
              'string': '34.0.1',
              'edition': '',
              'extendedSupport': false,
            },
            'capabilities': <String, Object?>{
              'spreed': <String, Object?>{
                'features': <Object?>['chat-v2', 'chat-read-status'],
                'config': <String, Object?>{
                  'chat': <String, Object?>{'read-privacy': readPrivacy},
                },
                'version': '24.0.2',
              },
            },
          },
        },
      }, context: CapabilityContext.authenticated),
      federated: false,
    );

Future<StoredAccount> _prepareAccount({
  required AppDatabase database,
  required AccountRepository accounts,
  required ChatRepository chat,
  required String accountId,
  required String serverUrl,
}) async {
  final account = await accounts.upsertAccount(
    accountId: accountId,
    serverUrl: serverUrl,
    loginName: 'user-$accountId',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026),
  );
  final roomWire = _roomWire();
  final room = ConversationRoom.fromJson(roomWire);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: account.id,
          token: room.token.value,
          displayName: room.displayName,
          description: room.description,
          lastActivity: room.lastActivity,
          unreadMessages: room.unreadMessages,
          favorite: room.isFavorite,
          rawJson: jsonEncode(roomWire),
        ),
      );
  final conversation = await chat.getConversation(
    accountId: account.id,
    roomToken: room.token.value,
  );
  await chat.recordCapabilities(
    accountId: account.id,
    talkFeatures: const {
      'chat-v2',
      'chat-read-marker',
      'chat-read-last',
      'chat-unread',
      'threads',
    },
    observedAt: DateTime.utc(2026),
  );
  await chat.ensureRootScope(account: account, conversation: conversation!);
  return account;
}

Future<void> _prepareThreadViews(
  AppDatabase database,
  ChatRepository chat,
  StoredAccount account,
) async {
  final conversation = (await chat.getConversation(
    accountId: account.id,
    roomToken: 'rooma123',
  ))!;
  await _insertRootMessage(
    database,
    accountId: account.id,
    messageId: 50,
    namedThread: false,
  );
  await _insertRootMessage(
    database,
    accountId: account.id,
    messageId: 60,
    namedThread: true,
  );
  await chat.ensureThreadScope(
    account: account,
    conversation: conversation,
    threadId: 50,
  );
  await chat.ensureThreadScope(
    account: account,
    conversation: conversation,
    threadId: 60,
  );
  await chat.ensureNamedThreadNetworkScope(
    account: account,
    conversation: conversation,
    threadId: 60,
  );
}

Future<void> _insertRootMessage(
  AppDatabase database, {
  required String accountId,
  required int messageId,
  required bool namedThread,
}) async {
  final wire = _messageWire(messageId: messageId, namedThread: namedThread);
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: 'rooma123',
          messageId: messageId,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 1770000000 + messageId,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-$messageId',
          displayText: 'Message $messageId',
          deleted: false,
          threadId: Value(namedThread ? messageId : null),
          rawJson: jsonEncode(wire),
        ),
      );
}

Map<String, Object?> _roomWire() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  room
    ..['token'] = 'rooma123'
    ..['lastReadMessage'] = 108
    ..['lastCommonReadMessage'] = 106
    ..['unreadMessages'] = 3;
  final lastMessage =
      Map<String, Object?>.from(room['lastMessage']! as Map<String, Object?>)
        ..['token'] = 'rooma123'
        ..['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}

Map<String, Object?> _messageWire({
  required int messageId,
  required bool namedThread,
}) {
  final root =
      readFixtureJson('chat-messages/fixtures/chat-future.response.json')!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final messages = ocs['data']! as List<Object?>;
  final message = Map<String, Object?>.from(
    messages.first! as Map<String, Object?>,
  );
  message
    ..['token'] = 'rooma123'
    ..['id'] = messageId
    ..['timestamp'] = 1770000000 + messageId
    ..['message'] = 'Message $messageId'
    ..['messageParameters'] = <String, Object?>{}
    ..['isThread'] = namedThread;
  if (namedThread) {
    message
      ..['threadId'] = messageId
      ..['threadTitle'] = 'Named thread';
  } else {
    message.remove('threadId');
  }
  return message;
}

ChatReadResponse _readResponse({
  required String accountId,
  required String serverUrl,
  required int lastReadMessage,
  required int lastCommonReadMessage,
  required int unreadMessages,
}) {
  final profile = _profile();
  final request = ChatSetReadMarkerRequest(
    accountId: AccountId.parse(accountId),
    requestId: ChatRequestId.parse('read-$accountId'),
    server: ServerBase.parse(serverUrl),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: profile,
    lastReadMessage: lastReadMessage,
  );
  return decodeChatReadResponse(
    request: request,
    statusCode: 200,
    body: _markerBody(
      lastReadMessage: lastReadMessage,
      lastCommonReadMessage: lastCommonReadMessage,
      unreadMessages: unreadMessages,
    ),
  );
}

ChatReadResponse _unreadResponse({
  required String accountId,
  required String serverUrl,
  required int lastReadMessage,
  required int lastCommonReadMessage,
  required int unreadMessages,
}) {
  final request = ChatMarkUnreadRequest(
    accountId: AccountId.parse(accountId),
    requestId: ChatRequestId.parse('unread-$accountId'),
    server: ServerBase.parse(serverUrl),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    profile: _profile(),
  );
  return decodeChatReadResponse(
    request: request,
    statusCode: 200,
    body: _markerBody(
      lastReadMessage: lastReadMessage,
      lastCommonReadMessage: lastCommonReadMessage,
      unreadMessages: unreadMessages,
    ),
  );
}

ChatCapabilityProfile _profile() =>
    ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
      'chat-v2',
      'chat-read-marker',
      'chat-read-last',
      'chat-unread',
      'threads',
    ], federated: false);

Uint8List _markerBody({
  required int lastReadMessage,
  required int lastCommonReadMessage,
  required int unreadMessages,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'ocs': {
        'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
        'data': {
          'token': 'rooma123',
          'lastReadMessage': lastReadMessage,
          'lastCommonReadMessage': lastCommonReadMessage,
          'unreadMessages': unreadMessages,
        },
      },
    }),
  ),
);

Future<void> _expectMarkers(
  ChatRepository chat, {
  required String accountId,
  required int? threadId,
  required int lastReadMessage,
  required String lastCommonRead,
  required int unreadMessages,
}) async {
  final scope = await chat.getScope(
    accountId: accountId,
    roomToken: 'rooma123',
    threadId: threadId,
  );
  expect(scope?.lastReadMessage, lastReadMessage);
  expect(scope?.lastCommonRead, lastCommonRead);
  expect(scope?.unreadMessages, unreadMessages);
}

Future<void> _expectNetworkMarkers(
  ChatRepository chat, {
  required String accountId,
  required int? threadId,
  required int lastReadMessage,
  required String lastCommonRead,
  required int unreadMessages,
}) async {
  final scope = await chat.getNetworkScope(
    accountId: accountId,
    roomToken: 'rooma123',
    threadId: threadId,
  );
  expect(scope?.lastReadMessage, lastReadMessage);
  expect(scope?.lastCommonRead, lastCommonRead);
  expect(scope?.unreadMessages, unreadMessages);
}

Future<void> _expectConversationMarker(
  AppDatabase database, {
  required String accountId,
  required int lastReadMessage,
  required int lastCommonReadMessage,
  required int unreadMessages,
}) async {
  final row =
      await (database.select(database.cachedConversations)..where(
            (conversation) =>
                conversation.accountId.equals(accountId) &
                conversation.token.equals('rooma123'),
          ))
          .getSingle();
  final wire = jsonDecode(row.rawJson) as Map<String, Object?>;
  expect(row.unreadMessages, unreadMessages);
  expect(wire['lastReadMessage'], lastReadMessage);
  expect(wire['lastCommonReadMessage'], lastCommonReadMessage);
  expect(wire['unreadMessages'], unreadMessages);
}
