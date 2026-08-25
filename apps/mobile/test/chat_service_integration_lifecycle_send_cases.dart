part of 'chat_service_integration_test.dart';

extension _ChatServiceLifecycleSendCases on _ChatServiceIntegrationSuite {
  void registerLifecycleSendCases() {
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

    test(
      'confirmed root send remains visible until network catch-up',
      () async {
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
              futureCursors.add(
                request.url.queryParameters['lastKnownMessageId'],
              );
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
            .watchTextSendOperations(
              accountId: 'account-a',
              roomToken: 'rooma123',
            )
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
      },
    );
  }
}
