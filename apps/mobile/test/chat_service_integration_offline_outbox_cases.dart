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

    const proxyPage = '<html>Refused in front of Talk</html>';
    const ocsRefusal =
        '{"ocs":{"meta":{"status":"failure","statuscode":403},'
        '"data":[]}}';
    const retryAfter = <String, String>{'retry-after': '7'};
    const maintenance = <String, String>{
      'retry-after': '7',
      'x-nextcloud-maintenance-mode': '1',
    };
    for (final (statusCode, source, body, headers, state, errorClass) in const [
      (
        403,
        'the server',
        ocsRefusal,
        retryAfter,
        'failed',
        'deterministic-rejection',
      ),
      (
        404,
        'the server',
        ocsRefusal,
        retryAfter,
        'failed',
        'deterministic-rejection',
      ),
      (
        412,
        'the server',
        ocsRefusal,
        retryAfter,
        'failed',
        'deterministic-rejection',
      ),
      (
        403,
        'a proxy',
        proxyPage,
        retryAfter,
        'awaitingConfirmation',
        'ambiguous-transport',
      ),
      (
        404,
        'a proxy',
        proxyPage,
        retryAfter,
        'awaitingConfirmation',
        'ambiguous-transport',
      ),
      (429, 'a proxy', proxyPage, retryAfter, 'retryable', 'rate-limited'),
      (
        503,
        'maintenance mode',
        proxyPage,
        maintenance,
        'retryable',
        'rate-limited',
      ),
      (
        503,
        'a proxy',
        proxyPage,
        retryAfter,
        'awaitingConfirmation',
        'ambiguous-transport',
      ),
    ]) {
      test('a send answered $statusCode by $source ends $state', () async {
        final api = HttpNextcloudApi(
          client: _sendServer(
            (request) => http.Response(body, statusCode, headers: headers),
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

    for (final wake in const ['its own timer', 'a connectivity wake']) {
      test('a send that never left goes out on $wake', () async {
        var reachable = false;
        final sent = <String>[];
        final api = HttpNextcloudApi(
          client: _UnreachableClient(
            _sendServer((request) {
              sent.add(request.bodyFields['message']!);
              return _acceptedSend(request, 121);
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
        addTearDown(service.close);
        await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

        await service.sendText(
          accountId: 'account-a',
          roomToken: 'rooma123',
          message: 'through a short blip',
        );
        await _waitForTextSends(
          database,
          (rows) => rows.single.outboxState == 'retryable',
        );
        reachable = true;
        final waited = Stopwatch()..start();

        if (wake == 'a connectivity wake') {
          await service.drainPendingSends();
          expect(
            waited.elapsed,
            lessThan(const Duration(seconds: 3)),
            reason: 'a wake does not sit out the backoff',
          );
        } else {
          // Nothing else touches the room: only the service's timer can.
          for (var attempt = 0; attempt < 400 && sent.isEmpty; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          expect(waited.elapsed, greaterThan(const Duration(seconds: 3)));
        }
        await _waitForOutboxSettled(chat);

        expect(sent, ['through a short blip']);
        final rows = await database.select(database.textSendOperations).get();
        expect(rows.single.outboxState, 'completed');
        expect(rows.single.attemptCount, 2);
      });
    }

    test('a closed service leaves its retry timer unarmed', () async {
      var posts = 0;
      final api = HttpNextcloudApi(
        client: _UnreachableClient(
          _sendServer((request) => _acceptedSend(request, 121)),
          unreachable: (request) {
            if (request.method != 'POST') return false;
            posts++;
            return true;
          },
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
        message: 'left behind',
      );
      await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'retryable',
      );

      await service.close();
      await Future<void>.delayed(const Duration(seconds: 6));

      expect(posts, 1);
    });

    test('recovery leaves a send that is still on the wire alone', () async {
      final answer = Completer<void>();
      var posts = 0;
      final api = HttpNextcloudApi(
        client: _sendServer((request) async {
          posts++;
          await answer.future;
          return _acceptedSend(request, 121);
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
        message: 'slow but alive',
      );
      final sending = await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'sending' && posts == 1,
      );

      // A sync runs recovery, and this one runs while the POST is unanswered.
      final sync = service.syncRoom(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final during = await database.select(database.textSendOperations).get();
      expect(during.single.outboxState, 'sending');

      // The repository skips exactly the ids it is given, and no others.
      await chat.recoverInterruptedTextSends(
        'account-a',
        inFlight: {ChatOperationId.parse(sending.single.operationId)},
      );
      expect(
        (await database.select(database.textSendOperations).get())
            .single
            .outboxState,
        'sending',
      );

      answer.complete();
      await sync;
      await _waitForOutboxSettled(chat);
      final done = await database.select(database.textSendOperations).get();
      expect(done.single.outboxState, 'completed');
      expect(posts, 1);
    });

    test('recovery converts a send no process owns', () async {
      final api = HttpNextcloudApi(
        client: _sendServer((request) => Completer<http.Response>().future),
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
        message: 'orphaned by a restart',
      );
      await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'sending',
      );

      // A second repository stands in for the process after a restart.
      await ChatRepository(database).recoverInterruptedTextSends('account-a');

      final rows = await database.select(database.textSendOperations).get();
      expect(rows.single.outboxState, 'awaitingConfirmation');
      expect(rows.single.errorClass, 'process-interrupted');
    });

    test('preparing a room rewrites its scope only when it changed', () async {
      final account = (await accounts.getAccount('account-a'))!;
      final conversation = (await chat.getConversation(
        accountId: 'account-a',
        roomToken: 'rooma123',
      ))!;
      await chat.ensureRootScope(account: account, conversation: conversation);
      final stored = (await chat.getScope(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: null,
      ))!;

      var writes = 0;
      final subscription = database
          .tableUpdates(TableUpdateQuery.onTable(database.chatScopes))
          .listen((_) => writes++);
      addTearDown(subscription.cancel);
      await chat.ensureRootScope(account: account, conversation: conversation);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(writes, 0);

      // A chat response has moved the common-read marker past what the
      // conversation row still says. Preparing the room must not undo that.
      final ahead = (int.parse(stored.lastCommonRead) + 40).toString();
      await database
          .update(database.chatScopes)
          .write(ChatScopesCompanion(lastCommonRead: Value(ahead)));
      await chat.ensureRootScope(account: account, conversation: conversation);
      for (final scope in await database.select(database.chatScopes).get()) {
        expect(scope.lastCommonRead, ahead, reason: scope.scopeKey);
      }
    });

    test('a reply answer leaves its cached parent as it was read', () async {
      await _cacheThreadRoot(database, storedThreadId: null);
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
                    'threads',
                  ],
                ),
              ),
              200,
            );
          }
          if (request.method == 'GET') {
            return http.Response('', 304);
          }
          // Built by the server before the parent was edited: the parent it
          // carries still has the old text.
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
      Future<CachedChatMessage> parent() =>
          (database.select(database.cachedChatMessages)..where(
                (row) =>
                    row.accountId.equals('account-a') &
                    row.roomToken.equals('rooma123') &
                    row.messageId.equals(109),
              ))
              .getSingle();
      final read = await parent();
      final editedWire = (jsonDecode(read.rawJson) as Map<String, Object?>)
        ..['message'] = 'Edited after the reply was written';
      await (database.update(
        database.cachedChatMessages,
      )..where((row) => row.messageId.equals(109))).write(
        CachedChatMessagesCompanion(
          displayText: const Value('Edited after the reply was written'),
          rawJson: Value(jsonEncode(editedWire)),
        ),
      );

      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'Reply whose answer comes late',
        threadId: 109,
      );
      await _waitForOutboxSettled(chat);

      final sent = await database.select(database.textSendOperations).get();
      expect(sent.single.outboxState, 'completed');
      final kept = await parent();
      expect(kept.displayText, 'Edited after the reply was written');
      expect(
        (jsonDecode(kept.rawJson) as Map<String, Object?>)['message'],
        'Edited after the reply was written',
      );
    });

    test('a silent send the server stopped supporting fails and frees '
        'the room', () async {
      var features = const <String>[
        'conversation-v4',
        'chat-v2',
        'chat-reference-id',
        'silent-send',
      ];
      var reachable = false;
      final sent = <String>[];
      final api = HttpNextcloudApi(
        capabilityCacheTtl: Duration.zero,
        client: _UnreachableClient(
          MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(
                jsonEncode(_chatCapabilities(talkFeatures: features)),
                200,
              );
            }
            if (request.method == 'GET') {
              return http.Response('', 304);
            }
            sent.add(request.bodyFields['message']!);
            return _acceptedSend(request, 121);
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
      addTearDown(service.close);
      await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');
      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'quietly',
        silent: true,
      );
      await _waitForTextSends(
        database,
        (rows) => rows.single.outboxState == 'retryable',
      );
      await service.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: 'aloud',
      );

      features = features.sublist(0, 3);
      reachable = true;
      await service.drainPendingSends();
      await _waitForOutboxSettled(chat);

      expect(sent, ['aloud']);
      final rows = await database.select(database.textSendOperations).get();
      expect(rows.map((row) => row.outboxState), ['failed', 'completed']);
      expect(rows.first.errorClass, 'silent-send-unsupported');
    });

    for (final replaced in const [true, false]) {
      test(
        'a send refused with 401 '
        '${replaced ? 'for a replaced password is sent again' : 'asks for a new login'}',
        () async {
          final authorizations = <String?>[];
          final api = HttpNextcloudApi(
            client: _sendServer((request) {
              authorizations.add(request.headers['Authorization']);
              if (authorizations.length > 1) {
                return _acceptedSend(request, 121);
              }
              // The user logs in again while this request is on its way.
              if (replaced) {
                credentials.values['account-a'] =
                    'fixture-replacement-password';
              }
              return http.Response('', 401);
            }),
          );
          addTearDown(api.close);
          final service = ChatService(
            accounts: accounts,
            chat: chat,
            credentials: credentials,
            api: api,
          );
          addTearDown(service.close);
          await service.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

          await service.sendText(
            accountId: 'account-a',
            roomToken: 'rooma123',
            message: 'across a new login',
          );
          final rows = await _waitForTextSends(
            database,
            (rows) =>
                rows.single.outboxState ==
                (replaced ? 'completed' : 'retryable'),
          );
          final lane =
              (await database.select(database.chatCapabilities).getSingle())
                  .lane;

          if (replaced) {
            expect(authorizations, hasLength(2));
            expect(authorizations.first, isNot(authorizations.last));
            expect(rows.single.attemptCount, 2);
            expect(lane, ChatAccountLane.ready.name);
          } else {
            expect(authorizations, hasLength(1));
            expect(rows.single.errorClass, 'reauth');
            expect(lane, ChatAccountLane.reauthenticationRequired.name);
          }
        },
      );
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
