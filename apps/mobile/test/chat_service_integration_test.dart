import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ChatRepository chat;
  late MemoryCredentialVault credentials;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
    credentials = MemoryCredentialVault();

    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    credentials.values[account.id] = 'fixture-app-password-never-use';

    final roomJson = _conversationRoomJson();
    final room = ConversationRoom.fromJson(roomJson);
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
            readOnly: Value(room.readOnly),
            roomType: Value(room.type),
            roomName: Value(room.name),
            objectType: Value(room.objectType),
            avatarVersion: Value(room.avatarVersion),
            isCustomAvatar: Value(room.isCustomAvatar),
            rawJson: jsonEncode(roomJson),
          ),
        );
  });

  tearDown(() => database.close());

  test('sync stores history and future catch-up messages in Drift', () async {
    var historyRequests = 0;
    var futureRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_chatCapabilities()), 200);
        }
        expect(request.method, 'GET');
        expect(request.url.path, endsWith('/apps/spreed/api/v1/chat/rooma123'));
        expect(request.headers['Authorization'], startsWith('Basic '));

        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          historyRequests++;
          expect(request.url.queryParameters['lastKnownMessageId'], '109');
          expect(request.url.queryParameters['includeLastKnown'], '1');
          return http.Response(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-history.response.json',
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '103',
              'X-Chat-Last-Common-Read': '100',
            },
          );
        }

        futureRequests++;
        if (futureRequests == 1) {
          expect(request.url.queryParameters['lastKnownMessageId'], '109');
          return http.Response(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-future.response.json',
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '114',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }
        expect(futureRequests, 2);
        expect(request.url.queryParameters['lastKnownMessageId'], '114');
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

    final messages = await chat
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final scope = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(historyRequests, 1);
    expect(futureRequests, 2);
    expect(messages.map((message) => message.messageId), [105, 108, 110, 112]);
    expect(messages.map((message) => message.displayText), [
      'Synthetic older history message',
      'Synthetic newest history message',
      'Synthetic first future message',
      'Synthetic second future message',
    ]);
    expect(scope?.historyCursor, '103');
    expect(scope?.futureCursor, '114');
    expect(scope?.futureConverged, isTrue);
    expect(scope?.lastSyncError, isNull);
  });

  test(
    'a poll overtaken by another writer is discarded without an error',
    () async {
      // Reproduces the live emulator finding: an attachment confirmation
      // advances the future cursor while the room poll is still in flight. The
      // overtaken answer must be dropped silently instead of surfacing as a
      // rejected chat response.
      final overtakenPollReached = Completer<void>();
      final overtakingSyncFinished = Completer<void>();
      var futureRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_chatCapabilities()), 200);
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }

          futureRequests++;
          if (request.url.queryParameters['lastKnownMessageId'] != '109') {
            return http.Response('', 304);
          }
          final overtaken = futureRequests == 1;
          if (overtaken) {
            overtakenPollReached.complete();
            await overtakingSyncFinished.future;
          }
          return http.Response(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-future.response.json',
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '114',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }),
      );
      addTearDown(api.close);

      ChatService service() => ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      final overtakenSync = service().syncRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      await overtakenPollReached.future;
      await service().syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      overtakingSyncFinished.complete();
      await overtakenSync;

      final scope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final messages = await chat
          .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      expect(scope?.futureCursor, '114');
      expect(scope?.lastSyncError, isNull);
      expect(messages.map((message) => message.messageId), contains(112));
    },
  );

  test('completed live cycles release their cancellation wait', () async {
    var futureRequests = 0;
    final pendingPollStarted = Completer<void>();
    final api = HttpNextcloudApi(
      client: MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _streamedResponse(jsonEncode(_chatCapabilities()), 200);
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return _streamedResponse('', 304);
        }

        futureRequests++;
        if (futureRequests <= 65) {
          return _streamedResponse('', 304);
        }

        expect(futureRequests, 66);
        expect(request, isA<http.Abortable>());
        pendingPollStarted.complete();
        await (request as http.Abortable).abortTrigger!;
        throw http.RequestAbortedException(request.url);
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final binding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    addTearDown(binding.close);

    await binding.synchronize();
    expect(binding.debugActiveCancellationCycleCount, 0);
    for (var cycle = 0; cycle < 64; cycle++) {
      await binding.synchronize();
      expect(
        binding.debugActiveCancellationCycleCount,
        0,
        reason: 'completed cycle $cycle retained a cancellation wait',
      );
    }

    final pendingPoll = binding.synchronize();
    await pendingPollStarted.future;
    expect(binding.debugActiveCancellationCycleCount, 1);
    binding.close();
    await pendingPoll;
    expect(binding.debugActiveCancellationCycleCount, 0);
    expect(futureRequests, 66);
  });

  test(
    'live room binding long polls and updates chat plus conversation preview',
    () async {
      var futureRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_chatCapabilities()), 200);
          }
          expect(request.method, 'GET');
          expect(
            request.url.path,
            endsWith('/apps/spreed/api/v1/chat/rooma123'),
          );
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }

          futureRequests++;
          if (futureRequests == 1) {
            expect(request.url.queryParameters['timeout'], '0');
            expect(request.url.queryParameters['lastKnownMessageId'], '109');
            return http.Response('', 304);
          }

          if (futureRequests == 2) {
            expect(request.url.queryParameters['timeout'], '30');
            expect(request.url.queryParameters['lastKnownMessageId'], '109');
            return http.Response(
              jsonEncode(
                _externalMessageResponse(
                  messageId: 120,
                  timestamp: 1770000120,
                  message: _giphyResourceUrl,
                ),
              ),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '120',
                'X-Chat-Last-Common-Read': '110',
              },
            );
          }

          expect(futureRequests, 3);
          expect(request.url.queryParameters['timeout'], '0');
          expect(request.url.queryParameters['lastKnownMessageId'], '120');
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      await binding.synchronize();
      await binding.synchronize();
      await binding.synchronize();

      final messages = await chat
          .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      final conversation = await chat.getConversation(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final scope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(futureRequests, 3);
      expect(messages.map((message) => message.messageId), [120]);
      expect(messages.single.displayText, 'GIF');
      expect(messages.single.displayText, isNot(_giphyResourceUrl));
      expect(scope?.futureCursor, '120');
      expect(scope?.futureConverged, isTrue);
      expect(scope?.lastSyncError, isNull);
      expect(conversation?.lastMessageText, 'GIF');
      expect(conversation?.lastMessageText, isNot(_giphyResourceUrl));
      expect(conversation?.lastMessageTimestamp, 1770000120);
      expect(conversation?.lastActivity, 1770000120);
    },
  );

  test(
    'reply-chain binding polls the room and clears its view error',
    () async {
      await _cacheThreadRoot(database, storedThreadId: null);
      final account = (await accounts.getAccount('account-a'))!;
      final conversation = (await chat.getConversation(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ))!;
      await chat.ensureThreadScope(
        account: account,
        conversation: conversation,
        threadId: 109,
      );
      await chat.recordRoomError(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
        errorCode: 'invalidResponse',
      );
      final rootScopes = database.chatScopes.createAlias('root_scopes');
      final viewScopes = database.chatScopes.createAlias('view_scopes');
      final projectionStates = <(StoredChatScope, StoredChatScope)>[];
      final projected = Completer<void>();
      final projectionQuery =
          database.select(rootScopes).join([
            innerJoin(
              viewScopes,
              viewScopes.accountId.equalsExp(rootScopes.accountId) &
                  viewScopes.roomToken.equalsExp(rootScopes.roomToken) &
                  viewScopes.scopeKey.equals('thread:109'),
            ),
          ])..where(
            rootScopes.accountId.equals('account-a') &
                rootScopes.roomToken.equals('rooma123') &
                rootScopes.scopeKey.equals('root'),
          );
      final projectionSubscription = projectionQuery.watch().listen((rows) {
        if (rows.isEmpty) {
          return;
        }
        final state = (
          rows.single.readTable(rootScopes),
          rows.single.readTable(viewScopes),
        );
        projectionStates.add(state);
        if (state.$1.futureCursor == '120' && !projected.isCompleted) {
          projected.complete();
        }
      });
      addTearDown(projectionSubscription.cancel);

      var historyRequests = 0;
      var futureRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: const <String>[
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                    'threads',
                  ],
                ),
              ),
              200,
            );
          }
          expect(request.url.queryParameters, isNot(contains('threadId')));
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            historyRequests++;
            expect(request.url.queryParameters['lastKnownMessageId'], '109');
            return http.Response('', 304);
          }

          futureRequests++;
          if (futureRequests == 1) {
            expect(request.url.queryParameters['timeout'], '0');
            expect(request.url.queryParameters['lastKnownMessageId'], '109');
            return http.Response('', 304);
          }

          expect(futureRequests, 2);
          expect(request.url.queryParameters['timeout'], '30');
          expect(request.url.queryParameters['lastKnownMessageId'], '109');
          return http.Response(
            jsonEncode(
              _externalMessageResponse(
                messageId: 120,
                timestamp: 1770000120,
                message: 'External reply-chain message',
                threadId: 109,
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '120',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );

      await binding.synchronize();
      await binding.synchronize();
      await projected.future;

      final messages = await chat
          .watchMessages(
            accountId: 'account-a',
            roomToken: 'rooma123',
            threadId: 109,
          )
          .first;
      final rootMessages = await chat
          .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      final scope = await chat.getScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      final rootScope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(historyRequests, 1);
      expect(futureRequests, 2);
      expect(messages.map((message) => message.messageId), [109, 120]);
      expect(messages.last.displayText, 'External reply-chain message');
      expect(rootMessages.map((message) => message.messageId), [109]);
      expect(scope?.hasHistory, isFalse);
      expect(scope?.lastSyncError, isNull);
      expect(rootScope?.futureCursor, '120');
      expect(scope?.historyCursor, rootScope?.historyCursor);
      expect(scope?.futureCursor, rootScope?.futureCursor);
      expect(scope?.lastCommonRead, rootScope?.lastCommonRead);
      expect(scope?.lastReadMessage, rootScope?.lastReadMessage);
      expect(scope?.unreadMessages, rootScope?.unreadMessages);
      expect(scope?.futureConverged, rootScope?.futureConverged);
      expect(scope?.blocksJson, rootScope?.blocksJson);
      expect(scope?.lastSyncedAtMillis, rootScope?.lastSyncedAtMillis);
      expect(
        projectionStates.where((state) => state.$1.futureCursor == '120'),
        everyElement(
          predicate<(StoredChatScope, StoredChatScope)>(
            (state) =>
                state.$2.futureCursor == state.$1.futureCursor &&
                state.$2.blocksJson == state.$1.blocksJson &&
                state.$2.lastReadMessage == state.$1.lastReadMessage &&
                state.$2.unreadMessages == state.$1.unreadMessages &&
                state.$2.futureConverged == state.$1.futureConverged &&
                state.$2.lastSyncedAtMillis == state.$1.lastSyncedAtMillis,
          ),
        ),
      );
    },
  );

  test('cache-miss reply chain falls back from thread 404 to root', () async {
    var dedicatedRequests = 0;
    var rootHistoryRequests = 0;
    var rootFutureRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'threads',
                ],
              ),
            ),
            200,
          );
        }
        if (request.url.queryParameters.containsKey('threadId')) {
          dedicatedRequests++;
          expect(request.url.queryParameters['threadId'], '109');
          return http.Response(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-thread-not-found.response.json',
              ),
            ),
            404,
          );
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          rootHistoryRequests++;
          return http.Response(
            jsonEncode(
              _externalMessageResponse(
                messageId: 109,
                timestamp: 1770000109,
                message: 'Hydrated ordinary root',
                threadId: 109,
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '108',
              'X-Chat-Last-Common-Read': '100',
            },
          );
        }
        rootFutureRequests++;
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final binding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );

    await binding.synchronize();

    final messages = await chat
        .watchMessages(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;
    final scope = await chat.getScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    expect(dedicatedRequests, 1);
    expect(rootHistoryRequests, 1);
    expect(rootFutureRequests, 1);
    expect(messages.map((message) => message.messageId), [109]);
    expect(messages.single.displayText, 'Hydrated ordinary root');
    expect(scope?.lastSyncError, isNull);
  });

  test(
    'sync resolves an older reply root from an already synced root scope',
    () async {
      final account = (await accounts.getAccount('account-a'))!;
      final conversation = (await chat.getConversation(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ))!;
      await chat.ensureRootScope(account: account, conversation: conversation);
      await (database.update(database.chatScopes)..where(
            (scope) =>
                scope.accountId.equals('account-a') &
                scope.roomToken.equals('rooma123') &
                scope.threadId.isNull(),
          ))
          .write(
            const ChatScopesCompanion(
              historyCursor: Value('120'),
              futureCursor: Value('120'),
              blocksJson: Value('[["120","120"]]'),
              hasHistory: Value(true),
              futureConverged: Value(true),
              lastSyncedAtMillis: Value(1),
            ),
          );

      var dedicatedRequests = 0;
      var rootHistoryRequests = 0;
      var rootFutureRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: const <String>[
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                    'threads',
                  ],
                ),
              ),
              200,
            );
          }
          if (request.url.queryParameters.containsKey('threadId')) {
            dedicatedRequests++;
            return http.Response(
              jsonEncode(
                readFixtureJson(
                  'chat-messages/fixtures/chat-thread-not-found.response.json',
                ),
              ),
              404,
            );
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            rootHistoryRequests++;
            expect(request.url.queryParameters['lastKnownMessageId'], '120');
            expect(request.url.queryParameters['includeLastKnown'], '0');
            return http.Response(
              jsonEncode(
                _externalMessageResponse(
                  messageId: 109,
                  timestamp: 1770000109,
                  message: 'Older ordinary root',
                  threadId: 109,
                ),
              ),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '109',
                'X-Chat-Last-Common-Read': '100',
              },
            );
          }
          rootFutureRequests++;
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      await service.syncRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );

      final messages = await chat
          .watchMessages(
            accountId: 'account-a',
            roomToken: 'rooma123',
            threadId: 109,
          )
          .first;
      final rootScope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final viewScope = await chat.getScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      expect(dedicatedRequests, 1);
      expect(rootHistoryRequests, 1);
      expect(rootFutureRequests, 1);
      expect(messages.map((message) => message.messageId), [109]);
      expect(rootScope?.lastSyncedAtMillis, isNotNull);
      expect(viewScope?.lastSyncedAtMillis, rootScope?.lastSyncedAtMillis);
      expect(viewScope?.lastSyncError, isNull);
    },
  );

  test('cache-miss ordinary reply works without thread fetch', () async {
    var dedicatedRequests = 0;
    var rootHistoryRequests = 0;
    var rootFutureRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_chatCapabilities()), 200);
        }
        if (request.url.queryParameters.containsKey('threadId')) {
          dedicatedRequests++;
          return http.Response('', 500);
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          rootHistoryRequests++;
          return http.Response(
            jsonEncode(
              _externalMessageResponse(
                messageId: 109,
                timestamp: 1770000109,
                message: 'Capability-safe ordinary root',
                threadId: 109,
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '109',
              'X-Chat-Last-Common-Read': '100',
            },
          );
        }
        rootFutureRequests++;
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final binding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );

    await binding.synchronize();

    final messages = await chat
        .watchMessages(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;
    expect(dedicatedRequests, 0);
    expect(rootHistoryRequests, 1);
    expect(rootFutureRequests, 1);
    expect(messages.map((message) => message.messageId), [109]);
  });

  test('federated cache-miss ordinary reply uses the root endpoint', () async {
    final conversation = (await chat.getConversation(
      accountId: 'account-a',
      roomToken: 'rooma123',
    ))!;
    final rawConversation =
        jsonDecode(conversation.rawJson) as Map<String, Object?>;
    rawConversation['remoteServer'] = 'remote.example.invalid';
    await (database.update(database.cachedConversations)..where(
          (row) =>
              row.accountId.equals('account-a') & row.token.equals('rooma123'),
        ))
        .write(
          CachedConversationsCompanion(
            rawJson: Value(jsonEncode(rawConversation)),
          ),
        );

    var dedicatedRequests = 0;
    var rootRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'threads',
                ],
              ),
            ),
            200,
          );
        }
        if (request.url.queryParameters.containsKey('threadId')) {
          dedicatedRequests++;
          return http.Response('', 500);
        }
        rootRequests++;
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return http.Response(
            jsonEncode(
              _externalMessageResponse(
                messageId: 109,
                timestamp: 1770000109,
                message: 'Federated ordinary root',
                threadId: 109,
              ),
            ),
            200,
            headers: const <String, String>{
              'X-Chat-Last-Given': '109',
              'X-Chat-Last-Common-Read': '100',
            },
          );
        }
        return http.Response('', 304);
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final binding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );

    await binding.synchronize();

    final messages = await chat
        .watchMessages(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;
    expect(dedicatedRequests, 0);
    expect(rootRequests, 2);
    expect(messages.map((message) => message.messageId), [109]);
  });

  test(
    'loadOlder maps an unresolved thread fallback to a public error',
    () async {
      var dedicatedRequests = 0;
      var rootHistoryRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: const <String>[
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                    'threads',
                  ],
                ),
              ),
              200,
            );
          }
          if (request.url.queryParameters.containsKey('threadId')) {
            dedicatedRequests++;
            return http.Response(
              jsonEncode(
                readFixtureJson(
                  'chat-messages/fixtures/chat-thread-not-found.response.json',
                ),
              ),
              404,
            );
          }
          rootHistoryRequests++;
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );

      await expectLater(
        service.loadOlder(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        ),
        throwsA(
          isA<ChatServiceException>().having(
            (error) => error.code,
            'code',
            ChatServiceError.invalidResponse,
          ),
        ),
      );

      final scope = await chat.getScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      expect(dedicatedRequests, 1);
      expect(rootHistoryRequests, 1);
      expect(scope?.lastSyncError, ChatServiceError.invalidResponse.name);
    },
  );

  test('root and reply-chain bindings share one root network poll', () async {
    await _cacheThreadRoot(database, storedThreadId: null);
    final account = (await accounts.getAccount('account-a'))!;
    final conversation = (await chat.getConversation(
      accountId: 'account-a',
      roomToken: 'rooma123',
    ))!;
    await chat.ensureThreadScope(
      account: account,
      conversation: conversation,
      threadId: 109,
    );
    await chat.recordRoomError(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
      errorCode: 'invalidResponse',
    );

    var liveRequests = 0;
    final firstLiveRequest = Completer<void>();
    final releaseLiveResponse = Completer<void>();
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'threads',
                ],
              ),
            ),
            200,
          );
        }
        expect(request.url.queryParameters, isNot(contains('threadId')));
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return http.Response('', 304);
        }
        if (request.url.queryParameters['timeout'] == '0') {
          return http.Response('', 304);
        }

        liveRequests++;
        if (!firstLiveRequest.isCompleted) {
          firstLiveRequest.complete();
        }
        await releaseLiveResponse.future;
        final response = _sendReplyResponse(
          referenceId: '88888888-8888-4888-8888-888888888888',
          message: 'Shared root poll reply',
          replyTo: 109,
        );
        final ocs = response['ocs']! as Map<String, Object?>;
        final meta = ocs['meta']! as Map<String, Object?>;
        meta['statuscode'] = 200;
        final reply = ocs['data']! as Map<String, Object?>;
        reply['id'] = 120;
        reply['timestamp'] = 1770000120;
        final parent = reply['parent']! as Map<String, Object?>;
        parent['isThread'] = true;
        parent['threadReplies'] = 1;
        ocs['data'] = <Object?>[reply];
        return http.Response(
          jsonEncode(response),
          200,
          headers: const <String, String>{
            'X-Chat-Last-Given': '120',
            'X-Chat-Last-Common-Read': '110',
          },
        );
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final rootBinding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final replyBinding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );

    await rootBinding.synchronize();
    await replyBinding.synchronize();
    final rootPoll = rootBinding.synchronize();
    final replyPoll = replyBinding.synchronize();
    await firstLiveRequest.future;
    final replyCatchUp = service.catchUpRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    await Future<void>.delayed(Duration.zero);
    releaseLiveResponse.complete();
    await Future.wait([rootPoll, replyPoll, replyCatchUp]);

    final rootScope = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final replyScope = await chat.getScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    final replies = await chat
        .watchMessages(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;
    final cachedRootIsNamed = await chat.cachedRootIsNamedThread(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    expect(liveRequests, 1);
    expect(rootScope?.futureCursor, '120');
    expect(rootScope?.lastSyncError, isNull);
    expect(replyScope?.lastSyncError, isNull);
    expect(cachedRootIsNamed, isTrue);
    expect(
      decodeChatScopeBlocks(
        replyScope!.blocksJson,
      ).any((block) => block.contains(ChatCursor.parse('120'))),
      isTrue,
    );
    expect(replies.map((message) => message.messageId), [109, 120]);
  });

  test('shared root poll aborts only after every binding cancels', () async {
    await _cacheThreadRoot(database, storedThreadId: null);
    var liveRequests = 0;
    final livePollStarted = Completer<void>();
    final transportAborted = Completer<void>();
    final api = HttpNextcloudApi(
      client: MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _streamedResponse(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'threads',
                ],
              ),
            ),
            200,
          );
        }
        expect(request.url.queryParameters, isNot(contains('threadId')));
        if (request.url.queryParameters['lookIntoFuture'] == '0' ||
            request.url.queryParameters['timeout'] == '0') {
          return _streamedResponse('', 304);
        }

        liveRequests++;
        expect(request, isA<http.Abortable>());
        final abortTrigger = (request as http.Abortable).abortTrigger;
        expect(abortTrigger, isNotNull);
        livePollStarted.complete();
        await abortTrigger;
        transportAborted.complete();
        throw http.RequestAbortedException(request.url);
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final rootBinding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final replyBinding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    await rootBinding.synchronize();
    await replyBinding.synchronize();

    final rootCancellation = Completer<void>();
    final replyCancellation = Completer<void>();
    final rootPoll = rootBinding.synchronize(
      abortTrigger: rootCancellation.future,
    );
    final replyPoll = replyBinding.synchronize(
      abortTrigger: replyCancellation.future,
    );
    await livePollStarted.future;
    rootCancellation.complete();
    await rootPoll;
    expect(transportAborted.isCompleted, isFalse);

    replyCancellation.complete();
    await replyPoll;
    await transportAborted.future;

    final rootScope = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final replyScope = await chat.getScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    expect(liveRequests, 1);
    expect(rootScope?.lastSyncError, isNull);
    expect(replyScope?.lastSyncError, isNull);
  });

  test(
    'cancelled shared poll is replaced before its transport completes',
    () async {
      await _cacheThreadRoot(database, storedThreadId: null);
      var liveRequests = 0;
      final firstPollStarted = Completer<void>();
      final firstPollAborted = Completer<void>();
      final releaseFirstPoll = Completer<void>();
      final secondPollStarted = Completer<void>();
      final api = HttpNextcloudApi(
        client: MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _streamedResponse(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: const <String>[
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                    'threads',
                  ],
                ),
              ),
              200,
            );
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0' ||
              request.url.queryParameters['timeout'] == '0') {
            return _streamedResponse('', 304);
          }

          liveRequests++;
          if (liveRequests == 1) {
            firstPollStarted.complete();
            final abortTrigger = (request as http.Abortable).abortTrigger!;
            await abortTrigger;
            firstPollAborted.complete();
            await releaseFirstPoll.future;
            return _streamedResponse(
              jsonEncode(
                _externalMessageResponse(
                  messageId: 130,
                  timestamp: 1770000130,
                  message: 'Cancelled stale response',
                ),
              ),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '130',
                'X-Chat-Last-Common-Read': '110',
              },
            );
          }

          secondPollStarted.complete();
          return _streamedResponse('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final firstBinding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final replacementBinding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      await firstBinding.synchronize();
      await replacementBinding.synchronize();

      final cancellation = Completer<void>();
      final firstPoll = firstBinding.synchronize(
        abortTrigger: cancellation.future,
      );
      await firstPollStarted.future;
      cancellation.complete();
      await firstPoll;
      await firstPollAborted.future;

      final replacementPoll = replacementBinding.synchronize();
      await secondPollStarted.future.timeout(const Duration(seconds: 2));
      releaseFirstPoll.complete();
      await replacementPoll;
      await Future<void>.delayed(Duration.zero);

      final messages = await chat
          .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      expect(liveRequests, 2);
      expect(
        messages.map((message) => message.messageId),
        isNot(contains(130)),
      );
    },
  );

  test(
    'named thread binding keeps its dedicated network query and scope',
    () async {
      await _cacheThreadRoot(database, isThread: true);
      var futureRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: const <String>[
                    'conversation-v4',
                    'chat-v2',
                    'chat-reference-id',
                    'threads',
                  ],
                ),
              ),
              200,
            );
          }
          expect(request.url.queryParameters['threadId'], '109');
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }

          futureRequests++;
          if (futureRequests == 1) {
            expect(request.url.queryParameters['timeout'], '0');
            expect(request.url.queryParameters['lastKnownMessageId'], '109');
            return http.Response('', 304);
          }

          if (futureRequests == 2) {
            expect(request.url.queryParameters['timeout'], '30');
            expect(request.url.queryParameters['lastKnownMessageId'], '109');
            return http.Response(
              jsonEncode(
                _externalMessageResponse(
                  messageId: 120,
                  timestamp: 1770000120,
                  message: 'External thread message',
                  threadId: 109,
                ),
              ),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '120',
                'X-Chat-Last-Common-Read': '110',
              },
            );
          }

          expect(futureRequests, 3);
          expect(request.url.queryParameters['timeout'], '0');
          expect(request.url.queryParameters['lastKnownMessageId'], '120');
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );

      await binding.synchronize();
      await binding.synchronize();
      await binding.synchronize();

      final messages = await chat
          .watchMessages(
            accountId: 'account-a',
            roomToken: 'rooma123',
            threadId: 109,
          )
          .first;
      final rootMessages = await chat
          .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      final scope = await chat.getScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      expect(futureRequests, 3);
      expect(messages.map((message) => message.messageId), [109, 120]);
      expect(messages.last.displayText, 'External thread message');
      expect(rootMessages.map((message) => message.messageId), [109]);
      expect(scope?.futureCursor, '120');
      expect(scope?.futureConverged, isTrue);
      expect(scope?.lastSyncError, isNull);
    },
  );

  test(
    'live binding re-prepares before polling after capability epoch changes',
    () async {
      const initialFeatures = <String>[
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
      ];
      const updatedFeatures = <String>[
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
        'chat-keep-notifications',
      ];
      var capabilityRequests = 0;
      var now = DateTime.utc(2026, 8, 25, 12);
      final futureTimeouts = <String?>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests++;
            return http.Response(
              jsonEncode(
                _chatCapabilities(
                  talkFeatures: capabilityRequests == 1
                      ? initialFeatures
                      : updatedFeatures,
                ),
              ),
              200,
            );
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }
          futureTimeouts.add(request.url.queryParameters['timeout']);
          return http.Response('', 304);
        }),
        clock: () => now,
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      await binding.synchronize();
      await accounts.updateTalkFeatures('account-a', updatedFeatures.toSet());
      // The server grows a feature only after the first snapshot has fallen out
      // of its validity window, so the re-prepare reads the new epoch fresh.
      now = now.add(const Duration(minutes: 6));
      await binding.synchronize();
      await binding.synchronize();
      await binding.synchronize();

      expect(capabilityRequests, 2);
      expect(futureTimeouts, ['0', '0', '30']);
    },
  );

  test(
    'live binding re-prepares before polling after stored generation changes',
    () async {
      var capabilityRequests = 0;
      final futureTimeouts = <String?>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests++;
            return http.Response(jsonEncode(_chatCapabilities()), 200);
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }
          futureTimeouts.add(request.url.queryParameters['timeout']);
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      await binding.synchronize();
      await chat.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: const <String>{
          'conversation-v4',
          'chat-v2',
          'chat-reference-id',
          'chat-keep-notifications',
        },
        observedAt: DateTime.utc(2026, 1, 2),
      );
      await binding.synchronize();
      await binding.synchronize();
      await binding.synchronize();

      // Re-preparing costs no capability request while the snapshot is valid;
      // the reset poll timeout sequence is what proves the re-prepare happened.
      expect(capabilityRequests, 1);
      expect(futureTimeouts, ['0', '0', '30']);
    },
  );

  test(
    'ordinary reply view cursor never advances a new named network scope',
    () async {
      await _cacheThreadRoot(database, storedThreadId: null);
      var capabilityRequests = 0;
      var rootRequests = 0;
      var dedicatedRequests = 0;
      final dedicatedCursors = <String?>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests++;
            return http.Response(
              jsonEncode(
                _chatCapabilities(
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
            );
          }
          if (request.method == 'POST') {
            expect(request.bodyFields['replyTo'], '109');
            expect(request.bodyFields, isNot(contains('threadId')));
            return http.Response(
              jsonEncode(
                _sendReplyResponse(
                  referenceId: request.bodyFields['referenceId']!,
                  message: request.bodyFields['message']!,
                  replyTo: 109,
                ),
              ),
              201,
              headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
            );
          }
          if (request.url.queryParameters.containsKey('threadId')) {
            dedicatedRequests++;
            expect(request.url.queryParameters['threadId'], '109');
            dedicatedCursors.add(
              request.url.queryParameters['lastKnownMessageId'],
            );
            if (dedicatedRequests == 2) {
              return http.Response(
                jsonEncode(
                  _externalMessageResponse(
                    messageId: 130,
                    timestamp: 1770000130,
                    message: 'Named transition reply',
                    threadId: 109,
                  ),
                ),
                200,
                headers: const <String, String>{
                  'X-Chat-Last-Given': '130',
                  'X-Chat-Last-Common-Read': '110',
                },
              );
            }
          } else {
            rootRequests++;
          }
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );

      await binding.synchronize();
      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'Synthetic ordinary reply before named transition',
        threadId: 109,
      );
      final ordinaryView = await chat.getScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      expect(ordinaryView?.futureCursor, '121');
      final cachedRoot =
          await (database.select(database.cachedChatMessages)..where(
                (message) =>
                    message.accountId.equals('account-a') &
                    message.roomToken.equals('rooma123') &
                    message.messageId.equals(109),
              ))
              .getSingle();
      final rawRoot = jsonDecode(cachedRoot.rawJson) as Map<String, Object?>;
      rawRoot['isThread'] = true;
      await (database.update(database.cachedChatMessages)..where(
            (message) =>
                message.accountId.equals('account-a') &
                message.roomToken.equals('rooma123') &
                message.messageId.equals(109),
          ))
          .write(
            CachedChatMessagesCompanion(
              threadId: const Value(109),
              rawJson: Value(jsonEncode(rawRoot)),
            ),
          );

      await binding.synchronize();
      await binding.synchronize();

      // Re-preparing costs no capability request while the snapshot is valid;
      // the root/dedicated request split is what proves the re-prepare happened.
      expect(capabilityRequests, 1);
      expect(rootRequests, 2);
      expect(dedicatedRequests, greaterThanOrEqualTo(1));
      expect(dedicatedCursors.first, '109');
      final firstNamedRequestCount = dedicatedCursors.length;
      final firstNamedNetwork = await chat.getNetworkScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      expect(firstNamedNetwork?.futureCursor, '130');

      rawRoot['isThread'] = false;
      rawRoot['threadId'] = null;
      await (database.update(database.cachedChatMessages)..where(
            (message) =>
                message.accountId.equals('account-a') &
                message.roomToken.equals('rooma123') &
                message.messageId.equals(109),
          ))
          .write(
            CachedChatMessagesCompanion(
              threadId: const Value(null),
              rawJson: Value(jsonEncode(rawRoot)),
            ),
          );
      await binding.synchronize();
      await binding.synchronize();
      expect(
        await chat.getNetworkScope(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        ),
        isNull,
      );

      rawRoot['isThread'] = true;
      rawRoot['threadId'] = 109;
      await (database.update(database.cachedChatMessages)..where(
            (message) =>
                message.accountId.equals('account-a') &
                message.roomToken.equals('rooma123') &
                message.messageId.equals(109),
          ))
          .write(
            CachedChatMessagesCompanion(
              threadId: const Value(109),
              rawJson: Value(jsonEncode(rawRoot)),
            ),
          );
      await binding.synchronize();
      await binding.synchronize();
      expect(dedicatedCursors[firstNamedRequestCount], '109');
    },
  );

  test('live thread 401 persists the error in its own scope', () async {
    var futureRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'threads',
                ],
              ),
            ),
            200,
          );
        }
        expect(request.url.queryParameters['threadId'], '109');
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return http.Response('', 304);
        }
        futureRequests++;
        if (futureRequests == 1) {
          return http.Response('', 304);
        }
        return http.Response(
          jsonEncode(
            readFixtureJson(
              'chat-messages/fixtures/chat-unauthorized.response.json',
            ),
          ),
          401,
        );
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final binding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    await binding.synchronize();

    await expectLater(
      binding.synchronize(),
      throwsA(
        isA<ChatServiceException>().having(
          (error) => error.code,
          'code',
          ChatServiceError.reauthenticationRequired,
        ),
      ),
    );

    final scope = await chat.getScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    expect(futureRequests, 2);
    expect(
      scope?.lastSyncError,
      ChatServiceError.reauthenticationRequired.name,
    );
  });

  test(
    'live cancellation aborts transport without persisting an error',
    () async {
      var futureRequests = 0;
      final livePollStarted = Completer<void>();
      final api = HttpNextcloudApi(
        client: MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _streamedResponse(jsonEncode(_chatCapabilities()), 200);
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return _streamedResponse('', 304);
          }
          futureRequests++;
          if (futureRequests == 1) {
            return _streamedResponse('', 304);
          }
          expect(request.url.queryParameters['timeout'], '30');
          expect(request, isA<http.Abortable>());
          final abortTrigger = (request as http.Abortable).abortTrigger;
          expect(abortTrigger, isNotNull);
          livePollStarted.complete();
          await abortTrigger;
          throw http.RequestAbortedException(request.url);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      await binding.synchronize();

      final cancellation = Completer<void>();
      final poll = binding.synchronize(abortTrigger: cancellation.future);
      await livePollStarted.future;
      cancellation.complete();
      await poll;

      final scope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(futureRequests, 2);
      expect(scope?.futureCursor, '109');
      expect(scope?.lastSyncError, isNull);
    },
  );

  test('closing a binding aborts its initial capabilities request', () async {
    final requestStarted = Completer<void>();
    final abortObserved = Completer<void>();
    final api = HttpNextcloudApi(
      client: MockClient.streaming((request, _) async {
        expect(request.url.path, endsWith('/cloud/capabilities'));
        requestStarted.complete();
        expect(request, isA<http.Abortable>());
        await (request as http.Abortable).abortTrigger!;
        abortObserved.complete();
        throw http.RequestAbortedException(request.url);
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final binding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );

    final synchronization = binding.synchronize();
    await requestStarted.future;
    binding.close();
    await abortObserved.future.timeout(const Duration(seconds: 2));
    await synchronization;

    final scope = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(scope?.lastSyncError, isNull);
  });

  test(
    'initial response is discarded after capability generation changes',
    () async {
      var historyRequests = 0;
      final historyStarted = Completer<void>();
      final releaseHistory = Completer<void>();
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_chatCapabilities()), 200);
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            historyRequests++;
            if (historyRequests == 1) {
              historyStarted.complete();
              await releaseHistory.future;
              return http.Response(
                jsonEncode(
                  readFixtureJson(
                    'chat-messages/fixtures/chat-history.response.json',
                  ),
                ),
                200,
                headers: const <String, String>{
                  'X-Chat-Last-Given': '103',
                  'X-Chat-Last-Common-Read': '100',
                },
              );
            }
            return http.Response('', 304);
          }
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      final firstSynchronization = binding.synchronize();
      await historyStarted.future;
      await chat.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: const <String>{
          'conversation-v4',
          'chat-v2',
          'chat-reference-id',
          'chat-keep-notifications',
        },
        observedAt: DateTime.utc(2026, 1, 2),
      );
      releaseHistory.complete();
      await firstSynchronization;

      var messages = await chat
          .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      var scope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(messages, isEmpty);
      expect(scope?.lastSyncError, isNull);

      await binding.synchronize();
      messages = await chat
          .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      scope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(historyRequests, 2);
      expect(messages, isEmpty);
      expect(scope?.lastSyncError, isNull);
    },
  );

  test(
    'live not-modified response keeps the authoritative future cursor',
    () async {
      var futureRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_chatCapabilities()), 200);
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }
          futureRequests++;
          expect(
            request.url.queryParameters['timeout'],
            futureRequests == 1 ? '0' : '30',
          );
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      await binding.synchronize();
      await binding.synchronize();

      final scope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(futureRequests, 2);
      expect(scope?.futureCursor, '109');
      expect(scope?.lastSyncError, isNull);
    },
  );

  test(
    'live unauthorized response enters reauthentication lane once',
    () async {
      var futureRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(jsonEncode(_chatCapabilities()), 200);
          }
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }
          futureRequests++;
          if (futureRequests == 1) {
            return http.Response('', 304);
          }
          return http.Response(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-unauthorized.response.json',
              ),
            ),
            401,
          );
        }),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      final binding = service.bindLiveRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      await binding.synchronize();

      await expectLater(
        binding.synchronize(),
        throwsA(
          isA<ChatServiceException>().having(
            (error) => error.code,
            'code',
            ChatServiceError.reauthenticationRequired,
          ),
        ),
      );

      final scope = await chat.getRootScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      final capability = await database
          .select(database.chatCapabilities)
          .getSingle();
      expect(futureRequests, 2);
      expect(capability.lane, ChatAccountLane.reauthenticationRequired.name);
      expect(
        scope?.lastSyncError,
        ChatServiceError.reauthenticationRequired.name,
      );
    },
  );

  test('active live poll does not block send or history loading', () async {
    var futureRequests = 0;
    var historyRequests = 0;
    var sendRequests = 0;
    final livePollStarted = Completer<void>();
    final livePollResponse = Completer<http.Response>();
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_chatCapabilities()), 200);
        }
        if (request.method == 'POST') {
          sendRequests++;
          return http.Response(
            jsonEncode(
              _sendResponse(
                referenceId: request.bodyFields['referenceId']!,
                message: request.bodyFields['message']!,
              ),
            ),
            201,
            headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
          );
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          historyRequests++;
          if (historyRequests == 1) {
            return http.Response(
              jsonEncode(
                readFixtureJson(
                  'chat-messages/fixtures/chat-history.response.json',
                ),
              ),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '103',
                'X-Chat-Last-Common-Read': '100',
              },
            );
          }
          return http.Response('', 304);
        }
        futureRequests++;
        if (futureRequests == 1) {
          return http.Response('', 304);
        }
        livePollStarted.complete();
        return livePollResponse.future;
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final binding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await binding.synchronize();

    final livePoll = binding.synchronize();
    await livePollStarted.future;
    await service
        .sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'Concurrent local send',
        )
        .timeout(const Duration(seconds: 2));
    await service
        .loadOlder(accountId: 'account-a', roomToken: 'rooma123')
        .timeout(const Duration(seconds: 2));

    expect(sendRequests, 1);
    expect(historyRequests, 2);
    expect(futureRequests, 2);
    livePollResponse.complete(http.Response('', 304));
    await livePoll;
  });

  test('closed binding rejects a stale response before merge', () async {
    var futureRequests = 0;
    final livePollStarted = Completer<void>();
    final livePollResponse = Completer<http.Response>();
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_chatCapabilities()), 200);
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return http.Response('', 304);
        }
        futureRequests++;
        if (futureRequests == 1) {
          return http.Response('', 304);
        }
        livePollStarted.complete();
        return livePollResponse.future;
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    final binding = service.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    await binding.synchronize();

    final first = binding.synchronize();
    final singleFlight = binding.synchronize();
    await livePollStarted.future;
    expect(futureRequests, 2);
    binding.close();
    livePollResponse.complete(
      http.Response(
        jsonEncode(
          _externalMessageResponse(
            messageId: 130,
            timestamp: 1770000130,
            message: 'Stale response',
          ),
        ),
        200,
        headers: const <String, String>{
          'X-Chat-Last-Given': '130',
          'X-Chat-Last-Common-Read': '110',
        },
      ),
    );
    await Future.wait(<Future<void>>[first, singleFlight]);

    final messages = await chat
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final scope = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(messages, isEmpty);
    expect(scope?.futureCursor, '109');
    expect(scope?.lastSyncError, isNull);
  });

  test('a reply carries its parent to the server and the outbox', () async {
    String? sentReplyTo;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'chat-replies',
                ],
              ),
            ),
            200,
          );
        }
        expect(request.method, 'POST');
        sentReplyTo = request.bodyFields['replyTo'];
        return http.Response(
          jsonEncode(
            _sendResponse(
              referenceId: request.bodyFields['referenceId']!,
              message: request.bodyFields['message']!,
            ),
          ),
          201,
          headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
        );
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.sendText(
      accountId: 'account-a',
      roomToken: 'rooma123',
      message: 'Synthetic reply',
      replyTo: 109,
    );

    final operations = await chat
        .watchTextSendOperations(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;
    expect(sentReplyTo, '109');
    expect(operations, hasLength(1));
    expect(operations.single.replyTo, 109);
    expect(operations.single.parentRoomToken, 'rooma123');
    // The fixture answer carries no parent, so the reply stays unconfirmed
    // instead of being completed on a weaker match.
    expect(operations.single.outboxState, 'awaitingConfirmation');
  });

  test('a reply inside a thread scope is refused', () async {
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_chatCapabilities()), 200);
        }
        fail('a refused reply must never reach the server');
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await expectLater(
      service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'Synthetic reply',
        threadId: 20,
        replyTo: 109,
      ),
      throwsA(isA<ChatServiceException>()),
    );
  });

  test('confirmed root send remains visible until network catch-up', () async {
    var sendRequests = 0;
    var historyRequests = 0;
    var futureRequests = 0;
    final futureCursors = <String?>[];
    String? sentReferenceId;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_chatCapabilities()), 200);
        }
        if (request.method == 'GET') {
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            historyRequests++;
            return http.Response('', 304);
          }
          futureRequests++;
          futureCursors.add(request.url.queryParameters['lastKnownMessageId']);
          if (futureRequests == 1) {
            return http.Response('', 304);
          }
          if (futureRequests == 2) {
            return http.Response(
              jsonEncode(
                _externalMessageResponse(
                  messageId: 120,
                  timestamp: 1770000120,
                  message: 'Synthetic text send',
                  referenceId: sentReferenceId,
                ),
              ),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '120',
                'X-Chat-Last-Common-Read': '110',
              },
            );
          }
          return http.Response('', 304);
        }
        expect(request.method, 'POST');
        sendRequests++;
        sentReferenceId = request.bodyFields['referenceId'];
        final response = _sendResponse(
          referenceId: request.bodyFields['referenceId']!,
          message: request.bodyFields['message']!,
        );
        return http.Response(
          jsonEncode(response),
          201,
          headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
        );
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.sendText(
      accountId: 'account-a',
      roomToken: 'rooma123',
      message: '  Synthetic text send  ',
    );

    final pendingCatchUpView = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final pendingCatchUpNetwork = await chat.getNetworkScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: null,
    );
    expect(jsonDecode(pendingCatchUpView!.blocksJson), [
      ['109', '109'],
      ['120', '120'],
    ]);
    expect(pendingCatchUpNetwork?.futureCursor, '109');

    await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
    final afterNotModified = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    expect(jsonDecode(afterNotModified!.blocksJson), [
      ['109', '109'],
      ['120', '120'],
    ]);

    await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

    final operations = await chat
        .watchTextSendOperations(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final messages = await chat
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final scope = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final networkScope =
        await (database.select(database.chatScopes)..where(
              (row) =>
                  row.accountId.equals('account-a') &
                  row.roomToken.equals('rooma123') &
                  row.scopeKey.equals('network-root'),
            ))
            .getSingle();
    expect(sendRequests, 1);
    expect(operations, hasLength(1));
    expect(operations.single.message, 'Synthetic text send');
    expect(operations.single.outboxState, 'completed');
    expect(jsonDecode(operations.single.messageIdsJson), [120]);
    expect(messages, hasLength(1));
    expect(messages.single.messageId, 120);
    expect(messages.single.referenceId, operations.single.referenceId);
    expect(messages.single.displayText, 'Synthetic text send');
    expect(historyRequests, 1);
    expect(futureRequests, 3);
    expect(futureCursors, ['109', '109', '120']);
    expect(scope?.futureCursor, '120');
    expect(jsonDecode(scope!.blocksJson), [
      ['109', '120'],
    ]);
    expect(networkScope.futureCursor, '120');
    expect(jsonDecode(networkScope.blocksJson), [
      ['109', '120'],
    ]);
  });

  test('named-thread send persists and restores its threadId', () async {
    await _cacheThreadRoot(database, isThread: true, threadReplies: 0);
    var getRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'threads',
                ],
              ),
            ),
            200,
          );
        }
        if (request.method == 'GET') {
          getRequests++;
          expect(request.url.queryParameters['threadId'], '109');
          expect(request.url.queryParameters['lastKnownMessageId'], '109');
          return http.Response('', 304);
        }
        expect(request.method, 'POST');
        expect(request.bodyFields['threadId'], '109');
        expect(request.bodyFields, isNot(contains('replyTo')));
        return http.Response(
          jsonEncode(
            _sendResponse(
              referenceId: request.bodyFields['referenceId']!,
              message: request.bodyFields['message']!,
              threadId: 109,
              threadReplies: 1,
            ),
          ),
          201,
          headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
        );
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.sendText(
      accountId: 'account-a',
      roomToken: 'rooma123',
      message: 'Synthetic named-thread send',
      threadId: 109,
    );
    await service.syncRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );

    final threadOperations = await chat
        .watchTextSendOperations(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;
    final rootOperations = await chat
        .watchTextSendOperations(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final restored = await ChatRepository(
      database,
    ).loadRuntimeForTesting('account-a');
    final restoredOperation =
        restored.accounts.values.single.operations.values.single;
    final cachedRoot =
        await (database.select(database.cachedChatMessages)..where(
              (message) =>
                  message.accountId.equals('account-a') &
                  message.roomToken.equals('rooma123') &
                  message.messageId.equals(109),
            ))
            .getSingle();
    final cachedRootJson = jsonDecode(cachedRoot.rawJson);
    final viewScope = await chat.getScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    final networkScope =
        await (database.select(database.chatScopes)..where(
              (row) =>
                  row.accountId.equals('account-a') &
                  row.roomToken.equals('rooma123') &
                  row.scopeKey.equals('network-thread:109'),
            ))
            .getSingle();

    expect(threadOperations, hasLength(1));
    expect(getRequests, 2);
    expect(threadOperations.single.threadId, 109);
    expect(threadOperations.single.replyTo, isNull);
    expect(rootOperations, isEmpty);
    expect(restoredOperation.threadId, 109);
    expect(restoredOperation.replyTo, isNull);
    expect(cachedRootJson['threadReplies'], 1);
    expect(jsonDecode(viewScope!.blocksJson), [
      ['109', '109'],
      ['123', '123'],
    ]);
    expect(viewScope.futureCursor, '123');
    expect(jsonDecode(networkScope.blocksJson), [
      ['109', '109'],
    ]);
    expect(networkScope.futureCursor, '109');
  });

  test(
    'root scope does not migrate an ordinary reply cursor into a named thread',
    () async {
      await _cacheThreadRoot(database, isThread: false);
      await database
          .into(database.chatScopes)
          .insert(
            ChatScopesCompanion.insert(
              accountId: 'account-a',
              roomToken: 'rooma123',
              scopeKey: 'thread:109',
              threadId: const Value(109),
              historyCursor: '140',
              futureCursor: '150',
              lastCommonRead: '7',
              lastReadMessage: 8,
              unreadMessages: 2,
              hasHistory: false,
              futureConverged: true,
              blocksJson: '[["140","150"]]',
              lastSyncedAtMillis: const Value(123456),
            ),
          );
      final account = (await accounts.getAccount('account-a'))!;
      final conversation = (await chat.getConversation(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ))!;

      await chat.ensureRootScope(account: account, conversation: conversation);

      final ordinaryView = await chat.getScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      final rootView = await chat.getScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: null,
      );
      final namedNetwork = await chat.getNetworkScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );
      final rootNetwork = await chat.getNetworkScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: null,
      );

      expect(ordinaryView?.historyCursor, '140');
      expect(ordinaryView?.futureCursor, '150');
      expect(ordinaryView?.lastCommonRead, '7');
      expect(ordinaryView?.lastReadMessage, 8);
      expect(ordinaryView?.unreadMessages, 2);
      expect(ordinaryView?.hasHistory, isFalse);
      expect(ordinaryView?.futureConverged, isTrue);
      expect(jsonDecode(ordinaryView!.blocksJson), [
        ['140', '150'],
      ]);
      expect(ordinaryView.lastSyncedAtMillis, 123456);
      expect(ordinaryView.lastSyncError, isNull);
      expect(namedNetwork, isNull);
      expect(rootNetwork?.historyCursor, rootView?.historyCursor);
      expect(rootNetwork?.futureCursor, rootView?.futureCursor);
      expect(rootNetwork?.lastCommonRead, rootView?.lastCommonRead);
      expect(rootNetwork?.lastReadMessage, rootView?.lastReadMessage);
      expect(rootNetwork?.unreadMessages, rootView?.unreadMessages);
      expect(rootNetwork?.hasHistory, rootView?.hasHistory);
      expect(rootNetwork?.futureConverged, rootView?.futureConverged);
      expect(rootNetwork?.blocksJson, rootView?.blocksJson);
      expect(rootNetwork?.lastSyncedAtMillis, rootView?.lastSyncedAtMillis);
      expect(rootNetwork?.lastSyncError, rootView?.lastSyncError);
    },
  );

  test('root worker migrates and completes a queued named send', () async {
    await _cacheThreadRoot(database, isThread: true, threadReplies: 0);
    await database
        .into(database.chatScopes)
        .insert(
          ChatScopesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            scopeKey: 'thread:109',
            threadId: const Value(109),
            historyCursor: '90',
            futureCursor: '110',
            lastCommonRead: '7',
            lastReadMessage: 8,
            unreadMessages: 2,
            hasHistory: false,
            futureConverged: true,
            blocksJson: '[["90","110"]]',
            lastSyncedAtMillis: const Value(123456),
          ),
        );
    await database
        .into(database.textSendOperations)
        .insert(
          TextSendOperationsCompanion.insert(
            accountId: 'account-a',
            operationId: '00000000-0000-4000-8000-000000000099',
            roomToken: 'rooma123',
            referenceId: '99999999-9999-4999-8999-999999999999',
            message: 'Queued named send from the previous runtime',
            replayContractRevision: textSendReplayContractRevision,
            enqueueSequence: 1,
            outboxState: 'queued',
            attemptCount: 0,
            messageIdsJson: '[]',
            threadId: const Value(109),
            duplicateRiskAcknowledged: false,
            createdAtMillis: 1,
            updatedAtMillis: 1,
          ),
        );
    var sendRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'threads',
                ],
              ),
            ),
            200,
          );
        }
        if (request.method == 'GET') {
          expect(request.url.queryParameters, isNot(contains('threadId')));
          return http.Response('', 304);
        }
        sendRequests++;
        expect(request.bodyFields['threadId'], '109');
        return http.Response(
          jsonEncode(
            _sendResponse(
              referenceId: request.bodyFields['referenceId']!,
              message: request.bodyFields['message']!,
              threadId: 109,
              threadReplies: 1,
            ),
          ),
          201,
          headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
        );
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

    final operation = await database
        .select(database.textSendOperations)
        .getSingle();
    final networkScope = await chat.getNetworkScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    final viewScope = await chat.getScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    final confirmed = await chat
        .watchMessages(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;

    expect(sendRequests, 1);
    expect(operation.outboxState, 'completed');
    expect(jsonDecode(operation.messageIdsJson), [123]);
    expect(networkScope?.historyCursor, '90');
    expect(networkScope?.futureCursor, '110');
    expect(networkScope?.lastCommonRead, '7');
    expect(networkScope?.lastReadMessage, 8);
    expect(networkScope?.unreadMessages, 2);
    expect(networkScope?.hasHistory, isFalse);
    expect(networkScope?.futureConverged, isTrue);
    expect(networkScope?.lastSyncedAtMillis, 123456);
    expect(jsonDecode(networkScope!.blocksJson), [
      ['90', '110'],
    ]);
    expect(viewScope?.futureCursor, '123');
    expect(jsonDecode(viewScope!.blocksJson), [
      ['90', '110'],
      ['123', '123'],
    ]);
    expect(confirmed.map((message) => message.messageId), [109, 123]);
  });

  test(
    'confirmed send rolls back outbox and message when view projection fails',
    () async {
      await _cacheThreadRoot(database, isThread: true, threadReplies: 0);
      final account = (await accounts.getAccount('account-a'))!;
      final conversation = (await chat.getConversation(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ))!;
      final capability = await chat.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: const {'chat-v2', 'chat-reference-id', 'threads'},
        observedAt: DateTime.utc(2026, 1, 1),
      );
      await chat.ensureRootScope(account: account, conversation: conversation);
      await chat.ensureThreadScope(
        account: account,
        conversation: conversation,
        threadId: 109,
      );
      await chat.ensureNamedThreadNetworkScope(
        account: account,
        conversation: conversation,
        threadId: 109,
      );
      await (database.update(database.chatScopes)..where(
            (scope) =>
                scope.accountId.equals('account-a') &
                scope.roomToken.equals('rooma123') &
                scope.scopeKey.equals('thread:109'),
          ))
          .write(const ChatScopesCompanion(blocksJson: Value('[]')));
      final profile = ChatCapabilityProfile.fromTalkFeatures(const <Object?>[
        'chat-v2',
        'chat-reference-id',
        'threads',
      ], federated: false);
      final authority = ChatTextSendAuthority(
        accountId: AccountId.parse('account-a'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        capabilityGeneration: capability.generation,
        profile: profile,
        replayContractRevision: textSendReplayContractRevision,
      );
      final operationId = ChatOperationId.parse(
        '00000000-0000-4000-8000-000000000098',
      );
      await chat.admitTextSend(
        accountId: 'account-a',
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        authority: authority,
        operationId: operationId,
        referenceId: ChatReferenceId.parse(
          '99999999-9999-4999-8999-999999999998',
        ),
        message: 'Synthetic rollback probe',
        threadId: 109,
      );
      final claim = await chat.claimNextTextSend(
        accountId: 'account-a',
        roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
        authority: authority,
        requestId: ChatRequestId.parse('projection-rollback'),
        now: 1,
      );
      final response = decodeChatSendResponse(
        request: claim!.request,
        statusCode: 201,
        body: Uint8List.fromList(
          utf8.encode(
            jsonEncode(
              _sendResponse(
                referenceId: claim.request.referenceId.value,
                message: claim.request.message,
                threadId: 109,
                threadReplies: 1,
              ),
            ),
          ),
        ),
      );

      await expectLater(
        chat.applyTextSendResponse(
          accountId: 'account-a',
          operationId: operationId,
          response: response,
          now: 2,
        ),
        throwsStateError,
      );

      final operation = await database
          .select(database.textSendOperations)
          .getSingle();
      final confirmedMessage =
          await (database.select(database.cachedChatMessages)..where(
                (message) =>
                    message.accountId.equals('account-a') &
                    message.roomToken.equals('rooma123') &
                    message.messageId.equals(123),
              ))
              .getSingleOrNull();
      final cachedRoot =
          await (database.select(database.cachedChatMessages)..where(
                (message) =>
                    message.accountId.equals('account-a') &
                    message.roomToken.equals('rooma123') &
                    message.messageId.equals(109),
              ))
              .getSingle();
      final networkScope = await chat.getNetworkScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 109,
      );

      expect(operation.outboxState, 'sending');
      expect(jsonDecode(operation.messageIdsJson), isEmpty);
      expect(confirmedMessage, isNull);
      expect(jsonDecode(cachedRoot.rawJson)['threadReplies'], 0);
      expect(networkScope?.futureCursor, '109');
      expect(jsonDecode(networkScope!.blocksJson), [
        ['109', '109'],
      ]);
    },
  );

  test('ordinary reply stays visible from pending through HTTP 201', () async {
    await _cacheThreadRoot(database, isThread: false);
    final postStarted = Completer<void>();
    final releasePost = Completer<void>();
    var futureRequests = 0;
    final futureCursors = <String?>[];
    String? sentReferenceId;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              _chatCapabilities(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                  'chat-replies',
                ],
              ),
            ),
            200,
          );
        }
        if (request.method == 'GET') {
          if (request.url.queryParameters['lookIntoFuture'] == '0') {
            return http.Response('', 304);
          }
          futureRequests++;
          futureCursors.add(request.url.queryParameters['lastKnownMessageId']);
          if (futureRequests == 1) {
            return http.Response('', 304);
          }
          if (futureRequests == 2) {
            final response = _sendReplyResponse(
              referenceId: sentReferenceId!,
              message: 'Synthetic ordinary reply',
              replyTo: 109,
            );
            final ocs = response['ocs']! as Map<String, Object?>;
            final meta = ocs['meta']! as Map<String, Object?>;
            meta['statuscode'] = 200;
            ocs['data'] = <Object?>[ocs['data']];
            return http.Response(
              jsonEncode(response),
              200,
              headers: const <String, String>{
                'X-Chat-Last-Given': '121',
                'X-Chat-Last-Common-Read': '110',
              },
            );
          }
          return http.Response('', 304);
        }
        expect(request.method, 'POST');
        expect(request.bodyFields['replyTo'], '109');
        expect(request.bodyFields, isNot(contains('threadId')));
        sentReferenceId = request.bodyFields['referenceId'];
        postStarted.complete();
        await releasePost.future;
        return http.Response(
          jsonEncode(
            _sendReplyResponse(
              referenceId: request.bodyFields['referenceId']!,
              message: request.bodyFields['message']!,
              replyTo: 109,
            ),
          ),
          201,
          headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
        );
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    final operations = database.textSendOperations;
    final messages = database.cachedChatMessages;
    final scopes = database.chatScopes;
    final visibilityStates = <bool>[];
    final outboxStates = <String>[];
    final confirmationObserved = Completer<void>();
    final visibilityQuery =
        database.select(operations).join([
          leftOuterJoin(
            messages,
            messages.accountId.equalsExp(operations.accountId) &
                messages.roomToken.equalsExp(operations.roomToken) &
                messages.referenceId.equalsExp(operations.referenceId),
          ),
          leftOuterJoin(
            scopes,
            scopes.accountId.equalsExp(operations.accountId) &
                scopes.roomToken.equalsExp(operations.roomToken) &
                scopes.scopeKey.equals('thread:109'),
          ),
        ])..where(
          operations.accountId.equals('account-a') &
              operations.roomToken.equals('rooma123') &
              operations.replyTo.equals(109) &
              operations.threadId.isNull(),
        );
    final visibilitySubscription = visibilityQuery.watch().listen((rows) {
      if (rows.isEmpty) {
        return;
      }
      final row = rows.single;
      final operation = row.readTable(operations);
      final message = row.readTableOrNull(messages);
      final scope = row.readTableOrNull(scopes);
      final confirmedVisible =
          message != null &&
          scope != null &&
          decodeChatScopeBlocks(scope.blocksJson).any(
            (block) =>
                block.contains(ChatCursor.parse(message.messageId.toString())),
          );
      visibilityStates.add(
        operation.outboxState != 'completed' || confirmedVisible,
      );
      outboxStates.add(operation.outboxState);
      if (operation.outboxState == 'completed' &&
          !confirmationObserved.isCompleted) {
        confirmationObserved.complete();
      }
    });
    addTearDown(visibilitySubscription.cancel);

    final send = service.sendText(
      accountId: 'account-a',
      roomToken: 'rooma123',
      message: 'Synthetic ordinary reply',
      threadId: 109,
    );
    await postStarted.future;
    releasePost.complete();
    await send;
    await confirmationObserved.future;

    await service.syncRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    final afterNotModified = await chat.getScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    expect(jsonDecode(afterNotModified!.blocksJson), [
      ['109', '109'],
      ['121', '121'],
    ]);

    await service.syncRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );

    final threadOperations = await chat
        .watchTextSendOperations(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;
    final rootOperations = await chat
        .watchTextSendOperations(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final replyMessages = await chat
        .watchMessages(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 109,
        )
        .first;
    final viewScope = await chat.getScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 109,
    );
    final rootScope = await chat.getRootScope(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    final restored = await chat.loadRuntimeForTesting('account-a');
    final restoredView =
        restored.accounts.values.single.scopes[ChatScopeKey(
          roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
          threadId: 109,
        )];
    final restoredNetworkRoot =
        restored.accounts.values.single.scopes[ChatScopeKey(
          roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
          threadId: null,
        )];

    expect(threadOperations, hasLength(1));
    expect(threadOperations.single.replyTo, 109);
    expect(threadOperations.single.threadId, isNull);
    expect(threadOperations.single.outboxState, 'completed');
    expect(rootOperations, isEmpty);
    expect(replyMessages.map((message) => message.messageId), [109, 121]);
    expect(jsonDecode(viewScope!.blocksJson), [
      ['109', '121'],
    ]);
    expect(viewScope.historyCursor, '109');
    expect(viewScope.futureCursor, '121');
    expect(rootScope?.futureCursor, '121');
    expect(jsonDecode(rootScope!.blocksJson), [
      ['109', '121'],
    ]);
    expect(restoredView, isNull);
    expect(restoredNetworkRoot?.messageIds, [109]);
    expect(restoredNetworkRoot?.futureCursor.value, '121');
    expect(futureRequests, 3);
    expect(futureCursors, ['109', '109', '121']);
    expect(outboxStates, contains('sending'));
    expect(visibilityStates, isNotEmpty);
    expect(visibilityStates, everyElement(isTrue));
  });

  test('ambiguous transport waits for explicit confirmation', () async {
    var sendRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(jsonEncode(_chatCapabilities()), 200);
        }
        expect(request.method, 'POST');
        sendRequests++;
        throw http.ClientException(
          'Synthetic transport interruption',
          request.url,
        );
      }),
    );
    addTearDown(api.close);
    final service = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );

    await service.sendText(
      accountId: 'account-a',
      roomToken: 'rooma123',
      message: 'Possibly sent',
    );

    final operations = await chat
        .watchTextSendOperations(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    final messages = await chat
        .watchMessages(accountId: 'account-a', roomToken: 'rooma123')
        .first;
    expect(sendRequests, 1);
    expect(operations, hasLength(1));
    expect(operations.single.outboxState, 'awaitingConfirmation');
    expect(operations.single.duplicateRiskAcknowledged, isFalse);
    expect(messages, isEmpty);
  });
}

