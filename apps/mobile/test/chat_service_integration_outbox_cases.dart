part of 'chat_service_integration_test.dart';

extension _ChatServiceOutboxCases on _ChatServiceIntegrationSuite {
  void registerOutboxCases() {
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
          .watchTextSendOperations(
            accountId: 'account-a',
            roomToken: 'rooma123',
          )
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

        await chat.ensureRootScope(
          account: account,
          conversation: conversation,
        );

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
        await chat.ensureRootScope(
          account: account,
          conversation: conversation,
        );
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

    test(
      'ordinary reply stays visible from pending through HTTP 201',
      () async {
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
              futureCursors.add(
                request.url.queryParameters['lastKnownMessageId'],
              );
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
                (block) => block.contains(
                  ChatCursor.parse(message.messageId.toString()),
                ),
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
            .watchTextSendOperations(
              accountId: 'account-a',
              roomToken: 'rooma123',
            )
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
              roomToken: ConversationToken.parse(
                'rooma123',
                path: r'$.roomToken',
              ),
              threadId: 109,
            )];
        final restoredNetworkRoot =
            restored.accounts.values.single.scopes[ChatScopeKey(
              roomToken: ConversationToken.parse(
                'rooma123',
                path: r'$.roomToken',
              ),
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
      },
    );

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
          .watchTextSendOperations(
            accountId: 'account-a',
            roomToken: 'rooma123',
          )
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
}
