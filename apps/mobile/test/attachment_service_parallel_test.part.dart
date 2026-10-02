part of 'attachment_service_test.dart';

void _registerAttachmentServiceParallelTests() {
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
}
