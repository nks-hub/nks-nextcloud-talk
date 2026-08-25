part of 'chat_service_integration_test.dart';

extension _ChatServiceSyncCases on _ChatServiceIntegrationSuite {
  void registerSyncCases() {
    test('sync stores history and future catch-up messages in Drift', () async {
      var historyRequests = 0;
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
      expect(messages.map((message) => message.messageId), [
        105,
        108,
        110,
        112,
      ]);
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
        await chat.ensureRootScope(
          account: account,
          conversation: conversation,
        );
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
    test(
      'federated cache-miss ordinary reply uses the root endpoint',
      () async {
        final conversation = (await chat.getConversation(
          accountId: 'account-a',
          roomToken: 'rooma123',
        ))!;
        final rawConversation =
            jsonDecode(conversation.rawJson) as Map<String, Object?>;
        rawConversation['remoteServer'] = 'remote.example.invalid';
        await (database.update(database.cachedConversations)..where(
              (row) =>
                  row.accountId.equals('account-a') &
                  row.token.equals('rooma123'),
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
      },
    );
  }
}
