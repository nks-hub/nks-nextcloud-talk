part of 'attachment_service_test.dart';

void _registerAttachmentServiceLifecycleTests() {
  test(
    'normal upload is durable before enqueue returns and reconciles',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final methods = <String>[];
      final service = fixture.service(
        MockClient((request) async {
          methods.add(request.method);
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            expect(request.bodyBytes, fixture.bytes);
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
      final persisted = await fixture.repository.getStoredJob(
        accountId: 'account-a',
        jobId: session.jobId.value,
      );

      expect(persisted, isNotNull);
      expect(persisted!.phase, isNot(AttachmentJobPhase.completed.name));
      final awaiting = await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      expect(awaiting.progress, 1);
      expect(methods, ['POST', 'PUT', 'POST']);

      await fixture.cacheConfirmation(messageId: 101);
      final completed = await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.completed,
      );

      expect(completed.messageIds, [101]);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test('the credential is read once for an upload, not once per request, and '
      'the account row is written only when it changes', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final vault = _CountingCredentialVault(fixture.credentials);
    var requests = 0;
    final service = fixture.service(
      MockClient((request) async {
        requests++;
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'POST') {
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        return http.Response('', 201);
      }),
      credentialVault: vault,
      clock: () => DateTime.utc(2026, 1, 1).add(Duration(seconds: requests)),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 4));
    final admitted = await fixture.database
        .select(fixture.database.attachmentRuntimeAccounts)
        .getSingle();
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );

    // Probe, MKCOL, two chunks, MOVE and finalize.
    expect(requests, 6);
    // One read to admit the job and one for the whole run.
    expect(vault.reads, 2);
    final after = await fixture.database
        .select(fixture.database.attachmentRuntimeAccounts)
        .getSingle();
    expect(after.updatedAtMillis, admitted.updatedAtMillis);
  });

  test('bytes of the request in flight are reported in memory and cleared '
      'when it ends', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final inFlight = ValueNotifier<Map<String, int>>(const {});
    final seen = <int>[];
    inFlight.addListener(() => seen.addAll(inFlight.value.values));
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 201);
        }
        return http.Response.bytes(_finalizeSuccess(), 200);
      }),
      inFlightBytes: inFlight,
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );

    expect(seen, contains(fixture.bytes.length));
    expect(inFlight.value, isEmpty);
  });

  test('an attachment admitted without a network stays queued as a durable '
      'job', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final service = fixture.service(
      MockClient((request) async {
        throw http.ClientException('Synthetic offline');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final retryable = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.retryable,
    );

    expect(retryable.resumePhase, AttachmentJobPhase.localPrepared);
    final stored = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: session.jobId.value,
    );
    expect(stored, isNotNull);
    expect(await fixture.sourceFile.exists(), isTrue);
  });

  test(
    'chunk upload executes FIFO ranges and moves before finalizing',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final seen = <String>[];
      final service = fixture.service(
        MockClient((request) async {
          seen.add('${request.method} ${request.url.pathSegments.last}');
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'MKCOL') {
            return http.Response('', 201);
          }
          if (request.method == 'PROPFIND') {
            return http.Response(
              _emptyManifest(request.url),
              207,
              headers: const {'content-type': 'application/xml'},
            );
          }
          if (request.method == 'PUT') {
            return http.Response('', 201);
          }
          if (request.method == 'MOVE') {
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

      final session = await service.enqueue(fixture.request(normalMaximum: 4));
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );

      // The collection was created by this run (201), so it is known to be
      // empty and no PROPFIND is spent on listing it.
      expect(seen.map((value) => value.split(' ').first), [
        'POST',
        'MKCOL',
        'PUT',
        'PUT',
        'MOVE',
        'POST',
      ]);
    },
  );

  test('a 413 on a large body falls back to small chunks and is remembered '
      'for the server', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final bytes = Uint8List(2000000)..fillRange(0, 2000000, 0x41);
    final file = File(
      '${fixture.directory.path}${Platform.pathSeparator}large.bin',
    );
    await file.writeAsBytes(bytes, flush: true);
    final source = PreparedAttachmentSource(
      handle: AttachmentSourceHandle.parse(file.uri.toString()),
      ownership: AttachmentSourceOwnership.appOwnedCopy,
      byteLength: bytes.length,
      sha256: AttachmentSha256.parse(sha256.convert(bytes).toString()),
      mimeType: 'image/png',
      displayName: 'source.png',
    );
    final base = fixture.request(normalMaximum: 32, source: source);
    AttachmentEnqueueRequest large() => AttachmentEnqueueRequest(
      accountId: base.accountId,
      server: base.server,
      roomToken: base.roomToken,
      source: source,
      metadata: base.metadata,
      davUserId: base.davUserId,
      profile: base.profile,
      credentialGeneration: base.credentialGeneration,
      capabilityGeneration: base.capabilityGeneration,
      roomCanWrite: base.roomCanWrite,
      policy: AttachmentUploadPolicy(
        normalUploadMaximumBytes: 10 * 1024 * 1024,
        chunkSizeBytes: 5 * 1024 * 1024,
      ),
    );
    final seen = <String>[];
    final service = fixture.service(
      MockClient((request) async {
        seen.add('${request.method} ${request.bodyBytes.length}');
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response(
            '',
            request.bodyBytes.length > 1024000 ? 413 : 201,
          );
        }
        if (request.method == 'MKCOL' || request.method == 'MOVE') {
          return http.Response('', 201);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/attachment')) {
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
      identifierFactory: _SequentialIdentifierFactory(),
    );
    addTearDown(service.close);

    final session = await service.enqueue(large());
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );

    expect(seen, [
      isA<String>(),
      'PUT 2000000',
      'MKCOL 0',
      'PUT 1024000',
      'PUT 976000',
      'MOVE 0',
      isA<String>(),
    ]);

    final later = await service.enqueue(large());
    final stored = await fixture.repository.getStoredJob(
      accountId: 'account-a',
      jobId: later.jobId.value,
    );
    expect(stored!.chunkSizeBytes, 1024000);
    expect(stored.uploadSessionId, isNotNull);
  });

  test(
    'scope collision cannot complete or release a reply attachment',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.cacheThreadRoot(42);
      var releaseCalls = 0;
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
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        releaseSource: (_) async {
          releaseCalls++;
        },
      );
      addTearDown(service.close);

      final session = await service.enqueue(
        fixture.request(normalMaximum: 32, replyTo: 42),
      );
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      await service.reconcileConfirmations(
        accountId: session.accountId,
        confirmations: <AttachmentMessageConfirmation>[
          fixture.confirmation(
            session.jobId,
            messageId: 120,
            parentMessageId: 42,
            parentRoomToken: ConversationToken.parse(
              'rooma123',
              path: r'$.roomToken',
              code: TalkProtocolErrorCode.invalidAttachmentModel,
            ),
            parentThreadId: 76,
            threadId: 77,
          ),
        ],
      );

      final stored = await fixture.repository.getStoredJob(
        accountId: session.accountId.value,
        jobId: session.jobId.value,
      );
      expect(stored?.phase, AttachmentJobPhase.awaitingConfirmation.name);
      expect(stored?.messageIdsJson, '[]');
      expect(releaseCalls, 0);
      expect(await fixture.sourceFile.exists(), isTrue);
    },
  );

  test(
    'deleted reply parent completes and releases its durable source once',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.cacheThreadRoot(42);
      var releaseCalls = 0;
      var catchUpCalls = 0;
      final sourceReleased = Completer<void>();
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
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        releaseSource: (_) async {
          releaseCalls++;
          sourceReleased.complete();
        },
        watchConfirmationCandidates: () => const Stream.empty(),
        catchUpConfirmation:
            ({
              required accountId,
              required roomToken,
              required threadId,
            }) async {
              catchUpCalls++;
              await fixture.cacheConfirmation(
                messageId: 121,
                deletedParentMessageId: 42,
                threadId: 77,
              );

              return ChatSynchronizationResult.converged;
            },
      );
      addTearDown(service.close);

      final session = await service.enqueue(
        fixture.request(normalMaximum: 32, replyTo: 42),
      );
      final completed = await session.events
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
          .timeout(const Duration(seconds: 2));
      await sourceReleased.future.timeout(const Duration(seconds: 2));

      final stored = await fixture.repository.getStoredJob(
        accountId: session.accountId.value,
        jobId: session.jobId.value,
      );
      expect(stored?.phase, AttachmentJobPhase.completed.name);
      expect(stored?.messageIdsJson, '[121]');
      expect(completed.messageIds, [121]);
      expect(catchUpCalls, 1);
      expect(releaseCalls, 1);
    },
  );

  test('ambiguous finalize waits for authoritative confirmation', () async {
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
        throw http.ClientException('Synthetic post-dispatch failure');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final awaiting = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );

    expect(awaiting.errorClass, 'ambiguous-finalize-transport');
    expect(await fixture.sourceFile.exists(), isTrue);
    await fixture.cacheConfirmation(messageId: 102);
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.completed,
    );
  });

  test('cached message completes a job that is admitted later', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    await fixture.cacheConfirmation(messageId: 103);
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
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final completed = await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.completed,
    );

    expect(completed.messageIds, [103]);
    await _expectFileRemoved(fixture.sourceFile);
  });

  test(
    'startup reconciles a cached message with a recovered finalize',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);
      await fixture.cacheConfirmation(messageId: 104);
      final service = fixture.service(_unexpectedClient());
      addTearDown(service.close);

      await service.ready;
      final completed = await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed);

      expect(completed.messageIds, [104]);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test(
    'startup catch-up retries and reconciles only authoritative cache',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.finalize);
      var catchUpCalls = 0;
      final service = fixture.service(
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
                throw StateError('Synthetic first catch-up failure');
              }
              await fixture.cacheConfirmation(messageId: 110);

              return ChatSynchronizationResult.converged;
            },
      );
      addTearDown(service.close);

      await service.ready;
      final completed = await service
          .watchJob(accountId: AccountId.parse('account-a'), jobId: jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
          .timeout(const Duration(seconds: 2));

      expect(catchUpCalls, 2);
      expect(completed.messageIds, [110]);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test('pending confirmation allows a later room DAV upload', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var uploaded = 0;
    var finalized = 0;
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          uploaded++;
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
    );
    addTearDown(service.close);

    final first = await service.enqueue(fixture.request(normalMaximum: 32));
    await first.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
    );
    final second = await service.enqueue(fixture.request(normalMaximum: 32));
    final secondUploaded = await second.events
        .firstWhere((event) => event.phase == AttachmentJobPhase.uploaded)
        .timeout(const Duration(seconds: 2));

    expect(secondUploaded.phase, AttachmentJobPhase.uploaded);
    expect(uploaded, 2);
    expect(finalized, 1);
    await fixture.cacheConfirmation(messageId: 112);
    await first.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.completed,
    );
    await second.events
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));

    expect(finalized, 2);
  });

  test(
    'exhausted confirmation catch-up persists reconciliation and retries safely',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final firstCatchUpStarted = Completer<void>();
      final releaseFirstCatchUp = Completer<void>();
      final finalCatchUpStarted = Completer<void>();
      final releaseFinalCatchUp = Completer<void>();
      var catchUpCalls = 0;
      var confirmFirstJob = false;
      var uploaded = 0;
      var finalized = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            uploaded++;
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
        confirmationRetryDelays: const <Duration>[Duration.zero, Duration.zero],
        catchUpConfirmation:
            ({
              required accountId,
              required roomToken,
              required threadId,
            }) async {
              catchUpCalls++;
              if (catchUpCalls == 1) {
                firstCatchUpStarted.complete();
                await releaseFirstCatchUp.future;
                await fixture.cacheConfirmation(
                  messageId: 113,
                  hasFileRichObject: false,
                );
              } else if (catchUpCalls == 3) {
                finalCatchUpStarted.complete();
                await releaseFinalCatchUp.future;
              } else if (confirmFirstJob) {
                await fixture.cacheConfirmation(messageId: 114);
              }

              return ChatSynchronizationResult.converged;
            },
      );
      addTearDown(service.close);

      final first = await service.enqueue(fixture.request(normalMaximum: 32));
      await first.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      );
      await firstCatchUpStarted.future.timeout(const Duration(seconds: 2));

      final second = await service.enqueue(fixture.request(normalMaximum: 32));
      await second.events
          .firstWhere((event) => event.phase == AttachmentJobPhase.uploaded)
          .timeout(const Duration(seconds: 2));
      expect(uploaded, 2);
      expect(finalized, 1);
      expect(await fixture.sourceFile.exists(), isTrue);

      releaseFirstCatchUp.complete();
      await finalCatchUpStarted.future.timeout(const Duration(seconds: 2));
      releaseFinalCatchUp.complete();
      final reconciliationRequired = await first.events
          .firstWhere(
            (event) =>
                event.errorClass ==
                attachmentConfirmationReconciliationRequired,
          )
          .timeout(const Duration(seconds: 2));
      final storedFirst = await fixture.repository.getStoredJob(
        accountId: 'account-a',
        jobId: first.jobId.value,
      );
      // A parked confirmation waits for an explicit retry, so it stops holding
      // room order and the second job finalizes without one.
      await second.events
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          )
          .timeout(const Duration(seconds: 2));

      expect(catchUpCalls, greaterThanOrEqualTo(3));
      expect(
        reconciliationRequired.phase,
        AttachmentJobPhase.awaitingConfirmation,
      );
      expect(reconciliationRequired.automaticRetryCount, 3);
      expect(reconciliationRequired.retryAllowed, isTrue);
      expect(
        storedFirst?.errorClass,
        attachmentConfirmationReconciliationRequired,
      );
      expect(storedFirst?.automaticRetryCount, 3);
      expect(storedFirst?.nextAttemptAtMillis, isNull);
      expect(await fixture.sourceFile.exists(), isTrue);
      expect(finalized, 2);

      confirmFirstJob = true;
      await first.retry();
      await first.events
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
          .timeout(const Duration(seconds: 2));
      await second.events
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          )
          .timeout(const Duration(seconds: 2));

      expect(catchUpCalls, greaterThanOrEqualTo(4));
      expect(finalized, 2);
    },
  );

  test(
    'reconciliation marker survives restart and requires explicit retry',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      var initialCatchUps = 0;
      var finalized = 0;
      final initialService = fixture.service(
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
        catchUpConfirmation:
            ({
              required accountId,
              required roomToken,
              required threadId,
            }) async {
              initialCatchUps++;

              return ChatSynchronizationResult.converged;
            },
      );
      addTearDown(initialService.close);

      final session = await initialService.enqueue(
        fixture.request(normalMaximum: 32),
      );
      final reconciliationRequired = await session.events
          .firstWhere((event) => event.confirmationReconciliationRequired)
          .timeout(const Duration(seconds: 2));

      expect(initialCatchUps, 1);
      expect(reconciliationRequired.retryAllowed, isTrue);
      expect(finalized, 1);
      expect(await fixture.sourceFile.exists(), isTrue);
      await initialService.close();

      var resumedCatchUps = 0;
      var resumedRequests = 0;
      final resumedService = fixture.service(
        MockClient((request) async {
          resumedRequests++;
          fail('Restart must not replay ${request.method} ${request.url}');
        }),
        catchUpConfirmation:
            ({
              required accountId,
              required roomToken,
              required threadId,
            }) async {
              resumedCatchUps++;
              await fixture.cacheConfirmation(messageId: 115);

              return ChatSynchronizationResult.converged;
            },
      );
      addTearDown(resumedService.close);

      await resumedService.ready;
      await pumpEventQueue(times: 20);
      final retained = await resumedService
          .watchJob(accountId: session.accountId, jobId: session.jobId)
          .first;

      expect(retained.confirmationReconciliationRequired, isTrue);
      expect(retained.retryAllowed, isTrue);
      expect(resumedCatchUps, 0);
      expect(resumedRequests, 0);

      final completed = resumedService
          .watchJob(accountId: session.accountId, jobId: session.jobId)
          .firstWhere((event) => event.phase == AttachmentJobPhase.completed);
      await resumedService.retry(
        accountId: session.accountId,
        jobId: session.jobId,
      );
      await completed.timeout(const Duration(seconds: 2));

      expect(resumedCatchUps, 1);
      expect(resumedRequests, 0);
      expect(finalized, 1);
      await _expectFileRemoved(fixture.sourceFile);
    },
  );

  test('retries reconciliation marker persistence after one failure', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var markerPersistAttempts = 0;
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
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
      catchUpConfirmation:
          ({required accountId, required roomToken, required threadId}) async {
            return ChatSynchronizationResult.converged;
          },
      persistTransition:
          ({
            required account,
            required job,
            required metadata,
            required updatedAt,
          }) async {
            if (job.phase == AttachmentJobPhase.awaitingConfirmation &&
                job.errorClass ==
                    attachmentConfirmationReconciliationRequired) {
              markerPersistAttempts++;
              if (markerPersistAttempts == 1) {
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

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final reconciliationRequired = await session.events
        .firstWhere((event) => event.confirmationReconciliationRequired)
        .timeout(const Duration(seconds: 2));

    expect(reconciliationRequired.retryAllowed, isTrue);
    expect(markerPersistAttempts, 2);
    expect(await fixture.sourceFile.exists(), isTrue);
  });

  test('close persists an exhausted in-flight reconciliation', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final lastCatchUpStarted = Completer<void>();
    final releaseLastCatchUp = Completer<void>();
    var catchUpCalls = 0;
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
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
      confirmationRetryDelays: const <Duration>[Duration.zero],
      catchUpConfirmation:
          ({required accountId, required roomToken, required threadId}) async {
            catchUpCalls++;
            if (catchUpCalls == 2) {
              lastCatchUpStarted.complete();
              await releaseLastCatchUp.future;
            }

            return ChatSynchronizationResult.converged;
          },
    );
    addTearDown(() async {
      if (!releaseLastCatchUp.isCompleted) {
        releaseLastCatchUp.complete();
      }
      await service.close();
    });

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    await lastCatchUpStarted.future.timeout(const Duration(seconds: 2));
    final close = service.close();
    releaseLastCatchUp.complete();
    await close.timeout(const Duration(seconds: 2));

    final stored = await fixture.repository.getStoredJob(
      accountId: session.accountId.value,
      jobId: session.jobId.value,
    );
    expect(catchUpCalls, 2);
    expect(stored?.errorClass, attachmentConfirmationReconciliationRequired);
    expect(stored?.automaticRetryCount, 2);

    var restartedCatchUps = 0;
    final restarted = fixture.service(
      _unexpectedClient(),
      catchUpConfirmation:
          ({required accountId, required roomToken, required threadId}) async {
            restartedCatchUps++;

            return ChatSynchronizationResult.converged;
          },
    );
    addTearDown(restarted.close);
    await restarted.ready;
    await pumpEventQueue(times: 20);

    expect(restartedCatchUps, 0);
  });
}
