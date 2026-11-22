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
    final offline = _readerService(OfflineClient());
    for (final message in ['first queued', 'second queued']) {
      await offline.sendText(
        accountId: 'account-a',
        roomToken: 'rooma123',
        message: message,
      );
    }
    await waitForUnsentTextSends(database);
    await offline.close();
  }

  void registerBackgroundReaderCases() {
    for (final (overlap, rejectConfirmation, rejectRelease, name) in [
      (false, false, false, 'sequential preserves the live send'),
      (true, false, false, 'overlap preserves the live send'),
      (false, true, false, 'failed confirmation allows conservative recovery'),
      (false, true, true, 'failed release preserves the persistence error'),
    ]) {
      test('background text wake $name without replaying the POST', () async {
        final dir = await Directory.systemTemp.createTemp(
          'own-talk-drain-overlap-',
        );
        addTearDown(() async => dir.delete(recursive: true));
        final file = File('${dir.path}/outbox.sqlite');
        final dbA = AppDatabase.forTesting(NativeDatabase(file));
        final dbB = AppDatabase.forTesting(NativeDatabase(file));
        addTearDown(dbA.close);
        addTearDown(dbB.close);
        final accountsA = AccountRepository(dbA);
        final accountsB = AccountRepository(dbB);
        final chatA = ChatRepository(dbA);
        final chatB = ChatRepository(dbB);
        final localVault = MemoryCredentialVault();
        const accountId = 'audit-account';
        const roomToken = 'rooma123';
        await accountsA.upsertAccount(
          accountId: accountId,
          serverUrl: 'https://cloud.example.invalid',
          loginName: 'fixture-user',
          serverProductName: 'Nextcloud',
          createdAt: DateTime.utc(2026, 1, 1),
        );
        localVault.values[accountId] = 'synthetic-password-no-network';
        await _cacheConversation(dbA, accountId: accountId);
        const features = {'conversation-v4', 'chat-v2', 'chat-reference-id'};
        await accountsA.updateTalkFeatures(accountId, features);
        await chatA.recordCapabilities(
          accountId: accountId,
          talkFeatures: features,
          observedAt: DateTime.utc(2026, 1, 1),
        );

        final offlineApi = HttpNextcloudApi(client: OfflineClient());
        addTearDown(offlineApi.close);
        final seed = ChatService(
          accounts: accountsA,
          chat: chatA,
          credentials: localVault,
          api: offlineApi,
        );
        addTearDown(seed.close);
        await seed.sendText(
          accountId: accountId,
          roomToken: roomToken,
          message: 'offline queued text',
        );
        await waitForUnsentTextSends(dbA);
        await seed.close();

        final postStarted = Completer<void>();
        final releasePost = Completer<void>();
        var postsA = 0;
        var postsB = 0;
        int? statusA;
        final apiA = HttpNextcloudApi(
          client: _sendServer((request) async {
            postsA++;
            if (!postStarted.isCompleted) postStarted.complete();
            await releasePost.future;
            final response = _acceptedSend(request, 121);
            statusA = response.statusCode;
            return response;
          }),
        );
        final apiB = HttpNextcloudApi(
          client: _sendServer((request) {
            postsB++;
            return _acceptedSend(request, 122);
          }),
        );
        addTearDown(apiA.close);
        addTearDown(apiB.close);
        final failingRelease = rejectRelease
            ? _LosesTextSendReleaseReply(textSendOwnership())
            : null;
        final first = ChatService(
          accounts: accountsA,
          chat: chatA,
          credentials: localVault,
          api: apiA,
          ownership: failingRelease,
        );
        final second = ChatService(
          accounts: accountsB,
          chat: chatB,
          credentials: localVault,
          api: apiB,
        );
        addTearDown(first.close);
        addTearDown(second.close);
        final queued = await dbA.select(dbA.textSendOperations).getSingle();
        if (rejectConfirmation) {
          await (dbA.update(
            dbA.textSendOperations,
          )..where((row) => row.operationId.equals(queued.operationId))).write(
            const TextSendOperationsCompanion(
              outboxState: Value('awaitingConfirmation'),
              nextAttemptAt: Value(null),
            ),
          );
        }
        final firstRun = rejectConfirmation
            ? expectLater(
                first.resendText(
                  accountId: accountId,
                  roomToken: roomToken,
                  operationId: queued.operationId,
                ),
                throwsA(
                  predicate(
                    (Object? error) =>
                        '$error'.contains('reject audit confirmation'),
                  ),
                ),
              )
            : first.drainPendingSends();
        try {
          await postStarted.future.timeout(const Duration(seconds: 5));
          final live = await dbA.select(dbA.textSendOperations).getSingle();
          expect(live.outboxState, 'sending');
          if (overlap) {
            await second.drainPendingSends().timeout(
              const Duration(seconds: 5),
            );
          }
          final afterSecond = await dbB
              .select(dbB.textSendOperations)
              .getSingle();
          if (rejectConfirmation) {
            await dbA.customStatement('''
                CREATE TRIGGER reject_audit_confirmation BEFORE INSERT ON text_send_operations
                WHEN NEW.outbox_state = 'completed'
                BEGIN SELECT RAISE(ABORT, 'reject audit confirmation'); END
              ''');
          }
          releasePost.complete();
          await firstRun.timeout(const Duration(seconds: 5));
          expect(statusA, 201);
          if (rejectConfirmation) {
            expect(
              (await dbA.select(dbA.textSendOperations).getSingle())
                  .outboxState,
              'sending',
            );
            await dbA.customStatement('DROP TRIGGER reject_audit_confirmation');
          }
          if (!overlap) await second.drainPendingSends();
          final terminal = await dbA.select(dbA.textSendOperations).getSingle();
          stdout.writeln(
            'BACKGROUND_TEXT_OVERLAP overlap=$overlap '
            'rejectConfirmation=$rejectConfirmation statusA=$statusA '
            'rejectRelease=$rejectRelease '
            'afterSecond=${afterSecond.outboxState} reason=${afterSecond.errorClass} '
            'terminal=${terminal.outboxState} ids=${terminal.messageIdsJson} '
            'mockPosts=$postsA/$postsB',
          );
          expect(
            (
              afterSecond.outboxState,
              terminal.outboxState,
              terminal.messageIdsJson,
            ),
            rejectConfirmation
                ? ('sending', 'awaitingConfirmation', '[]')
                : ('sending', 'completed', '[121]'),
          );
          if (rejectConfirmation) {
            expect(terminal.errorClass, 'process-interrupted');
          }
          expect((postsA, postsB), (1, 0));
          expect(failingRelease?.releases ?? 0, rejectRelease ? 1 : 0);
        } finally {
          if (!releasePost.isCompleted) releasePost.complete();
          await firstRun;
        }
      });
    }

    test('text send ownership survives only a committed live claim', () async {
      const id = 'account-a';
      final token = ConversationToken.parse('rooma123', path: r'$.roomToken');
      final operation = ChatOperationId.parse(
        '00000000-0000-4000-8000-000000000187',
      );
      const features = {'conversation-v4', 'chat-v2', 'chat-reference-id'};
      final capability = await chat.recordCapabilities(
        accountId: id,
        talkFeatures: features,
        observedAt: DateTime.utc(2026, 1, 1),
      );
      final authority = ChatTextSendAuthority(
        accountId: AccountId.parse(id),
        server: ServerBase.parse('https://cloud.example.invalid'),
        capabilityGeneration: capability.generation,
        profile: ChatCapabilityProfile.fromTalkFeatures(
          features.toList(),
          federated: false,
        ),
        replayContractRevision: textSendReplayContractRevision,
      );
      await chat.admitTextSend(
        accountId: id,
        roomToken: token,
        authority: authority,
        operationId: operation,
        referenceId: ChatReferenceId.parse(
          '00000000-0000-4000-8000-000000000188',
        ),
        message: 'queued text',
      );
      final ownership = LocalTextSendOwnership();
      Future<ClaimedTextSend?> claim() => chat.claimNextTextSend(
        accountId: id,
        roomToken: token,
        authority: authority,
        requestId: ChatRequestId.parse('claim-audit'),
        now: 10,
        ownership: ownership,
      );
      Future<StoredTextSendOperation> row() =>
          database.select(database.textSendOperations).getSingle();

      await database.customStatement('''
        CREATE TRIGGER reject_audit_claim BEFORE INSERT ON text_send_operations
        WHEN NEW.outbox_state = 'sending'
        BEGIN SELECT RAISE(ABORT, 'reject audit claim'); END
      ''');
      await expectLater(
        claim(),
        throwsA(
          predicate((Object? error) => '$error'.contains('reject audit claim')),
        ),
      );
      expect(await ownership.active(id), isEmpty);
      expect((await row()).outboxState, 'queued');
      await database.customStatement('DROP TRIGGER reject_audit_claim');

      final owned = (await claim())!;
      final recovering = ChatRepository(database);
      await recovering.recoverInterruptedTextSends(id, ownership: ownership);
      expect((await row()).outboxState, 'sending');
      await owned.reservation!.release();
      await recovering.recoverInterruptedTextSends(id, ownership: ownership);
      final abandoned = await row();
      expect(abandoned.outboxState, 'awaitingConfirmation');
      expect(abandoned.errorClass, 'process-interrupted');

      final manual = (await chat.manuallyResend(
        accountId: id,
        operationId: operation,
        authority: authority,
        requestId: ChatRequestId.parse('manual-audit'),
        ownership: ownership,
      ))!;
      addTearDown(manual.reservation!.release);
      await recovering.recoverInterruptedTextSends(id, ownership: ownership);
      expect(await ownership.active(id), {operation});
      expect((await row()).outboxState, 'sending');
    });

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
        // A poll hands the outbox on without waiting for it.
        await _waitForOutboxSettled(chat);
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
        // The first was already tried once in the tunnel that queued it.
        expect(completed.map((row) => row.attemptCount), [2, 1]);
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

final class _LosesTextSendReleaseReply implements TextSendOwnership {
  _LosesTextSendReleaseReply(this.delegate);

  final TextSendOwnership delegate;
  int releases = 0;

  @override
  Future<TextSendReservation?> acquire(
    String accountId,
    ChatOperationId id,
  ) async {
    final reservation = await delegate.acquire(accountId, id);
    if (reservation == null) return null;
    return TextSendReservation(() async {
      releases++;
      await reservation.release();
      throw StateError('audit release reply lost');
    });
  }

  @override
  Future<Set<ChatOperationId>> active(String accountId) =>
      delegate.active(accountId);
}
