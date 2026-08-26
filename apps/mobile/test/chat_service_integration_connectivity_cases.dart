part of 'chat_service_integration_test.dart';

extension _ChatServiceConnectivityCases on _ChatServiceIntegrationSuite {
  void registerConnectivityCases() {
    test(
      'connectivity wake revalidates before draining one queued text send',
      () async {
        const features = <String>{
          'conversation-v4',
          'chat-v2',
          'chat-reference-id',
        };
        var capabilityRequests = 0;
        var sendRequests = 0;
        final api = HttpNextcloudApi(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              capabilityRequests++;
              return http.Response(
                jsonEncode(_chatCapabilities(talkFeatures: features.toList())),
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
        expect(capabilityRequests, 1);

        await _admitConnectivityFixture(
          chat,
          features: features,
          operationId: '11111111-1111-4111-8111-111111111111',
          referenceId: '22222222-2222-4222-8222-222222222222',
        );
        await _admitConnectivityFixture(
          chat,
          features: features,
          operationId: '77777777-7777-4777-8777-777777777777',
          referenceId: '88888888-8888-4888-8888-888888888888',
          roomToken: 'roomb123',
        );
        final secondAccount = await accounts.upsertAccount(
          accountId: 'account-b',
          serverUrl: 'https://cloud.example.invalid',
          loginName: 'fixture-user-b',
          serverProductName: 'Nextcloud',
          talkFeatures: features,
          createdAt: DateTime.utc(2026, 1, 2),
        );
        await chat.recordCapabilities(
          accountId: secondAccount.id,
          talkFeatures: features,
          observedAt: DateTime.utc(2026, 1, 2),
        );
        await _admitConnectivityFixture(
          chat,
          features: features,
          operationId: '99999999-9999-4999-8999-999999999999',
          referenceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          accountId: secondAccount.id,
        );

        await binding.wakeAfterConnectivity();

        final operations = {
          for (final operation
              in await database.select(database.textSendOperations).get())
            operation.operationId: operation,
        };
        expect(capabilityRequests, 2);
        expect(sendRequests, 1);
        expect(
          operations['11111111-1111-4111-8111-111111111111']?.outboxState,
          'completed',
        );
        expect(
          operations['11111111-1111-4111-8111-111111111111']?.attemptCount,
          1,
        );
        for (final operationId in <String>[
          '77777777-7777-4777-8777-777777777777',
          '99999999-9999-4999-8999-999999999999',
        ]) {
          expect(operations[operationId]?.outboxState, 'queued');
          expect(operations[operationId]?.attemptCount, 0);
        }

        await Future.wait<void>([
          binding.wakeAfterConnectivity(),
          binding.wakeAfterConnectivity(),
        ]);
        expect(sendRequests, 1);
      },
    );

    test('false connectivity wake leaves queued text unclaimed', () async {
      const features = <String>{
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
      };
      var capabilityRequests = 0;
      var sendRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests++;
            if (capabilityRequests > 1) {
              throw http.ClientException(
                'Synthetic connectivity false positive',
                request.url,
              );
            }
            return http.Response(
              jsonEncode(_chatCapabilities(talkFeatures: features.toList())),
              200,
            );
          }
          if (request.method == 'POST') {
            sendRequests++;
            fail('A false connectivity wake must not send chat');
          }
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final binding = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      ).bindLiveRoom(accountId: 'account-a', roomToken: 'rooma123');
      addTearDown(binding.close);

      await binding.synchronize();
      await _admitConnectivityFixture(
        chat,
        features: features,
        operationId: '33333333-3333-4333-8333-333333333333',
        referenceId: '44444444-4444-4444-8444-444444444444',
      );

      await expectLater(
        binding.wakeAfterConnectivity(),
        throwsA(
          isA<ChatServiceException>().having(
            (error) => error.code,
            'code',
            ChatServiceError.network,
          ),
        ),
      );

      final operation = await database
          .select(database.textSendOperations)
          .getSingle();
      expect(capabilityRequests, 2);
      expect(sendRequests, 0);
      expect(operation.outboxState, 'queued');
      expect(operation.attemptCount, 0);
    });

    test('closed connectivity binding never claims queued text', () async {
      const features = <String>{
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
      };
      var capabilityRequests = 0;
      var sendRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests++;
            return http.Response(
              jsonEncode(_chatCapabilities(talkFeatures: features.toList())),
              200,
            );
          }
          if (request.method == 'POST') {
            sendRequests++;
          }
          return http.Response('', 304);
        }),
      );
      addTearDown(api.close);
      final binding = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      ).bindLiveRoom(accountId: 'account-a', roomToken: 'rooma123');

      await binding.synchronize();
      await _admitConnectivityFixture(
        chat,
        features: features,
        operationId: '55555555-5555-4555-8555-555555555555',
        referenceId: '66666666-6666-4666-8666-666666666666',
      );
      binding.close();
      await binding.wakeAfterConnectivity();

      final operation = await database
          .select(database.textSendOperations)
          .getSingle();
      expect(capabilityRequests, 1);
      expect(sendRequests, 0);
      expect(operation.outboxState, 'queued');
      expect(operation.attemptCount, 0);
    });
  }
}

Future<void> _admitConnectivityFixture(
  ChatRepository chat, {
  required Set<String> features,
  required String operationId,
  required String referenceId,
  String accountId = 'account-a',
  String roomToken = 'rooma123',
}) async {
  final capability = await chat.getReadyCapabilitySnapshot(accountId);
  expect(capability, isNotNull);
  await chat.admitTextSend(
    accountId: accountId,
    roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
    authority: ChatTextSendAuthority(
      accountId: AccountId.parse(accountId),
      server: ServerBase.parse('https://cloud.example.invalid'),
      capabilityGeneration: capability!.generation,
      profile: ChatCapabilityProfile.fromTalkFeatures(
        features.toList(),
        federated: false,
      ),
      replayContractRevision: textSendReplayContractRevision,
    ),
    operationId: ChatOperationId.parse(operationId),
    referenceId: ChatReferenceId.parse(referenceId),
    message: 'Queued reconnect fixture',
  );
}