Future<void> _cacheThreadRoot(
  AppDatabase database, {
  bool? isThread,
  int? storedThreadId = 109,
  int? threadReplies,
}) async {
  final rawJson = <String, Object?>{
    'id': 109,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'user-a',
    'actorDisplayName': 'User A',
    'timestamp': 1770000109,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': '',
    'message': 'Cached thread root',
    'messageParameters': <String, Object?>{},
    'markdown': true,
    'reactions': <String, Object?>{},
    'threadId': 109,
    'isThread': ?isThread,
    'threadReplies': ?threadReplies,
  };
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: 109,
          actorType: 'users',
          actorId: 'user-a',
          actorDisplayName: 'User A',
          timestamp: 1770000109,
          systemMessage: '',
          messageType: 'comment',
          referenceId: '',
          displayText: 'Cached thread root',
          deleted: false,
          threadId: Value(storedThreadId),
          rawJson: jsonEncode(rawJson),
        ),
      );
}

Map<String, Object?> _chatCapabilities({
  List<String> talkFeatures = const <String>[
    'conversation-v4',
    'chat-v2',
    'chat-reference-id',
  ],
}) => capabilitiesJson(talkFeatures: talkFeatures);

const _giphyResourceUrl = 'https://giphy.com/gifs/waving-cat-fixture123';

