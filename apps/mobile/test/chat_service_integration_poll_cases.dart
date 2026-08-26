part of 'chat_service_integration_test.dart';

extension _ChatServicePollCases on _ChatServiceIntegrationSuite {
  void registerPollCases() {
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
                headers: const <String, String>{
                  'X-Chat-Last-Common-Read': '110',
                },
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
        expect(capabilityRequests, 1);
        await service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'Synthetic ordinary reply before named transition',
          threadId: 109,
        );
        expect(
          capabilityRequests,
          2,
          reason: 'send admission requires a fresh capability read',
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

        // Live re-preparing can reuse the snapshot freshly verified by send;
        // the root/dedicated request split is what proves the re-prepare happened.
        expect(capabilityRequests, 2);
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
  }
}
