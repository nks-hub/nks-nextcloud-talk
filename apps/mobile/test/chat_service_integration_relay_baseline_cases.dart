part of 'chat_service_integration_test.dart';

extension _ChatRelayBaselineCases on _ChatServiceIntegrationSuite {
  ChatService _baselineService(http.Client client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
  }

  void registerRelayBaselineCases() {
    for (final olderOperation in ['ordinary sync', 'relay epoch']) {
      test('relay baseline cannot reuse an older $olderOperation', () async {
        final server = _RelayFakeServer([110]);
        final oldReadStarted = Completer<void>();
        final releaseOldRead = Completer<void>();
        var futureReads = 0;
        var holdOldRead = false;
        final service = _baselineService(
          MockClient((request) async {
            if (request.url.queryParameters['lookIntoFuture'] == '1') {
              futureReads++;
            }
            if (holdOldRead &&
                request.url.queryParameters['lookIntoFuture'] == '1') {
              holdOldRead = false;
              oldReadStarted.complete();
              await releaseOldRead.future;
              return http.Response('', 304);
            }
            return server.handle(request);
          }),
        );
        addTearDown(() {
          if (!releaseOldRead.isCompleted) releaseOldRead.complete();
        });
        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
        expect(await _messageIds(), [110]);
        holdOldRead = true;
        final relay = service.bindRelay(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(relay.close);
        Future<ChatSynchronizationResult>? oldSync;
        if (olderOperation == 'ordinary sync') {
          oldSync = service.syncRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
        } else {
          relay.activate(1);
        }
        await oldReadStarted.future.timeout(const Duration(seconds: 2));
        server.messages.add(111);
        relay.activate(olderOperation == 'ordinary sync' ? 1 : 2);
        releaseOldRead.complete();
        if (oldSync != null) {
          expect(await oldSync, ChatSynchronizationResult.converged);
        }
        await _waitForChatCondition(() => relay.isTrusted);
        expect(await _messageIds(), [110, 111]);
        expect(futureReads, greaterThan(1));
      });
    }

    for (final blockedBy in ['page budget', 'lobby', 'read marker']) {
      test('relay stays untrusted when catch-up stops at $blockedBy', () async {
        var futureReads = 0;
        var blocked = true;
        final server = _RelayFakeServer([110]);
        final service = _baselineService(
          MockClient((request) async {
            if (request.url.queryParameters['lookIntoFuture'] == '1') {
              futureReads++;
              if (blocked) {
                if (blockedBy == 'read marker') {
                  return http.Response(
                    jsonEncode({
                      'ocs': {
                        'meta': {
                          'status': 'ok',
                          'statuscode': 200,
                          'message': 'OK',
                        },
                        'data': <Object?>[],
                      },
                    }),
                    200,
                    headers: {'X-Chat-Last-Common-Read': '110'},
                  );
                }
                if (blockedBy == 'lobby') {
                  return http.Response(
                    jsonEncode({
                      'ocs': {
                        'meta': {
                          'status': 'failure',
                          'statuscode': 412,
                          'message': 'lobby',
                        },
                        'data': <Object?>[],
                      },
                    }),
                    412,
                  );
                }
                final id = 110 + futureReads;
                return server._page([id], cursor: id);
              }
            }
            return server.handle(request);
          }),
        );
        final relay = service.bindRelay(
          accountId: 'account-a',
          roomToken: 'rooma123',
        )..activate(1);
        addTearDown(relay.close);
        final result = await service.syncRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        await _settle();
        final trustedWithoutBaseline = relay.isTrusted;
        final blockedReads = futureReads;
        blocked = false;
        relay.activate(2);
        await _waitForChatCondition(() => relay.isTrusted);
        expect(trustedWithoutBaseline, isFalse);
        expect(result, ChatSynchronizationResult.incomplete);
        expect(blockedReads, greaterThan(0));
        expect(futureReads, greaterThan(blockedReads));
      });
    }

    test(
      'joined stale 304 cannot report convergence of the current cursor',
      () async {
        final server = _RelayFakeServer([110]);
        final pollStarted = Completer<void>();
        final releasePoll = Completer<void>();
        final service = _baselineService(
          MockClient((request) async {
            if (request.url.queryParameters['timeout'] == '30') {
              pollStarted.complete();
              await releasePoll.future;
              return http.Response('', 304);
            }
            return server.handle(request);
          }),
        );
        addTearDown(() {
          if (!releasePoll.isCompleted) releasePoll.complete();
        });
        final binding = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(binding.close);
        await binding.synchronize();
        final poll = binding.synchronize();
        await pollStarted.future.timeout(const Duration(seconds: 2));
        final joined = service.catchUpRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        server.messages.add(111);
        final writer = _baselineService(MockClient(server.handle));
        expect(
          await writer.syncRoom(accountId: 'account-a', roomToken: 'rooma123'),
          ChatSynchronizationResult.converged,
        );
        releasePoll.complete();
        final result = await joined.timeout(const Duration(seconds: 2));
        await poll.timeout(const Duration(seconds: 2));
        expect(result, ChatSynchronizationResult.incomplete);
        expect(await _messageIds(), [110, 111]);
        expect(
          (await chat.getRootScope(
            accountId: 'account-a',
            roomToken: 'rooma123',
          ))?.lastSyncError,
          isNull,
        );
      },
    );

    test(
      'relay trust rounds exhausted by traffic require another baseline',
      () async {
        final server = _RelayFakeServer([110]);
        late ChatRelayBinding relay;
        var injectTraffic = true;
        var futureReads = 0;
        final service = _baselineService(
          MockClient((request) async {
            if (request.url.queryParameters['lookIntoFuture'] == '1') {
              futureReads++;
              if (injectTraffic) relay.receive(1, _relayChat([111]));
            }
            return server.handle(request);
          }),
        );
        relay = service.bindRelay(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(relay.close);
        relay.activate(1);
        await _waitForChatCondition(() => futureReads >= 3);
        await _settle();
        final trustedAfterExhaustion = relay.isTrusted;
        final exhaustedReads = futureReads;
        injectTraffic = false;
        relay.activate(1);
        await _waitForChatCondition(() => relay.isTrusted);
        expect(trustedAfterExhaustion, isFalse);
        expect(futureReads, greaterThan(exhaustedReads));
      },
    );
  }
}
