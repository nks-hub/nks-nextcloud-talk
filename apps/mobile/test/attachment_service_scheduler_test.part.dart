part of 'attachment_service_test.dart';

void _registerAttachmentServiceSchedulerTests() {
  test(
    'temporary credential denial after admission does not strand upload',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final vault = _SequencedCredentialVault();
      final diagnostics = <AttachmentUploadDiagnostic>[];
      final client = MockClient((request) async {
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
      });
      final service = fixture.service(
        client,
        credentialVault: vault,
        reportDiagnostic: diagnostics.add,
        credentialRetryDelays: const <Duration>[Duration.zero],
        identifierFactory: _SequentialIdentifierFactory(),
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      await session.events
          .firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          )
          .timeout(const Duration(seconds: 2));

      expect(vault.readCount, greaterThanOrEqualTo(3));
      final credentialEvents = diagnostics.where(
        (event) =>
            event.checkpoint ==
            AttachmentUploadCheckpoint.credentialUnavailable,
      );
      expect(credentialEvents, hasLength(1));
      final diagnostic = credentialEvents.single;
      expect(diagnostic.credentialRetryCount, 1);
      expect(diagnostic.retryScheduled, isTrue);
      expect(diagnostic.retryDelay, Duration.zero);
    },
  );

  test('bounded credential retries end in visible reauthentication', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final vault = _SequencedCredentialVault(denials: 3);
    final service = fixture.service(
      MockClient((request) async {
        fail('Credential denial must stop before HTTP: ${request.url}');
      }),
      credentialVault: vault,
      credentialRetryDelays: const <Duration>[Duration.zero, Duration.zero],
      identifierFactory: _SequentialIdentifierFactory(),
    );
    addTearDown(service.close);

    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    final failed = await session.events
        .firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.errorClass == 'reauthentication-required',
        )
        .timeout(const Duration(seconds: 2));

    expect(failed.retryAllowed, isTrue);
    expect(vault.readCount, 4);
  });

  test('close wins a pending credential read without arming retry', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final vault = _BlockingSecondCredentialVault();
    final timers = <_RecordingRetryTimer>[];
    final diagnostics = <AttachmentUploadDiagnostic>[];
    final service = fixture.service(
      MockClient((request) async {
        fail('Closed credential gate must not send HTTP: ${request.url}');
      }),
      credentialVault: vault,
      credentialRetryDelays: const <Duration>[Duration(minutes: 1)],
      reportDiagnostic: diagnostics.add,
      createRetryTimer: (delay, callback) {
        final timer = _RecordingRetryTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
      identifierFactory: _SequentialIdentifierFactory(),
    );

    await service.enqueue(fixture.request(normalMaximum: 32));
    await vault.secondReadStarted.future.timeout(const Duration(seconds: 2));
    final closing = service.close();
    await pumpEventQueue();
    vault.releaseSecondRead.completeError(
      const CredentialVaultTemporarilyUnavailable(),
    );
    await closing.timeout(const Duration(seconds: 2));

    expect(timers.where((timer) => timer.isActive), isEmpty);
    expect(diagnostics, isEmpty);
  });

  test('later retry cannot replace an earlier room retry timer', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var now = DateTime.utc(2026, 9, 1, 12);
    final timers = <_RecordingRetryTimer>[];
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
        return http.Response('', 503);
      }
      fail('Unexpected request: ${request.method} ${request.url}');
    });
    final service = fixture.service(
      client,
      retryDelays: const <Duration>[Duration(minutes: 1)],
      identifierFactory: _SequentialIdentifierFactory(),
      clock: () => now,
      createRetryTimer: (delay, callback) {
        final timer = _RecordingRetryTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(service.close);

    final first = await service.enqueue(fixture.request(normalMaximum: 32));
    await first.events
        .firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.automaticRetryCount == 1,
        )
        .timeout(const Duration(seconds: 2));
    expect(timers, hasLength(1));
    final firstTimer = timers.single;

    now = now.add(const Duration(seconds: 45));
    final secondSource = await _createDistinctAttachmentSource(fixture);
    final second = await service.enqueue(
      fixture.request(normalMaximum: 32, source: secondSource.source),
    );
    await second.events
        .firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.automaticRetryCount == 1,
        )
        .timeout(const Duration(seconds: 2));

    expect(timers, hasLength(1));
    expect(firstTimer.isActive, isTrue);
  });

  test('manual retry restores FIFO before later finalization', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var acceptRequests = false;
    var probeCount = 0;
    var finalized = 0;
    final firstRetryProbeStarted = Completer<void>();
    final releaseFirstRetryProbe = Completer<void>();
    late _RecordingRetryTimer retryTimer;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
        probeCount++;
        if (probeCount == 3) {
          firstRetryProbeStarted.complete();
          await releaseFirstRetryProbe.future;
        }
        return acceptRequests
            ? http.Response.bytes(_probeSuccess(), 200)
            : http.Response('', 503);
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
    });
    AttachmentJobId? secondJobId;
    final secondFinalizationSelected = Completer<void>();
    final continueSecondFinalization = Completer<void>();
    final service = fixture.service(
      client,
      retryDelays: const <Duration>[Duration(minutes: 1)],
      identifierFactory: _SequentialIdentifierFactory(),
      createRetryTimer: (delay, callback) {
        retryTimer = _RecordingRetryTimer(delay, callback);
        return retryTimer;
      },
      beforeStepPlan: ({required jobId, required phase}) async {
        if (jobId == secondJobId && phase == AttachmentJobPhase.uploaded) {
          if (!secondFinalizationSelected.isCompleted) {
            secondFinalizationSelected.complete();
          }
          await continueSecondFinalization.future;
        }
      },
    );
    addTearDown(service.close);

    final first = await service.enqueue(fixture.request(normalMaximum: 32));
    await first.events
        .firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.automaticRetryCount == 1,
        )
        .timeout(const Duration(seconds: 2));

    acceptRequests = true;
    final secondSource = await _createDistinctAttachmentSource(fixture);
    final second = await service.enqueue(
      fixture.request(normalMaximum: 32, source: secondSource.source),
    );
    secondJobId = second.jobId;
    await secondFinalizationSelected.future.timeout(const Duration(seconds: 2));

    final retry = service.retry(accountId: first.accountId, jobId: first.jobId);
    while (retryTimer.isActive) {
      await Future<void>.delayed(Duration.zero);
    }
    continueSecondFinalization.complete();
    await firstRetryProbeStarted.future.timeout(const Duration(seconds: 2));
    expect(finalized, 0);

    releaseFirstRetryProbe.complete();
    await retry.timeout(const Duration(seconds: 2));
  });

  test('scheduled retryable job does not hold a later room upload', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var acceptRequests = false;
    var uploaded = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
        return acceptRequests
            ? http.Response.bytes(_probeSuccess(), 200)
            : http.Response('', 503);
      }
      if (request.method == 'PUT') {
        uploaded++;
        return http.Response('', 201);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/attachment')) {
        return http.Response.bytes(_finalizeSuccess(), 200);
      }
      fail('Unexpected request: ${request.method} ${request.url}');
    });
    final service = fixture.service(
      client,
      retryDelays: const <Duration>[Duration(minutes: 1)],
      identifierFactory: _SequentialIdentifierFactory(),
    );
    addTearDown(service.close);

    final first = await service.enqueue(fixture.request(normalMaximum: 32));
    final firstRetry = await first.events
        .firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.automaticRetryCount == 1,
        )
        .timeout(const Duration(seconds: 2));
    expect(firstRetry.retryAllowed, isTrue);

    final secondSource = await _createDistinctAttachmentSource(fixture);
    acceptRequests = true;
    final second = await service.enqueue(
      fixture.request(normalMaximum: 32, source: secondSource.source),
    );
    await second.events
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));

    expect(uploaded, 1);
  });

  test('exhausted retryable job allows a later room upload', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var acceptRequests = false;
    var uploaded = 0;
    var finalized = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
        return acceptRequests
            ? http.Response.bytes(_probeSuccess(), 200)
            : http.Response('', 503);
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
    });
    final identifiers = _SequentialIdentifierFactory();
    final initial = fixture.service(
      client,
      retryDelays: const <Duration>[Duration.zero],
      identifierFactory: identifiers,
    );
    addTearDown(initial.close);

    final first = await initial.enqueue(fixture.request(normalMaximum: 32));
    await first.events
        .firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.automaticRetryCount == 2,
        )
        .timeout(const Duration(seconds: 2));
    final storedFirst = await fixture.repository.getStoredJob(
      accountId: first.accountId.value,
      jobId: first.jobId.value,
    );
    expect(storedFirst?.nextAttemptAtMillis, isNull);
    expect(await fixture.sourceFile.exists(), isTrue);
    await initial.close();

    final secondSource = await _createDistinctAttachmentSource(fixture);
    acceptRequests = true;
    final restarted = fixture.service(
      client,
      retryDelays: const <Duration>[Duration.zero],
      identifierFactory: identifiers,
    );
    addTearDown(restarted.close);
    await restarted.ready;
    final second = await restarted.enqueue(
      fixture.request(normalMaximum: 32, source: secondSource.source),
    );
    await second.events
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));
    final storedSecond = await fixture.repository.getStoredJob(
      accountId: second.accountId.value,
      jobId: second.jobId.value,
    );
    await fixture.cacheConfirmation(
      messageId: 115,
      referenceId: storedSecond!.referenceId,
    );
    await second.events
        .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
        .timeout(const Duration(seconds: 2));

    expect(uploaded, 1);
    expect(finalized, 1);
    await _expectFileRemoved(secondSource.file);
    final retainedFirst = await fixture.repository.getStoredJob(
      accountId: first.accountId.value,
      jobId: first.jobId.value,
    );
    expect(retainedFirst?.phase, AttachmentJobPhase.retryable.name);
    expect(await fixture.sourceFile.exists(), isTrue);

    await restarted.retry(accountId: first.accountId, jobId: first.jobId);
    await restarted
        .watchJob(accountId: first.accountId, jobId: first.jobId)
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));
    await fixture.cacheConfirmation(messageId: 116);
    await restarted
        .watchJob(accountId: first.accountId, jobId: first.jobId)
        .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
        .timeout(const Duration(seconds: 2));
    expect(uploaded, 2);
    expect(finalized, 2);
    await _expectFileRemoved(fixture.sourceFile);
  });

  test('exhausted cleanup allows a later room upload', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final firstJobId = await fixture.seedInFlight(
      AttachmentRequestStep.cleanupDraftFile,
    );
    final firstAccountId = AccountId.parse('account-a');
    var cleanupSucceeds = false;
    var cleanupAttempts = 0;
    var uploaded = 0;
    var finalized = 0;
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        cleanupAttempts++;
        return http.Response('', cleanupSucceeds ? 204 : 503);
      }
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
    });
    final identifiers = _SequentialIdentifierFactory();
    identifiers.newReferenceId();
    final initial = fixture.service(
      client,
      retryDelays: const <Duration>[Duration.zero],
      identifierFactory: identifiers,
    );
    addTearDown(initial.close);
    await initial.ready;
    await initial
        .watchJob(accountId: firstAccountId, jobId: firstJobId)
        .firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.cleanupFailed &&
              event.automaticRetryCount == 2,
        )
        .timeout(const Duration(seconds: 2));
    await initial.close();

    final secondSource = await _createDistinctAttachmentSource(fixture);
    final restarted = fixture.service(
      client,
      retryDelays: const <Duration>[Duration.zero],
      identifierFactory: identifiers,
    );
    addTearDown(restarted.close);
    await restarted.ready;
    final second = await restarted.enqueue(
      fixture.request(normalMaximum: 32, source: secondSource.source),
    );
    await second.events
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));
    final storedSecond = await fixture.repository.getStoredJob(
      accountId: second.accountId.value,
      jobId: second.jobId.value,
    );
    await fixture.cacheConfirmation(
      messageId: 117,
      referenceId: storedSecond!.referenceId,
    );
    await second.events
        .firstWhere((event) => event.phase == AttachmentJobPhase.completed)
        .timeout(const Duration(seconds: 2));

    expect(uploaded, 1);
    expect(finalized, 1);
    await _expectFileRemoved(secondSource.file);
    expect(await fixture.sourceFile.exists(), isTrue);

    final cleanupAttemptsBeforeManualRetry = cleanupAttempts;
    cleanupSucceeds = true;
    await restarted.retry(accountId: firstAccountId, jobId: firstJobId);
    await restarted
        .watchJob(accountId: firstAccountId, jobId: firstJobId)
        .firstWhere((event) => event.phase == AttachmentJobPhase.cancelled)
        .timeout(const Duration(seconds: 2));
    expect(cleanupAttemptsBeforeManualRetry, greaterThan(0));
    expect(cleanupAttempts, cleanupAttemptsBeforeManualRetry + 1);
    expect(uploaded, 1);
    expect(finalized, 1);
    await _expectFileRemoved(fixture.sourceFile);
  });

  test('a job held back by room order does not strand later uploads', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var probes = 0;
    var uploaded = 0;
    var finalized = 0;
    final catchUpStarted = Completer<void>();
    final releaseCatchUp = Completer<void>();
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          probes++;
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
      confirmationRetryDelays: const <Duration>[Duration(minutes: 10)],
      catchUpConfirmation:
          ({required accountId, required roomToken, required threadId}) async {
            if (!catchUpStarted.isCompleted) {
              catchUpStarted.complete();
            }
            await releaseCatchUp.future;
          },
    );
    addTearDown(service.close);
    addTearDown(releaseCatchUp.complete);

    // The first job holds the room: its confirmation is still being chased, so
    // room order legitimately keeps later jobs short of finalization.
    final first = await service.enqueue(fixture.request(normalMaximum: 32));
    await first.events
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));
    await catchUpStarted.future.timeout(const Duration(seconds: 2));

    final secondSource = await _createDistinctAttachmentSource(fixture);
    final second = await service.enqueue(
      fixture.request(normalMaximum: 32, source: secondSource.source),
    );
    await second.events
        .firstWhere((event) => event.phase == AttachmentJobPhase.uploaded)
        .timeout(const Duration(seconds: 2));

    // A newly picked attachment must still reach the network. Leaving it at
    // localPrepared without a single attempt is the permanent "waiting to
    // upload" the user sees.
    final thirdSource = await _createDistinctAttachmentSource(
      fixture,
      name: 'source-third.bin',
    );
    final third = await service.enqueue(
      fixture.request(normalMaximum: 32, source: thirdSource.source),
    );
    final started = await third.events
        .firstWhere((event) => event.phase == AttachmentJobPhase.uploaded)
        .timeout(const Duration(seconds: 2));

    expect(started.attemptCount, greaterThan(0));
    expect(probes, 3);
    expect(uploaded, 3);
    expect(finalized, 1);
  });

  test('a parked confirmation stops holding the room finalization', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var finalized = 0;
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
          finalized++;
          return http.Response.bytes(
            _finalizeSuccess(fileName: 'source-$finalized.png'),
            200,
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
      identifierFactory: _SequentialIdentifierFactory(),
      confirmationRetryDelays: const <Duration>[],
      catchUpConfirmation:
          ({
            required accountId,
            required roomToken,
            required threadId,
          }) async {},
    );
    addTearDown(service.close);

    // The room never echoes the finalized message back, so the first job gives
    // up its automatic catch-up and waits for an explicit retry.
    final first = await service.enqueue(fixture.request(normalMaximum: 32));
    await first.events
        .firstWhere(
          (event) =>
              event.errorClass == attachmentConfirmationReconciliationRequired,
        )
        .timeout(const Duration(seconds: 2));

    // That parked job owns no request, so it must not hold the room hostage.
    final secondSource = await _createDistinctAttachmentSource(fixture);
    final second = await service.enqueue(
      fixture.request(normalMaximum: 32, source: secondSource.source),
    );
    await second.events
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));

    expect(finalized, 2);
  });

  test('a restart drains a room parked behind a stored confirmation', () async {
    final fixture = await _Fixture.create(fileBacked: true);
    addTearDown(fixture.close);
    var finalized = 0;
    http.Client roomClient() => MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
        return http.Response.bytes(_probeSuccess(), 200);
      }
      if (request.method == 'PUT') {
        return http.Response('', 201);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/attachment')) {
        finalized++;
        return http.Response.bytes(
          _finalizeSuccess(fileName: 'source-$finalized.png'),
          200,
        );
      }
      fail('Unexpected request: ${request.method} ${request.url}');
    });

    // Leave the room exactly as a stalled device stores it: an older job that
    // parked on its confirmation, and a newer one that never finalized.
    final identifiers = _SequentialIdentifierFactory();
    var holdFinalization = false;
    final initialService = fixture.service(
      roomClient(),
      identifierFactory: identifiers,
      confirmationRetryDelays: const <Duration>[],
      beforeStepPlan: ({required jobId, required phase}) async {
        if (holdFinalization && phase == AttachmentJobPhase.uploaded) {
          // Hold the second job at uploaded so the restart has to drain it.
          throw const AttachmentTransportException(
            AttachmentTransportError.cancelled,
            step: AttachmentRequestStep.finalize,
            stage: AttachmentTransportStage.connect,
          );
        }
      },
      catchUpConfirmation:
          ({
            required accountId,
            required roomToken,
            required threadId,
          }) async {},
    );
    final first = await initialService.enqueue(
      fixture.request(normalMaximum: 32),
    );
    await first.events
        .firstWhere(
          (event) =>
              event.errorClass == attachmentConfirmationReconciliationRequired,
        )
        .timeout(const Duration(seconds: 2));
    holdFinalization = true;
    final secondSource = await _createDistinctAttachmentSource(fixture);
    final second = await initialService.enqueue(
      fixture.request(normalMaximum: 32, source: secondSource.source),
    );
    await second.events
        .firstWhere((event) => event.phase == AttachmentJobPhase.uploaded)
        .timeout(const Duration(seconds: 2));
    expect(finalized, 1);
    await initialService.close();
    await fixture.reopenDatabase();

    // Restarting the app must move the stored backlog without any user action.
    final resumedService = fixture.service(
      roomClient(),
      identifierFactory: identifiers,
      confirmationRetryDelays: const <Duration>[],
      catchUpConfirmation:
          ({
            required accountId,
            required roomToken,
            required threadId,
          }) async {},
    );
    addTearDown(resumedService.close);
    await resumedService
        .watchJob(accountId: second.accountId, jobId: second.jobId)
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 5));

    expect(finalized, 2);
  });
}

