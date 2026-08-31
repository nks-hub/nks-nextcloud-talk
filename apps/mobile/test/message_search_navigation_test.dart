import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/features/search/message_search_thread_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late ChatRepository repository;
  late StoredAccount account;
  late CachedConversation conversation;

  setUp(() async {
    database = openTestDatabase();
    repository = ChatRepository(database);
    account = await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    conversation = _conversation(account.id, 'rooma123');
  });

  tearDown(() => database.close());

  test(
    'resolves an ordinary reply from its account-scoped cached root',
    () async {
      await _insertRoot(database, account.id, named: false);
      var synchronized = false;

      final context = await resolveMessageThread(
        repository: repository,
        accountId: account.id,
        target: MessageDestinationTarget.fromSearchResult(
          _result(messageId: 73, threadId: 72),
        ),
        synchronizeThread: () async => synchronized = true,
      );

      expect(context.kind, ChatThreadKind.ordinary);
      expect(context.rootMessageId, 72);
      expect(context.accountId, account.id);
      expect(context.roomToken, 'rooma123');
      expect(synchronized, isFalse);

      final destination =
          buildMessageDestination(
                account: account,
                conversation: conversation,
                target: MessageDestinationTarget.fromSearchResult(
                  _result(messageId: 73, threadId: 72),
                ),
                threadContext: context,
              )
              as MessageSearchThreadScreen;
      expect(destination.threadContext.kind, ChatThreadKind.ordinary);
      expect(destination.jumpToMessageId, 73);
    },
  );

  test(
    'loads and resolves a named root through the responsible sync layer',
    () async {
      var synchronized = false;

      final context = await resolveMessageThread(
        repository: repository,
        accountId: account.id,
        target: MessageDestinationTarget.fromSearchResult(
          _result(messageId: 83, threadId: 80),
        ),
        synchronizeThread: () async {
          synchronized = true;
          await _insertRoot(database, account.id, id: 80, named: true);
        },
      );

      expect(synchronized, isTrue);
      expect(context.kind, ChatThreadKind.named);
      expect(context.rootMessageId, 80);
      expect(context.title, 'Named fixture thread');

      final destination =
          buildMessageDestination(
                account: account,
                conversation: conversation,
                target: MessageDestinationTarget.fromSearchResult(
                  _result(messageId: 83, threadId: 80),
                ),
                threadContext: context,
              )
              as MessageSearchThreadScreen;
      expect(destination.threadContext.kind, ChatThreadKind.named);
      expect(destination.jumpToMessageId, 83);
    },
  );

  test('routes a root search hit to the root pane with its jump target', () {
    final destination =
        buildMessageDestination(
              account: account,
              conversation: conversation,
              target: MessageDestinationTarget.fromSearchResult(
                _result(messageId: 42),
              ),
              threadContext: null,
            )
            as PresenceChatRoomScreen;

    expect(destination.jumpToMessageId, 42);
  });

  test(
    'routes a shared chat message through the same destination contract',
    () {
      final message = ChatMessage.fromJson(
        _messageWire(id: 44, threadId: 44, named: false),
      );
      final destination =
          buildMessageDestination(
                account: account,
                conversation: conversation,
                target: MessageDestinationTarget.fromChatMessage(message),
                threadContext: null,
              )
              as PresenceChatRoomScreen;

      expect(destination.jumpToMessageId, 44);
    },
  );

  test(
    'fails closed when the cached root belongs to another account',
    () async {
      await _insertRoot(database, account.id, id: 90, named: true);

      expect(
        () => resolveMessageThread(
          repository: repository,
          accountId: 'account-b',
          target: MessageDestinationTarget.fromSearchResult(
            _result(messageId: 93, threadId: 90),
          ),
          synchronizeThread: () async {},
        ),
        throwsA(
          isA<MessageSearchThreadException>().having(
            (error) => error.code,
            'code',
            MessageSearchThreadError.unavailable,
          ),
        ),
      );
    },
  );

  test('keeps a root-sync network failure distinct from an absent root', () {
    expect(
      () => resolveMessageThread(
        repository: repository,
        accountId: account.id,
        target: MessageDestinationTarget.fromSearchResult(
          _result(messageId: 93, threadId: 90),
        ),
        synchronizeThread: () async =>
            throw const ChatServiceException(ChatServiceError.network),
      ),
      throwsA(
        isA<MessageSearchThreadException>().having(
          (error) => error.code,
          'code',
          MessageSearchThreadError.network,
        ),
      ),
    );
  });

  test(
    'fails closed when a cached target contradicts the search thread',
    () async {
      await _insertRoot(database, account.id, id: 100, named: false);
      await _insertMessage(database, account.id, id: 103, threadId: 99);

      expect(
        () => resolveMessageThread(
          repository: repository,
          accountId: account.id,
          target: MessageDestinationTarget.fromSearchResult(
            _result(messageId: 103, threadId: 100),
          ),
          synchronizeThread: () async {},
        ),
        throwsA(
          isA<MessageSearchThreadException>().having(
            (error) => error.code,
            'code',
            MessageSearchThreadError.unavailable,
          ),
        ),
      );
    },
  );

  testWidgets('thread screen forwards the reply jump into the resolved scope', (
    tester,
  ) async {
    await _insertRoot(database, account.id, id: 110, named: true);
    final root = await repository.getMessage(
      accountId: account.id,
      roomToken: conversation.token,
      messageId: 110,
    );
    final context = ChatThreadContext.fromCachedRoot(
      accountId: account.id,
      roomToken: conversation.token,
      root: root!,
    )!;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(MemoryCredentialVault()),
          chatMessagesProvider.overrideWith(
            (ref, key) => Stream.value(<CachedChatMessage>[root]),
          ),
          outgoingMessageStatusesProvider.overrideWith(
            (ref, key) => Stream.value(const []),
          ),
          textSendOperationsProvider.overrideWith(
            (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
          ),
          chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
          connectivityWakeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
        ],
        child: localizedTestApp(
          home: MessageSearchThreadScreen(
            account: account,
            conversation: conversation,
            threadContext: context,
            jumpToMessageId: 113,
          ),
        ),
      ),
    );

    await _pumpUntil(
      tester,
      () =>
          tester
              .widget<ChatRoomPane>(find.byType(ChatRoomPane))
              .threadContext ==
          context,
    );
    final pane = tester.widget<ChatRoomPane>(find.byType(ChatRoomPane));
    expect(pane.threadId, 110);
    expect(pane.threadContext, context);
    expect(pane.jumpToMessageId, 113);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Named fixture thread'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
  });

  testWidgets(
    'search-opened thread follows a live ordinary-to-named send binding',
    (tester) async {
      conversation = await _insertConversation(database, account.id);
      await _insertRoot(database, account.id, id: 120, named: false);
      final root = await repository.getMessage(
        accountId: account.id,
        roomToken: conversation.token,
        messageId: 120,
      );
      final initialContext = ChatThreadContext.fromCachedRoot(
        accountId: account.id,
        roomToken: conversation.token,
        root: root!,
      )!;
      final vault = MemoryCredentialVault()
        ..values[account.id] = 'fixture-app-password';
      final posts = <Map<String, String>>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                capabilitiesJson(
                  talkFeatures: const <String>[
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                    'chat-replies',
                    'threads',
                  ],
                ),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/apps/spreed/api/v1/chat/rooma123')) {
            posts.add(Map<String, String>.from(request.bodyFields));
            return http.Response('', 400);
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/apps/spreed/api/v1/chat/rooma123')) {
            return http.Response('', 304);
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            credentialVaultProvider.overrideWithValue(vault),
            nextcloudApiProvider.overrideWithValue(api),
            chatMessagesProvider.overrideWith(
              (ref, key) => repository.watchMessages(
                accountId: key.accountId,
                roomToken: key.roomToken,
                threadId: key.threadId,
              ),
            ),
            outgoingMessageStatusesProvider.overrideWith(
              (ref, key) => Stream.value(const []),
            ),
            textSendOperationsProvider.overrideWith(
              (ref, key) => Stream.value(const <StoredTextSendOperation>[]),
            ),
            chatScopeProvider.overrideWith((ref, key) => Stream.value(null)),
            connectivityWakeEventsProvider.overrideWithValue(
              const Stream<void>.empty(),
            ),
            chatAttachmentDependenciesProvider.overrideWith(
              (ref, key) => Future<ChatAttachmentDependencies>.error(
                StateError('transport is outside this route test'),
                StackTrace.empty,
              ),
            ),
          ],
          child: localizedTestApp(
            home: MessageSearchThreadScreen(
              account: account,
              conversation: conversation,
              threadContext: initialContext,
              jumpToMessageId: 123,
            ),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(ChatRoomPane).evaluate().isNotEmpty,
      );
      expect(find.text('Thread'), findsOneWidget);
      expect(
        tester
            .widget<ChatRoomPane>(find.byType(ChatRoomPane))
            .threadContext
            ?.kind,
        ChatThreadKind.ordinary,
      );

      await (database.update(database.cachedChatMessages)..where(
            (row) =>
                row.accountId.equals(account.id) &
                row.roomToken.equals(conversation.token) &
                row.messageId.equals(120),
          ))
          .write(
            CachedChatMessagesCompanion(
              rawJson: Value(
                jsonEncode(_messageWire(id: 120, threadId: 120, named: true)),
              ),
            ),
          );
      await _pumpUntil(
        tester,
        () => find.text('Named fixture thread').evaluate().isNotEmpty,
      );

      final pane = tester.widget<ChatRoomPane>(find.byType(ChatRoomPane));
      expect(pane.threadId, 120);
      expect(pane.threadContext?.kind, ChatThreadKind.named);
      expect(pane.threadContext?.replyTo, null);
      expect(pane.threadContext?.networkThreadId, 120);
      expect(pane.jumpToMessageId, 123);
      final mediaBinding = pane.threadContext!.mediaBinding(
        accountId: AccountId.parse(account.id),
        roomToken: ConversationToken.parse(
          conversation.token,
          path: r'$.roomToken',
        ),
      );
      expect(mediaBinding.replyTo, null);
      expect(mediaBinding.threadId, 120);

      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('chat-composer')).evaluate().isNotEmpty &&
            tester
                    .widget<IconButton>(find.byKey(const Key('send-message')))
                    .onPressed !=
                null,
      );
      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'Search route send',
      );
      tester
          .widget<IconButton>(find.byKey(const Key('send-message')))
          .onPressed!();
      await _pumpUntil(tester, () => posts.isNotEmpty);
      expect(posts.single['threadId'], '120');
      expect(posts.single.containsKey('replyTo'), isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await _settleDisposal(tester);
    },
  );
}

