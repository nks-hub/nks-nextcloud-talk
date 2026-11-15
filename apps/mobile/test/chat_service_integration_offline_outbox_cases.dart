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

      final admitted = await database.select(database.textSendOperations).get();

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
            fail('A headless legacy drain must not fetch chat');
          }
          sent.add(request.bodyFields['message']!);
          final response = _sendResponse(
            referenceId: request.bodyFields['referenceId']!,
            message: request.bodyFields['message']!,
          );
          ((response['ocs'] as Map)['data'] as Map)['id'] = 120 + sent.length;
          ((response['ocs'] as Map)['data'] as Map)['threadId'] =
              120 + sent.length;
          return http.Response(
            jsonEncode(response),
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

      final states = await database.select(database.textSendOperations).get();
      expect(
        sent,
        ['first in the tunnel', 'second in the tunnel'],
        reason: states
            .map(
              (row) =>
                  '${row.outboxState}/${row.attemptCount}/${row.errorClass}',
            )
            .join(', '),
      );
      expect(states.map((row) => row.outboxState), ['completed', 'completed']);
      expect(states.map((row) => row.attemptCount), everyElement(1));
      expect(
        {for (final row in states) row.operationId: row.referenceId},
        {for (final row in admitted) row.operationId: row.referenceId},
      );
      expect(await chat.roomsWithPendingTextSends(), isEmpty);
    });

    test('a send with cached capabilities is one request', () async {
      final requests = <String>[];
      final api = HttpNextcloudApi(
        client: _sendServer(
          (request) => _acceptedSend(request, 120),
          requests: requests,
        ),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      requests.clear();

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'One round trip',
      );
      await _waitForOutboxSettled(chat);

      expect(requests, ['POST']);
      final sent = await database.select(database.textSendOperations).get();
      expect(sent.single.outboxState, 'completed');
    });

    test('a send that never left is retried and frees the room', () async {
      var reachable = false;
      final sent = <String>[];
      final api = HttpNextcloudApi(
        client: _UnreachableClient(
          _sendServer((request) {
            sent.add(request.bodyFields['message']!);
            return _acceptedSend(request, 120 + sent.length);
          }),
          unreachable: (request) => !reachable && request.method == 'POST',
        ),
      );
      addTearDown(api.close);
      final service = ChatService(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
      );
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'first into the tunnel',
      );
      final unsent = await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'retryable',
      );
      expect(unsent.single.errorClass, 'transport-before-send');
      expect(unsent.single.attemptCount, 1);
      expect(unsent.single.nextAttemptAt, isNotNull);

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'second into the tunnel',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final waiting = await database.select(database.textSendOperations).get();
      expect(waiting.map((row) => row.outboxState), ['retryable', 'queued']);
      expect(sent, isEmpty);

      reachable = true;
      await (database.update(database.textSendOperations)
            ..where((row) => row.outboxState.equals('retryable')))
          .write(const TextSendOperationsCompanion(nextAttemptAt: Value(0)));
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      await _waitForOutboxSettled(chat);

      expect(sent, ['first into the tunnel', 'second into the tunnel']);
      final delivered = await database
          .select(database.textSendOperations)
          .get();
      expect(delivered.map((row) => row.outboxState), [
        'completed',
        'completed',
      ]);
      expect(delivered.map((row) => row.attemptCount), [2, 1]);
    });

    for (final lost in const ['timed out', 'was reset']) {
      test('a send that $lost after its body left stays unconfirmed', () async {
        var posts = 0;
        final api = HttpNextcloudApi(
          requestTimeout: const Duration(milliseconds: 100),
          client: _sendServer((request) {
            posts++;
            return lost == 'timed out'
                ? Completer<http.Response>().future
                : throw http.ClientException('Synthetic reset', request.url);
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

        await service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'Possibly stored',
        );
        final rows = await _waitForTextSends(
          database,
          (rows) => rows.single.outboxState == 'awaitingConfirmation',
        );
        expect(rows.single.errorClass, 'ambiguous-transport');
        expect(rows.single.nextAttemptAt, isNull);

        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
        expect(posts, 1, reason: 'an ambiguous send is never repeated unasked');
      });
    }

    for (final (statusCode, state, errorClass) in const [
      (403, 'failed', 'deterministic-rejection'),
      (404, 'failed', 'deterministic-rejection'),
      (412, 'failed', 'deterministic-rejection'),
      (429, 'retryable', 'rate-limited'),
      (503, 'retryable', 'rate-limited'),
    ]) {
      test('a send answered $statusCode without a body ends $state', () async {
        final api = HttpNextcloudApi(
          client: _sendServer(
            (request) => http.Response(
              '<html>Refused in front of Talk</html>',
              statusCode,
              headers: const <String, String>{'retry-after': '7'},
            ),
          ),
        );
        addTearDown(api.close);
        final service = ChatService(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
        );
        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

        final before =
            DateTime.now().millisecondsSinceEpoch ~/
            Duration.millisecondsPerSecond;
        await service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'Refused before the save',
        );
        final rows = await _waitForTextSends(
          database,
          (rows) => rows.single.outboxState == state,
        );
        expect(rows.single.errorClass, errorClass);
        if (state == 'retryable') {
          expect(
            rows.single.nextAttemptAt,
            inInclusiveRange(before + 7, before + 9),
          );
        } else {
          expect(rows.single.nextAttemptAt, isNull);
        }
      });
    }

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

    test('a drain gives each account its own lane', () async {
      const storedFeatures = <String>{
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
      };
      const secondHost = 'second.example.invalid';
      final second = await accounts.upsertAccount(
        accountId: 'account-b',
        serverUrl: 'https://$secondHost',
        loginName: 'fixture-user-b',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      credentials.values[second.id] = 'fixture-app-password-never-use';
      await _cacheConversation(database, accountId: second.id);
      for (final accountId in const ['account-a', 'account-b']) {
        await accounts.updateTalkFeatures(accountId, storedFeatures);
        await chat.recordCapabilities(
          accountId: accountId,
          talkFeatures: storedFeatures,
          observedAt: DateTime.utc(2026, 1, 1),
        );
      }

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
      for (final accountId in const ['account-a', 'account-b']) {
        await offline.sendText(
          accountId: accountId,
          roomToken: 'rooma123',
          message: 'queued for $accountId',
        );
      }

      // Neither server answers until both have been reached. A drain that
      // walks the rooms in one line only ever reaches the account it starts
      // with, so the barrier never opens and the drain times out.
      final reached = <String>{};
      final bothReached = Completer<void>();
      final sent = <String>[];
      final onlineApi = HttpNextcloudApi(
        client: MockClient((request) async {
          reached.add(request.url.host);
          if (reached.length == 2 && !bothReached.isCompleted) {
            bothReached.complete();
          }
          await bothReached.future;
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
      ).drainPendingSends().timeout(const Duration(seconds: 10));

      expect(reached, {'cloud.example.invalid', secondHost});
      expect(
        sent,
        unorderedEquals(['queued for account-a', 'queued for account-b']),
      );
      final states = await database.select(database.textSendOperations).get();
      expect(states.map((row) => row.outboxState), ['completed', 'completed']);
      expect(await chat.roomsWithPendingTextSends(), isEmpty);
    });
  }
}

const _sendFeatures = <String>{
  'conversation-v4',
  'chat-v2',
  'chat-reference-id',
};

/// Answers capabilities and chat reads, and hands every POST to [onSend].
MockClient _sendServer(
  FutureOr<http.Response> Function(http.Request request) onSend, {
  List<String>? requests,
}) {
  return MockClient((request) async {
    final capabilities = request.url.path.endsWith('/cloud/capabilities');
    requests?.add(capabilities ? 'capabilities' : request.method);
    if (capabilities) {
      return http.Response(
        jsonEncode(_chatCapabilities(talkFeatures: _sendFeatures.toList())),
        200,
      );
    }
    if (request.method == 'GET') {
      return http.Response('', 304);
    }
    return onSend(request);
  });
}

http.Response _acceptedSend(http.Request request, int messageId) {
  final response = _sendResponse(
    referenceId: request.bodyFields['referenceId']!,
    message: request.bodyFields['message']!,
  );
  final data = (response['ocs']! as Map)['data']! as Map;
  data['id'] = messageId;
  data['threadId'] = messageId;
  return http.Response(
    jsonEncode(response),
    201,
    headers: const <String, String>{'X-Chat-Last-Common-Read': '110'},
  );
}

Future<List<StoredTextSendOperation>> _waitForTextSends(
  AppDatabase database,
  bool Function(List<StoredTextSendOperation> rows) condition,
) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    final rows = await database.select(database.textSendOperations).get();
    if (rows.isNotEmpty && condition(rows)) return rows;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('The outbox did not reach the expected state');
}

/// Fails a request the way a refused connection does: before the client has
/// asked for the body, which a [MockClient] reads up front.
final class _UnreachableClient extends http.BaseClient {
  _UnreachableClient(this._inner, {required this.unreachable});

  final http.Client _inner;
  final bool Function(http.BaseRequest request) unreachable;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (unreachable(request)) {
      throw http.ClientException('Synthetic connection failure', request.url);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
