part of 'attachment_service_test.dart';

void _registerAttachmentServiceRecoveryTests() {
  test(
    'room scheduler reruns work enqueued while its run becomes idle',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final idleReached = Completer<void>();
      final releaseIdle = Completer<void>();
      var idleCount = 0;
      var finalized = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            finalized++;
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        identifierFactory: _SequentialIdentifierFactory(),
        beforeRoomIdle: () async {
          idleCount++;
          if (idleCount == 2) {
            idleReached.complete();
            await releaseIdle.future;
          }
        },
      );
      addTearDown(() async {
        if (!releaseIdle.isCompleted) {
          releaseIdle.complete();
        }
        await service.close();
      });

      final first = await service.enqueue(fixture.request(normalMaximum: 32));
      await first.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      await fixture.cacheConfirmation(messageId: 111);
      await first.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.completed,
      );
      await idleReached.future.timeout(const Duration(seconds: 2));
      await fixture.sourceFile.writeAsBytes(fixture.bytes, flush: true);

      final second = await service.enqueue(fixture.request(normalMaximum: 32));
      releaseIdle.complete();
      await second.events
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          )
          .timeout(const Duration(seconds: 2));

      expect(finalized, 2);
    },
  );

  test('close waits for startup terminal source release', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final jobId = await fixture.seedTerminal(messageId: 108);
    final releaseStarted = Completer<void>();
    final allowRelease = Completer<void>();
    var releaseCalls = 0;
    final service = fixture.service(
      _unexpectedClient(),
      releaseSource: (source) async {
        releaseCalls++;
        if (!releaseStarted.isCompleted) {
          releaseStarted.complete();
        }
        await allowRelease.future;
        final file = File.fromUri(Uri.parse(source.handle.value));
        if (await file.exists()) {
          await file.delete();
        }
      },
    );
    addTearDown(() async {
      if (!allowRelease.isCompleted) {
        allowRelease.complete();
      }
      await service.close();
    });

    await service.ready;
    var closeCompleted = false;
    final close = service.close().whenComplete(() => closeCompleted = true);
    await releaseStarted.future.timeout(const Duration(seconds: 1));
    await pumpEventQueue(times: 10);

    expect(closeCompleted, isFalse);
    allowRelease.complete();
    await close;
    final stored = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(releaseCalls, 1);
    expect(stored?.sourceReleased, isTrue);
  });

  test(
    'multiple cached matches stay ambiguous without an observer loop',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      var requestCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          requestCount++;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(service.close);
      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );

      await fixture.database.transaction(() async {
        await fixture.cacheConfirmation(messageId: 105);
        await fixture.cacheConfirmation(messageId: 106);
      });
      final ambiguous = await session.events.firstWhere(
        (event) => event.errorClass == 'multiple-attachment-matches',
      );
      await pumpEventQueue(times: 10);
      final stable = await fixture.repository.getStoredJob(
        accountId: 'account-a',
        jobId: session.jobId.value,
      );

      expect(ambiguous.phase, AttachmentJobPhase.awaitingConfirmation);
      expect(ambiguous.messageIds, [105, 106]);
      expect(stable?.messageIdsJson, '[105,106]');
      expect(stable?.errorClass, 'multiple-attachment-matches');
      expect(requestCount, 3);
    },
  );

  test(
    'observer errors neither replay transport nor poison later snapshots',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);
      final cancelled = Completer<void>();
      final controller = StreamController<AttachmentConfirmationSnapshot>(
        onCancel: () {
          if (!cancelled.isCompleted) {
            cancelled.complete();
          }
        },
      );
      addTearDown(controller.close);
      final service = fixture.service(
        _unexpectedClient(),
        watchConfirmationCandidates: () => controller.stream,
      );
      addTearDown(service.close);
      await service.ready;
      await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          );

      controller.addError(
        StateError('Synthetic confirmation observation failure'),
        StackTrace.current,
      );
      await pumpEventQueue();
      expect(
        (await fixture.repository.getStoredJob(
          accountId: 'account-a',
          jobId: jobId.value,
        ))?.phase,
        AttachmentJobPhase.awaitingConfirmation.name,
      );
      controller.add(
        AttachmentConfirmationSnapshot(<AttachmentConfirmationBatch>[
          AttachmentConfirmationBatch(
            accountId: AccountId.parse('account-a'),
            jobId: jobId,
            confirmations: <AttachmentMessageConfirmation>[
              fixture.confirmation(jobId, messageId: 107),
            ],
          ),
        ]),
      );
      await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed);

      await service.close();
      expect(cancelled.isCompleted, isTrue);
    },
  );

  test(
    'observed confirmation retries locally after one persistence failure',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);
      final controller = StreamController<AttachmentConfirmationSnapshot>();
      addTearDown(controller.close);
      var completedPersistAttempts = 0;
      final service = fixture.service(
        _unexpectedClient(),
        watchConfirmationCandidates: () => controller.stream,
        persistTransition:
            ({
              required account,
              required job,
              required metadata,
              required updatedAt,
            }) async {
              if (job.phase == AttachmentJobPhase.completed &&
                  !metadata.sourceReleased) {
                completedPersistAttempts++;
                if (completedPersistAttempts == 1) {
                  throw StateError('Synthetic one-shot persistence failure');
                }
              }
              await fixture.repository.persistTransition(
                account: account,
                job: job,
                metadata: metadata,
                updatedAt: updatedAt,
              );
            },
      );
      addTearDown(service.close);
      await service.ready;
      await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          );

      controller.add(
        AttachmentConfirmationSnapshot(<AttachmentConfirmationBatch>[
          AttachmentConfirmationBatch(
            accountId: AccountId.parse('account-a'),
            jobId: jobId,
            confirmations: <AttachmentMessageConfirmation>[
              fixture.confirmation(jobId, messageId: 109),
            ],
          ),
        ]),
      );
      final completed = await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
          .timeout(const Duration(seconds: 2));

      expect(completed.messageIds, [109]);
      expect(completedPersistAttempts, 2);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test(
    'cancel aborts ambiguous upload without deleting the remote path',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final putStarted = Completer<void>();
      var deleteCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            putStarted.complete();
            final abort = (request as http.Abortable).abortTrigger;
            await abort;
            throw http.RequestAbortedException(request.url);
          }
          if (request.method == 'DELETE') {
            deleteCount++;
            return http.Response('', 204);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      await putStarted.future;
      await session.cancel();
      final cancelled = await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.cancelled,
      );

      expect(cancelled.phase, AttachmentJobPhase.cancelled);
      expect(deleteCount, 0);
      expect(await fixture.sourceFile.exists(), isFalse);
    },
  );

  test('concurrent cancel releases a terminal source once', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final releaseStarted = Completer<void>();
    final allowRelease = Completer<void>();
    var releaseCalls = 0;
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_ocsFailure(400), 400);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
      releaseSource: (source) async {
        final call = ++releaseCalls;
        if (!releaseStarted.isCompleted) {
          releaseStarted.complete();
        }
        await allowRelease.future;
        if (call > 1) {
          throw StateError('Synthetic duplicate release failure');
        }
        final file = File.fromUri(Uri.parse(source.handle.value));
        if (await file.exists()) {
          await file.delete();
        }
      },
    );
    addTearDown(() async {
      if (!allowRelease.isCompleted) {
        allowRelease.complete();
      }
      await service.close();
    });

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.failed,
    );
    final firstCancel = session.cancel();
    await releaseStarted.future.timeout(const Duration(seconds: 1));
    final secondCancel = session.cancel();
    await pumpEventQueue(times: 20);

    expect(releaseCalls, 1);
    allowRelease.complete();
    await Future.wait<void>([firstCancel, secondCancel]);
    final stored = await fixture.repository.getStoredJob(
      accountId: session.accountId.value,
      jobId: session.jobId.value,
    );

    expect(stored?.sourceReleased, isTrue);
    expect(stored?.localCleanupError, isNull);
  });

  test(
    'bounds automatic retries without deleting the pending source',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      var probeCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            probeCount++;
            if (probeCount <= 2) {
              return http.Response.bytes(_ocsFailure(503), 503);
            }
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        retryDelays: const [Duration.zero],
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      final exhausted = await session.events.firstWhere(
        (event) =>
            event.phase == AttachmentJobPhase.retryable &&
            event.automaticRetryCount == 2,
      );

      expect(exhausted.retryAllowed, isTrue);
      expect(probeCount, 2);
      expect(await fixture.sourceFile.exists(), isTrue);

      await session.retry();
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      expect(probeCount, 3);
    },
  );

  test(
    'a network hint retries an upload whose automatic retries ran out',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      var probeCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            probeCount++;
            if (probeCount <= 2) {
              throw const SocketException('offline');
            }
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        retryDelays: const [Duration.zero],
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      await session.events.firstWhere(
        (event) =>
            event.phase == AttachmentJobPhase.retryable &&
            event.automaticRetryCount == 2,
      );
      expect(probeCount, 2);

      await service.resumeRetries();
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      expect(probeCount, 3);
    },
  );

  test('voice attachment keeps its audio metadata through enqueue', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 201);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/attachment')) {
          return http.Response.bytes(
            _finalizeSuccess(fileName: 'recording.mp3'),
            200,
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(
      fixture.request(
        normalMaximum: 32,
        kind: AttachmentMessageKind.voice,
        mimeType: 'audio/mpeg',
        displayName: 'recording.mp3',
      ),
    );
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );
    final persisted = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: session.jobId.value,
    );

    expect(persisted?.messageKind, AttachmentMessageKind.voice.name);
    expect(persisted?.sourceMimeType, 'audio/mpeg');
  });

  test('401 pauses the account and fresh credentials resume upload', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var authenticated = false;
    var probeCount = 0;
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          probeCount++;
          if (!authenticated) {
            return http.Response.bytes(_ocsFailure(401), 401);
          }
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 201);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/attachment')) {
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final paused = await session.events.firstWhere(
      (event) => event.errorClass == 'reauthentication-required',
    );
    final pausedRuntime = await fixture.repository.loadRuntime();

    expect(paused.phase, AttachmentJobPhase.retryable);
    expect(
      pausedRuntime.snapshot.accounts[AccountId.parse('account-a')]?.lane,
      AttachmentAccountLane.reauthenticationRequired,
    );
    expect(probeCount, 1);

    authenticated = true;
    await fixture.credentials.writeAppPassword(
      'account-a',
      'refreshed-fixture-password',
    );
    await service.completeReauthentication(
      accountId: AccountId.parse('account-a'),
      credentialGeneration: 2,
      capabilityGeneration: 1,
    );
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );
    final resumedRuntime = await fixture.repository.loadRuntime();

    expect(probeCount, 2);
    expect(
      resumedRuntime.snapshot.accounts[AccountId.parse('account-a')]?.lane,
      AttachmentAccountLane.ready,
    );
    expect(
      resumedRuntime
          .snapshot
          .accounts[AccountId.parse('account-a')]
          ?.credentialGeneration,
      2,
    );
  });

  test('startup recovers an in-flight upload without blind replay', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final jobId = await fixture.seedInFlight(AttachmentRequestStep.normalPut);
    await fixture.credentials.deleteAppPassword('account-a');

    // The missing password is what stops the scheduler from uploading, but it
    // also starts the credential ladder, and the fixture's default ladder is a
    // single zero-delay step. That escalates to `reauthentication-required`
    // after two event-loop turns and overwrites the `process-interrupted` this
    // test is reading - whichever gets there first. It did on a CI runner and
    // never on a developer machine. A ladder that cannot expire during the
    // assertions removes the race without weakening them: no password, no
    // upload, and `_unexpectedClient` still fails on any request.
    const noEscalation = <Duration>[Duration(minutes: 5)];

    final first = fixture.service(
      _unexpectedClient(),
      credentialRetryDelays: noEscalation,
    );
    await first.ready;
    final recovered = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(recovered?.phase, AttachmentJobPhase.retryable.name);
    expect(recovered?.resumePhase, AttachmentJobPhase.draftResolved.name);
    expect(recovered?.inFlightStep, isNull);
    expect(recovered?.errorClass, 'process-interrupted');
    expect(await fixture.sourceFile.exists(), isTrue);
    await first.close();

    final reopened = fixture.service(
      _unexpectedClient(),
      credentialRetryDelays: noEscalation,
    );
    await reopened.ready;
    final stable = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(stable?.phase, AttachmentJobPhase.retryable.name);
    expect(stable?.inFlightStep, isNull);
    expect(stable?.errorClass, 'process-interrupted');
    await reopened.close();
  });

  test('startup never replays an in-flight finalize request', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);

    final first = fixture.service(_unexpectedClient());
    await first.ready;
    final recovered = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(recovered?.phase, AttachmentJobPhase.awaitingConfirmation.name);
    expect(recovered?.inFlightStep, isNull);
    expect(recovered?.finalizationDispatched, isTrue);
    expect(recovered?.errorClass, 'restart-during-finalize');
    expect(await fixture.sourceFile.exists(), isTrue);
    await first.close();

    final reopened = fixture.service(_unexpectedClient());
    await reopened.ready;
    final stable = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: jobId.value,
    );

    expect(stable?.phase, AttachmentJobPhase.awaitingConfirmation.name);
    expect(stable?.inFlightStep, isNull);
    expect(stable?.errorClass, 'restart-during-finalize');
    await reopened.close();
  });

  test('failed attachment is retained until explicit discard', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_ocsFailure(400), 400);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final failed = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.failed,
    );

    expect(failed.errorClass, 'probe-rejected');
    expect(await fixture.sourceFile.exists(), isTrue);

    await service.discardFailed(
      accountId: session.accountId,
      jobId: session.jobId,
    );
    final discarded = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.cancelled,
    );

    expect(discarded.phase, AttachmentJobPhase.cancelled);
    expect(await fixture.sourceFile.exists(), isFalse);
  });

  test(
    'cancelled recovered upload never deletes an unverified remote path',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.normalPut);
      final sourceProvider = _BlockingSourceProvider(fixture.sourceFile);
      var deleteCount = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'DELETE') {
            deleteCount++;
            return http.Response('', 204);
          }
          fail('Source verification cancellation dispatched: $request');
        }),
        sourceProvider: sourceProvider,
      );
      addTearDown(service.close);

      await service.ready;
      await sourceProvider.opened.future;
      await service.cancel(
        accountId: AccountId.parse('account-a'),
        jobId: jobId,
      );
      final cancelled = await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.cancelled);

      expect(cancelled.phase, AttachmentJobPhase.cancelled);
      expect(deleteCount, 0);
      expect(sourceProvider.leaseClosed.isCompleted, isTrue);
      expect(await fixture.sourceFile.exists(), isFalse);
    },
  );

  test(
    'ambiguous reply finalize survives database reopen and exact catch-up',
    () async {
      final fixture = await _Fixture.create(fileBacked: true);
      addTearDown(fixture.close);
      await fixture.cacheThreadRoot(42);
      var initialRequestCount = 0;
      final initialService = fixture.service(
        MockClient((request) async {
          initialRequestCount++;
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            throw http.ClientException('Synthetic post-dispatch failure');
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(initialService.close);

      final session = await initialService.enqueue(
        fixture.request(normalMaximum: 32, replyTo: 42),
      );
      final ambiguous = await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );

      expect(ambiguous.errorClass, 'ambiguous-finalize-transport');
      expect(initialRequestCount, 3);
      expect(await fixture.sourceFile.exists(), isTrue);
      await initialService.close();
      await fixture.reopenDatabase();

      final exactCatchUpStarted = Completer<void>();
      final allowExactCatchUp = Completer<void>();
      var catchUpCalls = 0;
      var releaseCalls = 0;
      final resumedService = fixture.service(
        _unexpectedClient(),
        watchConfirmationCandidates: () => const Stream.empty(),
        confirmationRetryDelays: const <Duration>[Duration.zero],
        catchUpConfirmation:
            ({
              required accountId,
              required roomToken,
              required threadId,
            }) async {
              expect(accountId.value, 'account-a');
              expect(roomToken.value, 'rooma123');
              expect(threadId, isNull);
              catchUpCalls++;
              if (catchUpCalls == 1) {
                await fixture.cacheConfirmation(
                  messageId: 120,
                  deletedParentMessageId: 41,
                );
                return;
              }
              if (!exactCatchUpStarted.isCompleted) {
                exactCatchUpStarted.complete();
              }
              await allowExactCatchUp.future;
              await fixture.cacheConfirmation(
                messageId: 121,
                deletedParentMessageId: 42,
              );
            },
        releaseSource: (source) async {
          releaseCalls++;
          final file = File.fromUri(Uri.parse(source.handle.value));
          if (await file.exists()) {
            await file.delete();
          }
        },
      );
      addTearDown(() async {
        if (!allowExactCatchUp.isCompleted) {
          allowExactCatchUp.complete();
        }
        await resumedService.close();
      });

      await resumedService.ready;
      await exactCatchUpStarted.future.timeout(const Duration(seconds: 2));
      final wrongParent = await fixture.repository.getStoredJob(
        accountId: session.accountId.value,
        jobId: session.jobId.value,
      );

      expect(wrongParent?.phase, AttachmentJobPhase.awaitingConfirmation.name);
      expect(wrongParent?.messageIdsJson, '[]');
      expect(wrongParent?.sourceReleased, isFalse);
      expect(await fixture.sourceFile.exists(), isTrue);
      allowExactCatchUp.complete();

      final completed = await resumedService
          .watchJob(accountId: session.accountId, jobId: session.jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
          .timeout(const Duration(seconds: 2));
      await _expectFileRemoved(fixture.sourceFile);
      await pumpEventQueue(times: 10);
      final stored = await fixture.repository.getStoredJob(
        accountId: session.accountId.value,
        jobId: session.jobId.value,
      );

      expect(completed.messageIds, [121]);
      expect(stored?.phase, AttachmentJobPhase.completed.name);
      expect(stored?.messageIdsJson, '[121]');
      expect(stored?.sourceReleased, isTrue);
      expect(catchUpCalls, 2);
      expect(releaseCalls, 1);
    },
  );
}
