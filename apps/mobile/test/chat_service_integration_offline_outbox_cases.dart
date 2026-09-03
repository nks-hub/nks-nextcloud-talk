part of 'chat_service_integration_test.dart';

extension _ChatServiceOfflineOutboxCases on _ChatServiceIntegrationSuite {
  void registerOfflineOutboxCases() {
    test(
      'offline send queues from a matching ready snapshot and resumes once',
      () async {
        const storedFeatures = <String>{
          'conversation-v4',
          'chat-v2',
          'chat-reference-id',
        };
        await accounts.updateTalkFeatures('account-a', storedFeatures);
        await chat.recordCapabilities(
          accountId: 'account-a',
          talkFeatures: storedFeatures,
          observedAt: DateTime.utc(2026, 1, 1),
        );

        var offlineNonCapabilityRequests = 0;
        final offlineApi = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              throw http.ClientException(
                'Synthetic offline capability failure',
                request.url,
              );
            }
            offlineNonCapabilityRequests++;
            throw StateError('Offline send must not reach chat transport');
          }),
        );
        addTearDown(offlineApi.close);

        await ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: offlineApi,
        ).sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'Queued while offline',
        );

        final queued = await database
            .select(database.textSendOperations)
            .getSingle();
        expect(offlineNonCapabilityRequests, 0);
        expect(queued.outboxState, 'queued');
        expect(queued.attemptCount, 0);

        var sendRequests = 0;
        final onlineApi = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(
                jsonEncode(
                  _chatCapabilities(talkFeatures: storedFeatures.toList()),
                ),
                200,
              );
            }
            if (request.method == 'GET') {
              return http.Response('', 304);
            }
            expect(request.method, 'POST');
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
          }),
        );
        addTearDown(onlineApi.close);

        await ChatService(
          accounts: AccountRepository(database),
          chat: ChatRepository(database),
          credentials: credentials,
          api: onlineApi,
        ).syncRoom(accountId: 'account-a', roomToken: 'rooma123');

        final completed = await database
            .select(database.textSendOperations)
            .getSingle();
        expect(sendRequests, 1);
        expect(completed.operationId, queued.operationId);
        expect(completed.outboxState, 'completed');
      },
    );

    test('a drain delivers queued sends without the room being open', () async {
      const storedFeatures = <String>{
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
      };
      await accounts.updateTalkFeatures('account-a', storedFeatures);
      await chat.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: storedFeatures,
        observedAt: DateTime.utc(2026, 1, 1),
      );
      final offlineApi = HttpNextcloudApi(
        client: MockClient((request) async {
          throw http.ClientException('offline', request.url);
        }),
      );
      addTearDown(offlineApi.close);
      final offline = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: offlineApi,
      );
      await offline.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'first in the tunnel',
      );
      await offline.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'second in the tunnel',
      );
      expect(await chat.roomsWithPendingTextSends(), hasLength(1));

      final sent = <String>[];
      final onlineApi = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                _chatCapabilities(talkFeatures: storedFeatures.toList()),
              ),
              200,
            );
          }
          if (request.method == 'GET') {
            return http.Response('', 304);
          }
          sent.add(request.bodyFields['message']!);
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
      addTearDown(onlineApi.close);

      await ChatService(
        accounts: AccountRepository(database),
        chat: ChatRepository(database),
        credentials: credentials,
        api: onlineApi,
      ).drainPendingSends();

      expect(sent, ['first in the tunnel', 'second in the tunnel']);
      final states = await database.select(database.textSendOperations).get();
      expect(states.map((row) => row.outboxState), ['completed', 'completed']);
      expect(await chat.roomsWithPendingTextSends(), isEmpty);
    });

    test(
      'hot capability cache cannot authorize offline chat transport',
      () async {
        const storedFeatures = <String>{
          'conversation-v4',
          'chat-v2',
          'chat-reference-id',
        };
        await accounts.updateTalkFeatures('account-a', storedFeatures);
        await chat.recordCapabilities(
          accountId: 'account-a',
          talkFeatures: storedFeatures,
          observedAt: DateTime.utc(2026, 1, 1),
        );

        var networkAvailable = true;
        var capabilityRequests = 0;
        var sendRequests = 0;
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              capabilityRequests++;
              if (!networkAvailable) {
                throw http.ClientException(
                  'Synthetic offline capability failure',
                  request.url,
                );
              }
              return http.Response(
                jsonEncode(
                  _chatCapabilities(talkFeatures: storedFeatures.toList()),
                ),
                200,
              );
            }
            if (request.method == 'GET') {
              if (!networkAvailable) {
                throw StateError('Offline send must not fetch chat');
              }
              return http.Response('', 304);
            }
            expect(request.method, 'POST');
            sendRequests++;
            if (!networkAvailable) {
              throw StateError('Offline send must not reach chat transport');
            }
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

        await api.getAuthenticatedCapabilities(
          server: ServerBase.parse('https://cloud.example.invalid'),
          loginName: 'fixture-user',
          appPassword: 'fixture-app-password-never-use',
        );
        expect(capabilityRequests, 1);

        networkAvailable = false;
        await service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'Queued despite a hot capability cache',
        );

        final queued = await database
            .select(database.textSendOperations)
            .getSingle();
        expect(capabilityRequests, 2);
        expect(sendRequests, 0);
        expect(queued.outboxState, 'queued');
        expect(queued.attemptCount, 0);

        networkAvailable = true;
        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

        final completed = await database
            .select(database.textSendOperations)
            .getSingle();
        expect(capabilityRequests, 3);
        expect(sendRequests, 1);
        expect(completed.operationId, queued.operationId);
        expect(completed.outboxState, 'completed');
      },
    );

    test(
      'offline send rejects a missing persisted capability snapshot',
      () async {
        var nonCapabilityRequests = 0;
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              throw http.ClientException(
                'Synthetic offline capability failure',
                request.url,
              );
            }
            nonCapabilityRequests++;
            throw StateError('Rejected send must not reach chat transport');
          }),
        );
        addTearDown(api.close);

        await expectLater(
          ChatService(
            accounts: accounts,
            chat: chat,
            credentials: credentials,
            api: api,
          ).sendText(
            accountId: 'account-a',
            roomToken: 'rooma123',
            message: 'Must not queue',
          ),
          throwsA(
            isA<ChatServiceException>().having(
              (error) => error.code,
              'code',
              ChatServiceError.network,
            ),
          ),
        );

        expect(nonCapabilityRequests, 0);
        expect(
          await database.select(database.textSendOperations).get(),
          isEmpty,
        );
      },
    );

    test('offline send rejects a mismatched capability fingerprint', () async {
      await accounts.updateTalkFeatures('account-a', const <String>{
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
      });
      await chat.recordCapabilities(
        accountId: 'account-a',
        talkFeatures: const <String>{'chat-v2'},
        observedAt: DateTime.utc(2026, 1, 1),
      );
      var nonCapabilityRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            throw http.ClientException(
              'Synthetic offline capability failure',
              request.url,
            );
          }
          nonCapabilityRequests++;
          throw StateError('Rejected send must not reach chat transport');
        }),
      );
      addTearDown(api.close);

      await expectLater(
        ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        ).sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'Must not queue',
        ),
        throwsA(
          isA<ChatServiceException>().having(
            (error) => error.code,
            'code',
            ChatServiceError.network,
          ),
        ),
      );

      expect(nonCapabilityRequests, 0);
      expect(await database.select(database.textSendOperations).get(), isEmpty);
    });
  }
}