Map<String, Object?> _conversationRoomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  final lastMessage = Map<String, Object?>.from(
    room['lastMessage']! as Map<String, Object?>,
  );
  lastMessage['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}

Map<String, Object?> _sendResponse({
  required String referenceId,
  required String message,
  int? threadId,
  int? threadReplies,
}) {
  final response =
      readFixtureJson(
            threadId == null
                ? 'chat-messages/fixtures/send-success.response.json'
                : 'chat-messages/fixtures/send-named-thread-success.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  data['referenceId'] = referenceId;
  data['message'] = message;
  if (threadId != null) {
    data['threadId'] = threadId;
  }
  if (threadReplies != null) {
    data['threadReplies'] = threadReplies;
  }
  return response;
}

Map<String, Object?> _sendReplyResponse({
  required String referenceId,
  required String message,
  required int replyTo,
}) {
  final response =
      readFixtureJson(
            'chat-messages/fixtures/send-reply-success.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final parent = data['parent']! as Map<String, Object?>;
  data['referenceId'] = referenceId;
  data['message'] = message;
  data['threadId'] = replyTo;
  parent['id'] = replyTo;
  parent['threadId'] = replyTo;
  return response;
}

Map<String, Object?> _externalMessageResponse({
  required int messageId,
  required int timestamp,
  required String message,
  int? threadId,
  String? referenceId,
}) {
  final response =
      jsonDecode(
            jsonEncode(
              readFixtureJson(
                'chat-messages/fixtures/chat-future.response.json',
              ),
            ),
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final messages = ocs['data']! as List<Object?>;
  final external = Map<String, Object?>.from(
    messages.first! as Map<String, Object?>,
  );
  external['id'] = messageId;
  external['timestamp'] = timestamp;
  external['message'] = message;
  external['messageParameters'] = <String, Object?>{};
  if (referenceId != null) {
    external['referenceId'] = referenceId;
  }
  if (threadId != null) {
    external['threadId'] = threadId;
  }
  ocs['data'] = <Object?>[external];
  return response;
}

http.StreamedResponse _streamedResponse(
  String body,
  int statusCode, {
  Map<String, String> headers = const <String, String>{},
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    statusCode,
    headers: headers,
  );
}