final class _RecordingRetryTimer implements Timer {
  _RecordingRetryTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() {
    _active = false;
  }
}

final class _SequencedCredentialVault implements CredentialVault {
  _SequencedCredentialVault({this.denials = 1});

  final int denials;
  int readCount = 0;

  @override
  Future<String?> readAppPassword(String accountId) async {
    readCount++;
    if (readCount >= 2 && readCount <= denials + 1) {
      throw const CredentialVaultTemporarilyUnavailable();
    }
    return 'fixture-app-password-never-use';
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {}

  @override
  Future<void> deleteAppPassword(String accountId) async {}
}

final class _BlockingSecondCredentialVault implements CredentialVault {
  final secondReadStarted = Completer<void>();
  final releaseSecondRead = Completer<String?>();
  int _readCount = 0;

  @override
  Future<String?> readAppPassword(String accountId) async {
    _readCount++;
    if (_readCount == 2) {
      secondReadStarted.complete();
      return releaseSecondRead.future;
    }
    return 'fixture-app-password-never-use';
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {}

  @override
  Future<void> deleteAppPassword(String accountId) async {}
}

Future<({File file, PreparedAttachmentSource source})>
_createDistinctAttachmentSource(
  _Fixture fixture, {
  String name = 'source-second.bin',
}) async {
  final file = File('${fixture.directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(fixture.bytes, flush: true);
  final template = fixture.request(normalMaximum: 32).source;
  return (
    file: file,
    source: PreparedAttachmentSource(
      handle: AttachmentSourceHandle.parse(file.uri.toString()),
      ownership: AttachmentSourceOwnership.appOwnedCopy,
      byteLength: fixture.bytes.length,
      sha256: template.sha256,
      mimeType: 'image/png',
      displayName: 'source.png',
    ),
  );
}
