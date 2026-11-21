part of 'attachment_service_test.dart';

void _registerAttachmentServiceParallelTests() {
  test('close releases verified sources with bounded concurrency', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final closeGate = Completer<void>();
    final sourceProvider = _GatedCloseSourceProvider(closeGate.future);
    final threeUploadsStarted = Completer<void>();
    var uploadsStarted = 0;
    final service = fixture.service(
      MockClient.streaming((request, body) async {
        await body.drain<void>();
        if (request.url.path.endsWith('/folder')) {
          return http.StreamedResponse(Stream.value(_probeSuccess()), 200);
        }
        if (request.method == 'PUT') {
          uploadsStarted++;
          if (uploadsStarted == 3) threeUploadsStarted.complete();
          await (request as http.Abortable).abortTrigger!;
          throw http.RequestAbortedException(request.url);
        }
        fail('Unexpected request: ${request.method}');
      }),
      sourceProvider: sourceProvider,
      identifierFactory: const UuidAttachmentIdentifierFactory(),
    );
    Future<void>? closing;
    addTearDown(() async {
      if (!closeGate.isCompleted) closeGate.complete();
      await (closing ??= service.close());
    });

    for (var index = 0; index < 6; index++) {
      final source = await _createDistinctAttachmentSource(
        fixture,
        name: 'pending-$index.png',
      );
      await service.enqueue(
        fixture.request(normalMaximum: 32, source: source.source),
      );
    }
    await threeUploadsStarted.future.timeout(const Duration(seconds: 2));
    expect(sourceProvider.closeStarts, 0);

    sourceProvider.gateCloses = true;
    closing = service.close();
    for (var turn = 0; turn < 50 && sourceProvider.closeStarts < 4; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(sourceProvider.closeStarts, 4);
    expect(sourceProvider.closeFinishes, 0);

    closeGate.complete();
    await closing;
    expect(sourceProvider.closeStarts, 6);
    expect(sourceProvider.closeFinishes, 6);
  });

  test('a running retry does not arm another immediate retry timer', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    var now = DateTime.utc(2026, 10, 2);
    var probes = 0;
    final timers = <_RecordingRetryTimer>[];
    final retryStarted = Completer<void>();
    final releaseRetry = Completer<void>();
    final service = fixture.service(
      MockClient((request) async {
        if (request.url.path.endsWith('/folder')) {
          if (++probes == 1) return http.Response('', 503);
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') return http.Response('', 201);
        if (request.url.path.endsWith('/attachment')) {
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method}');
      }),
      identifierFactory: const UuidAttachmentIdentifierFactory(),
      clock: () => now,
      retryDelays: const [Duration(minutes: 1)],
      createRetryTimer: (delay, callback) {
        final timer = _RecordingRetryTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
      beforeStepPlan: ({required jobId, required phase}) async {
        if (phase == AttachmentJobPhase.retryable) {
          retryStarted.complete();
          await releaseRetry.future;
        }
      },
    );
    addTearDown(service.close);
    addTearDown(() {
      if (!releaseRetry.isCompleted) releaseRetry.complete();
    });
    final session = await service.enqueue(fixture.request(normalMaximum: 32));
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.retryable,
    );
    await pumpEventQueue();
    expect(timers, hasLength(1));
    now = now.add(const Duration(minutes: 1));
    timers.single.callback();
    await retryStarted.future.timeout(const Duration(seconds: 2));
    await pumpEventQueue();
    expect(timers, hasLength(1));
    releaseRetry.complete();
    await session.events
        .firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        )
        .timeout(const Duration(seconds: 2));
    expect(probes, 2);
  });

  test('cancelling one upload does not wait for its active siblings', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final threeStarted = Completer<void>();
    final releaseSiblings = Completer<void>();
    var started = 0;
    var aborted = 0;
    var finalized = 0;
    final service = fixture.service(
      MockClient.streaming((request, body) async {
        await body.drain<void>();
        if (request.url.path.endsWith('/folder')) {
          return http.StreamedResponse(Stream.value(_probeSuccess()), 200);
        }
        if (request.method == 'PUT') {
          started++;
          if (started == 3) threeStarted.complete();
          final wasCancelled = await Future.any([
            (request as http.Abortable).abortTrigger!.then((_) => true),
            releaseSiblings.future.then((_) => false),
          ]);
          if (wasCancelled) {
            aborted++;
            throw http.RequestAbortedException(request.url);
          }
          return http.StreamedResponse(const Stream.empty(), 201);
        }
        if (request.url.path.endsWith('/attachment')) {
          finalized++;
          return http.StreamedResponse(Stream.value(_finalizeSuccess()), 200);
        }
        fail('Unexpected request: ${request.method}');
      }),
      identifierFactory: const UuidAttachmentIdentifierFactory(),
      catchUpConfirmation:
          ({required accountId, required roomToken, required threadId}) async =>
              ChatSynchronizationResult.converged,
    );
    addTearDown(service.close);
    addTearDown(() {
      if (!releaseSiblings.isCompleted) releaseSiblings.complete();
    });
    final sessions = <DurableAttachmentSession>[];
    for (var index = 0; index < 3; index++) {
      final source = await _createDistinctAttachmentSource(
        fixture,
        name: 'photo-$index.png',
      );
      sessions.add(
        await service.enqueue(
          fixture.request(normalMaximum: 32, source: source.source),
        ),
      );
    }
    await threeStarted.future.timeout(const Duration(seconds: 3));
    await sessions.first.cancel().timeout(const Duration(seconds: 2));
    expect(aborted, 1);
    expect(finalized, 0);
    final runtime = await fixture.repository.loadRuntime();
    final jobs = runtime.snapshot.accounts.values.single.jobs;
    expect(jobs[sessions.first.jobId]!.phase, AttachmentJobPhase.cancelled);
    expect(jobs[sessions[1].jobId]!.phase, AttachmentJobPhase.uploading);
    expect(jobs[sessions[2].jobId]!.phase, AttachmentJobPhase.uploading);
    releaseSiblings.complete();
    await Future.wait(
      sessions
          .skip(1)
          .map(
            (session) => session.events.firstWhere(
              (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
            ),
          ),
    ).timeout(const Duration(seconds: 3));
    expect(finalized, 2);
  });

  test(
    'ten same-name photos upload three at a time and finalize in order',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final uploads = <String, Completer<void>>{};
      final finalized = <String>[];
      var active = 0;
      var peak = 0;
      var releaseUploads = false;
      final threeStarted = Completer<void>();
      final fourthStarted = Completer<void>();
      final service = fixture.service(
        MockClient((request) async {
          if (request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            final release = Completer<void>();
            expect(uploads.containsKey(request.url.path), isFalse);
            uploads[request.url.path] = release;
            active++;
            if (active > peak) peak = active;
            if (uploads.length == 3) threeStarted.complete();
            if (uploads.length == 4) fourthStarted.complete();
            if (!releaseUploads) await release.future;
            active--;
            return http.Response('', 201);
          }
          if (request.url.path.endsWith('/attachment')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            finalized.add(body['referenceId'] as String);
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method}');
        }),
        identifierFactory: const UuidAttachmentIdentifierFactory(),
        catchUpConfirmation:
            ({
              required accountId,
              required roomToken,
              required threadId,
            }) async => ChatSynchronizationResult.converged,
      );
      addTearDown(service.close);
      addTearDown(() {
        releaseUploads = true;
        for (final release in uploads.values) {
          if (!release.isCompleted) release.complete();
        }
      });
      final sessions = <DurableAttachmentSession>[];
      for (var index = 0; index < 10; index++) {
        final source = await _createDistinctAttachmentSource(
          fixture,
          name: 'photo-$index.png',
        );
        sessions.add(
          await service.enqueue(
            fixture.request(normalMaximum: 32, source: source.source),
          ),
        );
      }
      await threeStarted.future.timeout(const Duration(seconds: 3));
      expect(uploads, hasLength(3));
      expect(finalized, isEmpty);

      // A later upload frees its slot without overtaking the first message.
      uploads.values.elementAt(1).complete();
      await fourthStarted.future.timeout(const Duration(seconds: 3));
      expect(finalized, isEmpty);
      releaseUploads = true;
      for (final release in uploads.values) {
        if (!release.isCompleted) release.complete();
      }
      await Future.wait(
        sessions.map(
          (session) => session.events.firstWhere(
            (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
          ),
        ),
      ).timeout(const Duration(seconds: 5));
      final restored = await fixture.repository.loadRuntime();
      final jobs = restored.snapshot.accounts.values.single.jobs.values.toList()
        ..sort(
          (a, b) => a.draft.enqueueSequence.compareTo(b.draft.enqueueSequence),
        );
      expect(uploads, hasLength(10));
      expect(peak, 3);
      expect(finalized, jobs.map((job) => job.draft.referenceId.value));
    },
  );

  test('an album finalizes in send order without waiting for the chat poll to '
      'confirm each picture', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final finalized = <String>[];
    final neverConfirmed = Completer<ChatSynchronizationResult>();
    final service = fixture.service(
      MockClient((request) async {
        if (request.url.path.endsWith('/folder')) {
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') {
          return http.Response('', 201);
        }
        if (request.url.path.endsWith('/attachment')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          finalized.add(body['referenceId'] as String);
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method}');
      }),
      identifierFactory: const UuidAttachmentIdentifierFactory(),
      catchUpConfirmation:
          ({required accountId, required roomToken, required threadId}) =>
              neverConfirmed.future,
    );
    addTearDown(service.close);
    addTearDown(
      () => neverConfirmed.complete(ChatSynchronizationResult.converged),
    );

    final sessions = <DurableAttachmentSession>[];
    for (var index = 0; index < 4; index++) {
      final source = await _createDistinctAttachmentSource(
        fixture,
        name: 'album-$index.png',
      );
      sessions.add(
        await service.enqueue(
          fixture.request(normalMaximum: 32, source: source.source),
        ),
      );
    }
    await Future.wait(
      sessions.map(
        (session) => session.events.firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        ),
      ),
    ).timeout(const Duration(seconds: 5));

    final restored = await fixture.repository.loadRuntime();
    final jobs = restored.snapshot.accounts.values.single.jobs.values.toList()
      ..sort(
        (a, b) => a.draft.enqueueSequence.compareTo(b.draft.enqueueSequence),
      );
    expect(finalized, jobs.map((job) => job.draft.referenceId.value));
  });
}

final class _GatedCloseSourceProvider implements AttachmentSourceProvider {
  _GatedCloseSourceProvider(this.closeGate);

  final Future<void> closeGate;
  bool gateCloses = false;
  int closeStarts = 0;
  int closeFinishes = 0;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (cancellationSignal?.isCancelled ?? false) {
      throw StateError('Synthetic source open cancelled');
    }
    return _GatedCloseSourceLease(
      file: File.fromUri(Uri.parse(handle.value)),
      owner: this,
    );
  }
}

final class _GatedCloseSourceLease implements AttachmentSourceLease {
  const _GatedCloseSourceLease({required this.file, required this.owner});

  final File file;
  final _GatedCloseSourceProvider owner;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) =>
      file.openRead(offset, length == null ? null : offset + length);

  @override
  Future<void> close() async {
    owner.closeStarts++;
    if (owner.gateCloses) await owner.closeGate;
    owner.closeFinishes++;
  }
}
