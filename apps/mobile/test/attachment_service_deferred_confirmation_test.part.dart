part of 'attachment_service_test.dart';

void _registerDeferredConfirmationTests() {
  for (final wakeDuringRead in [false, true]) {
    test(
      'deferred attachment confirmation resumes ${wakeDuringRead ? 'during' : 'after'} its read without consuming retries',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final deferredStarted = Completer<void>();
        final releaseDeferred = Completer<void>();
        var reads = 0, finalizations = 0;
        final service = fixture.service(
          MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path.endsWith('/folder')) {
              return http.Response.bytes(_probeSuccess(), 200);
            }
            if (request.method == 'PUT') return http.Response('', 201);
            if (request.method == 'POST' &&
                request.url.path.endsWith('/attachment')) {
              finalizations++;
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
                reads++;
                if (reads == 1) {
                  deferredStarted.complete();
                  await releaseDeferred.future;
                  return ChatSynchronizationResult.deferred;
                }
                await fixture.cacheConfirmation(messageId: 110);
                return ChatSynchronizationResult.converged;
              },
        );
        addTearDown(() async {
          if (!releaseDeferred.isCompleted) releaseDeferred.complete();
          await service.close();
        });
        final session = await service.enqueue(
          fixture.request(normalMaximum: 32),
        );
        await deferredStarted.future.timeout(const Duration(seconds: 2));
        final completed = session.events.firstWhere(
          (event) => event.phase == AttachmentJobPhase.completed,
        );
        if (wakeDuringRead) {
          await service.resumeDeferredConfirmations(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
          releaseDeferred.complete();
        } else {
          releaseDeferred.complete();
          await pumpEventQueue(times: 20);
          final stored = await fixture.repository.getStoredJob(
            accountId: 'account-a',
            jobId: session.jobId.value,
          );
          expect(
            stored?.errorClass,
            isNot(attachmentConfirmationReconciliationRequired),
          );
          expect(stored?.automaticRetryCount, 0);
          expect(reads, 1);
          await service.resumeDeferredConfirmations(
            accountId: 'account-a',
            roomToken: 'roomb999',
          );
          expect(reads, 1);
          await service.resumeDeferredConfirmations(
            accountId: 'account-a',
            roomToken: 'rooma123',
          );
        }
        await completed.timeout(const Duration(seconds: 2));
        expect(reads, 2);
        expect(finalizations, 1);
        await _expectFileRemoved(fixture.sourceFile);
      },
    );
  }
}