Future<CachedConversation> _insertConversation(
  AppDatabase database,
  String accountId,
) async {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final roomJson = Map<String, Object?>.from(
    (ocs['data']! as List<Object?>).first! as Map<String, Object?>,
  );
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: accountId,
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
          rawJson: jsonEncode(roomJson),
        ),
      );
  return database.select(database.cachedConversations).getSingle();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}

Future<void> _settleDisposal(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

MessageSearchResult _result({required int messageId, int? threadId}) {
  return parseMessageSearchResult(<String, Object?>{
    'title': 'Fixture author',
    'subline': 'Fixture matching message',
    'resourceUrl':
        'https://cloud.example.invalid/call/rooma123'
        '${threadId == null ? '' : '?threadId=$threadId'}'
        '#message_$messageId',
    'attributes': <String, Object?>{
      'conversation': 'rooma123',
      'messageId': '$messageId',
      if (threadId != null) 'threadId': '$threadId',
    },
  }, path: r'$');
}

Future<void> _insertRoot(
  AppDatabase database,
  String accountId, {
  int id = 72,
  required bool named,
}) {
  return _insertMessage(
    database,
    accountId,
    id: id,
    threadId: id,
    named: named,
  );
}

Future<void> _insertMessage(
  AppDatabase database,
  String accountId, {
  required int id,
  required int threadId,
  bool named = false,
}) {
  final wire = _messageWire(id: id, threadId: threadId, named: named);
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: 'rooma123',
          messageId: id,
          actorType: 'users',
          actorId: 'fixture-author',
          actorDisplayName: 'Fixture author',
          timestamp: 1724300000 + id,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-$id',
          displayText: named ? 'Named fixture thread' : 'Fixture message $id',
          deleted: false,
          threadId: Value(threadId),
          rawJson: jsonEncode(wire),
        ),
      );
}

Map<String, Object?> _messageWire({
  required int id,
  required int threadId,
  required bool named,
}) => <String, Object?>{
  'id': id,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-author',
  'actorDisplayName': 'Fixture author',
  'timestamp': 1724300000 + id,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-$id',
  'message': named ? 'Named fixture thread' : 'Fixture message $id',
  'messageParameters': <String, Object?>{},
  'markdown': false,
  'reactions': <String, Object?>{},
  'threadId': threadId,
  'isThread': named,
  if (named) 'threadTitle': 'Named fixture thread',
};

CachedConversation _conversation(String accountId, String token) {
  return CachedConversation(
    accountId: accountId,
    token: token,
    displayName: 'Fixture room',
    description: '',
    lastActivity: 1,
    unreadMessages: 0,
    favorite: false,
    isArchived: false,
    readOnly: 0,
    roomType: 2,
    roomName: '',
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    peerStatus: null,
    peerStatusIcon: null,
    peerStatusMessage: null,
    lastMessageText: null,
    lastMessageTimestamp: null,
    rawJson: '{}',
  );
}
