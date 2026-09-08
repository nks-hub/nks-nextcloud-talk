part of 'chat_service_integration_test.dart';

extension _BackgroundReaderCases on _ChatServiceIntegrationSuite {
  Future<void> _queueBackgroundPair() async {
    const features = {'conversation-v4', 'chat-v2', 'chat-reference-id'};
    await accounts.updateTalkFeatures('account-a', features);
    await chat.recordCapabilities(
      accountId: 'account-a',
      talkFeatures: features,
      observedAt: DateTime.utc(2026, 1, 1),
    );
    final offline = _readerService(
      MockClient((request) async {
        throw http.ClientException('offline', request.url);
      }),
    );
    for (final message in ['first queued', 'second queued']) {
      await offline.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: message,
      );
    }
  }

  void registerBackgroundReaderCases() {
    for (final passive in [false, true]) {
      test(
        'single-message ${passive ? 'passive' : 'legacy'} repair respects reader admission',
        () async {
          var reads = 0;
          final service = _readerService(
            MockClient((request) async {
              if (request.url.path.endsWith('/cloud/capabilities')) {
                return http.Response(
                  jsonEncode(
                    _chatCapabilities(
                      talkFeatures: [
                        'conversation-v4',
                        'chat-v2',
                        'chat-reference-id',
                        if (passive) 'chat-keep-notifications',
                      ],
                    ),
                  ),
                  200,
                );
              }
              reads++;
              expect(
                request.url.queryParameters['markNotificationsAsRead'],
                passive ? '0' : '1',
              );
              return http.Response(
                jsonEncode(
                  _externalMessageResponse(
                    messageId: 140,
                    threadId: 140,
                    timestamp: 1770000140,
                    message: 'Repaired message',
                  ),
                ),
                200,
                headers: {'X-Chat-Last-Given': '140'},
              );
            }),
          );
          expect(
            await service.refreshMessage(
              accountId: 'account-a',
              roomToken: 'rooma123',
              messageId: 140,
            ),
            passive,
          );
          expect(reads, passive ? 1 : 0);
          final before = await chat.getRootScope(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          final reader = service.bindLiveRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          addTearDown(reader.close);
          expect(
            await service.refreshMessage(
              accountId: 'account-a',
              roomToken: 'rooma123',
              messageId: 140,
            ),
            isTrue,
          );
          expect(
            (await chat.getMessage(
              accountId: 'account-a',
              roomToken: 'rooma123',
              messageId: 140,
            ))?.displayText,
            'Repaired message',
          );
          final after = await chat.getRootScope(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          expect(after?.futureCursor, before?.futureCursor);
          expect(after?.historyCursor, before?.historyCursor);
        },
      );

      test(
        'revoked explicit ${passive ? 'modern' : 'legacy'} navigation stops before chat dispatch',
        () async {
          var ownerActive = true;
          var reads = 0;
          final service = _readerService(
            MockClient((request) async {
              if (request.url.path.endsWith('/cloud/capabilities')) {
                ownerActive = false;
                return http.Response(
                  jsonEncode(
                    _chatCapabilities(
                      talkFeatures: [
                        'conversation-v4',
                        'chat-v2',
                        'chat-reference-id',
                        if (passive) 'chat-keep-notifications',
                      ],
                    ),
                  ),
                  200,
                );
              }
              reads++;
              return http.Response('', 304);
            }),
          );
          expect(
            await service.syncRoom(
              accountId: 'account-a',
              roomToken: 'rooma123',
              readerIsActive: () => ownerActive,
            ),
            ChatSynchronizationResult.deferred,
          );
          expect(reads, 0);
          await service.loadOlder(
            accountId: 'account-a',
            roomToken: 'rooma123',
            readerIsActive: () => ownerActive,
          );
          expect(reads, 0);
          ownerActive = true;
          expect(
            await service.syncRoom(
              accountId: 'account-a',
              roomToken: 'rooma123',
              readerIsActive: () => ownerActive,
            ),
            ChatSynchronizationResult.converged,
          );
          expect(reads, greaterThan(0));
        },
      );
    }

    test(
      'legacy outbox waits for an uncertain send and resumes after a live confirmation',
      () async {
        await _queueBackgroundPair();
        final admitted = await database
            .select(database.textSendOperations)
            .get();
        final sent = <String>[];
        String? firstReference;
        var deliverConfirmation = false;
        var allowRead = false;
        final service = _readerService(
          MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            if (request.method == 'GET') {
              expect(
                allowRead,
                isTrue,
                reason: 'Inactive legacy drain must not read chat',
              );
              if (request.url.queryParameters['timeout'] == '30' &&
                  deliverConfirmation) {
                deliverConfirmation = false;
                return http.Response(
                  jsonEncode(
                    _externalMessageResponse(
                      messageId: 120,
                      timestamp: 1770000120,
                      message: 'first queued',
                      referenceId: firstReference,
                      threadId: 120,
                    ),
                  ),
                  200,
                  headers: {'X-Chat-Last-Given': '120'},
                );
              }
              return http.Response('', 304);
            }
            sent.add(request.bodyFields['message']!);
            if (sent.length == 1) {
              firstReference = request.bodyFields['referenceId'];
              throw http.ClientException(
                'response lost after acceptance',
                request.url,
              );
            }
            final response = _sendResponse(
              referenceId: request.bodyFields['referenceId']!,
              message: request.bodyFields['message']!,
            );
            ((response['ocs'] as Map)['data'] as Map)['id'] = 121;
            ((response['ocs'] as Map)['data'] as Map)['threadId'] = 121;
            return http.Response(jsonEncode(response), 201);
          }),
        );
        await service.drainPendingSends();
        expect(sent, ['first queued']);
        expect(
          (await database.select(database.textSendOperations).get()).map(
            (row) => row.outboxState,
          ),
          ['awaitingConfirmation', 'queued'],
        );
        await service.drainPendingSends();
        expect(sent, ['first queued']);
        allowRead = true;
        final binding = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(binding.close);
        await binding.synchronize();
        expect(sent, ['first queued']);
        deliverConfirmation = true;
        await binding.synchronize();
        final completed = await database
            .select(database.textSendOperations)
            .get();
        expect(
          sent,
          ['first queued', 'second queued'],
          reason: completed
              .map(
                (row) =>
                    '${row.outboxState}/${row.attemptCount}/${row.errorClass}',
              )
              .join(', '),
        );
        expect(
          completed.map((row) => row.outboxState),
          everyElement('completed'),
        );
        expect(completed.map((row) => row.attemptCount), everyElement(1));
        expect(
          {for (final row in completed) row.operationId: row.referenceId},
          {for (final row in admitted) row.operationId: row.referenceId},
        );
        binding.setReaderActive(false);
        allowRead = false;
        await service.drainPendingSends();
        expect(sent, ['first queued', 'second queued']);
      },
    );

    for (final passive in [false, true]) {
      test(
        'background ${passive ? 'passive' : 'legacy'} request handles reader loss during HTTP',
        () async {
          final started = Completer<void>(), release = Completer<void>();
          var aborted = false;
          final service = _readerService(
            MockClient.streaming((request, _) async {
              if (request.url.path.endsWith('/cloud/capabilities')) {
                return _streamedResponse(
                  jsonEncode(
                    _chatCapabilities(
                      talkFeatures: [
                        'conversation-v4',
                        'chat-v2',
                        'chat-reference-id',
                        if (passive) 'chat-keep-notifications',
                      ],
                    ),
                  ),
                  200,
                );
              }
              if (request.url.queryParameters['lookIntoFuture'] == '0') {
                return _streamedResponse('', 304);
              }
              started.complete();
              final cancelled = await Future.any<bool>([
                (request as http.Abortable).abortTrigger!.then((_) => true),
                release.future.then((_) => false),
              ]);
              if (cancelled) {
                aborted = true;
                throw http.RequestAbortedException(request.url);
              }
              return _streamedResponse('', 304);
            }),
          );
          final reader = service.bindLiveRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          addTearDown(reader.close);
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          final pending = service.catchUpRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          await started.future.timeout(const Duration(seconds: 2));
          reader.setReaderActive(false);
          if (passive) release.complete();
          expect(
            await pending.timeout(const Duration(seconds: 2)),
            passive
                ? ChatSynchronizationResult.converged
                : ChatSynchronizationResult.deferred,
          );
          expect(aborted, !passive);
          expect(
            (await chat.getRootScope(
              accountId: 'account-a',
              roomToken: 'rooma123',
            ))?.lastSyncError,
            isNull,
          );
        },
      );
    }

    test(
      'legacy relay retries its deferred baseline when a reader arrives',
      () async {
        final server = _RelayFakeServer([110], passive: false);
        var reads = 0;
        final service = _readerService(
          MockClient((request) async {
            if (!request.url.path.endsWith('/cloud/capabilities')) reads++;
            return server.handle(request);
          }),
        );
        final relay = service.bindRelay(
          accountId: 'account-a',
          roomToken: 'rooma123',
        )..activate(1);
        addTearDown(relay.close);
        expect(
          await service.catchUpRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          ),
          ChatSynchronizationResult.deferred,
        );
        expect(reads, 0);
        expect(relay.isTrusted, isFalse);
        final reader = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
        );
        addTearDown(reader.close);
        await _waitForChatCondition(() => relay.isTrusted);
        expect(await _messageIds(), [110]);
      },
    );

    for (final passive in [false, true]) {
      test(
        'background catch-up ${passive ? 'reads passively' : 'defers legacy reads'} without a reader',
        () async {
          var reads = 0;
          final service = _readerService(
            MockClient((request) async {
              if (request.url.path.endsWith('/cloud/capabilities')) {
                return http.Response(
                  jsonEncode(
                    _chatCapabilities(
                      talkFeatures: [
                        'conversation-v4',
                        'chat-v2',
                        'chat-reference-id',
                        if (passive) 'chat-keep-notifications',
                      ],
                    ),
                  ),
                  200,
                );
              }
              reads++;
              expect(
                request.url.queryParameters['markNotificationsAsRead'],
                passive ? '0' : '1',
              );
              return http.Response('', 304);
            }),
          );
          final result = await service.catchUpRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          expect(
            result,
            passive
                ? ChatSynchronizationResult.converged
                : ChatSynchronizationResult.deferred,
          );
          expect(reads, passive ? greaterThan(0) : 0);
          expect(
            (await chat.getRootScope(
              accountId: 'account-a',
              roomToken: 'rooma123',
            ))?.lastSyncError,
            isNull,
          );
        },
      );
    }

    test(
      'legacy background catch-up requires a reader in its own account and room',
      () async {
        var reads = 0;
        final service = _readerService(
          MockClient((request) async {
            if (request.url.path.endsWith('/cloud/capabilities')) {
              return http.Response(jsonEncode(_chatCapabilities()), 200);
            }
            reads++;
            return http.Response('', 304);
          }),
        );
        final otherRoom = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'roomb999',
        );
        final otherAccount = service.bindLiveRoom(
          accountId: 'account-b',
          roomToken: 'rooma123',
        );
        final reader = service.bindLiveRoom(
          accountId: 'account-a',
          roomToken: 'rooma123',
          readerActive: false,
        );
        addTearDown(otherRoom.close);
        addTearDown(otherAccount.close);
        addTearDown(reader.close);
        expect(
          await service.catchUpRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          ),
          ChatSynchronizationResult.deferred,
        );
        expect(reads, 0);
        reader.setReaderActive(true);
        expect(
          await service.catchUpRoom(
            accountId: 'account-a',
            roomToken: 'rooma123',
          ),
          ChatSynchronizationResult.converged,
        );
        expect(reads, greaterThan(0));
      },
    );
  }
}
