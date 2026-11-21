part of 'attachment_service_test.dart';

void _registerAttachmentServiceRetryResumeTests() {
  test('a network hint resumes different rooms concurrently', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final probeCounts = <String, int>{};
    final resumedRooms = <String>{};
    final bothResumed = Completer<void>();
    final allowResumedProbes = Completer<void>();
    addTearDown(() {
      if (!allowResumedProbes.isCompleted) {
        allowResumedProbes.complete();
      }
    });
    final service = fixture.service(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
          final segments = request.url.pathSegments;
          final roomToken = segments[segments.length - 3];
          final probeCount = probeCounts.update(
            roomToken,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          if (probeCount <= 2) {
            throw const SocketException('offline');
          }
          resumedRooms.add(roomToken);
          if (resumedRooms.length == 2 && !bothResumed.isCompleted) {
            bothResumed.complete();
          }
          await allowResumedProbes.future;
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
      identifierFactory: _SequentialIdentifierFactory(),
      retryDelays: const [Duration.zero],
    );
    addTearDown(service.close);

    final first = await service.enqueue(
      fixture.request(normalMaximum: 32, roomToken: 'rooma123'),
    );
    final second = await service.enqueue(
      fixture.request(normalMaximum: 32, roomToken: 'roomb123'),
    );
    try {
      await Future.wait([
        first.events.firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.automaticRetryCount == 2,
        ),
        second.events.firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.automaticRetryCount == 2,
        ),
      ]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      final firstStored = await fixture.repository.getStoredJob(
        accountId: 'account-a',
        jobId: first.jobId.value,
      );
      final secondStored = await fixture.repository.getStoredJob(
        accountId: 'account-a',
        jobId: second.jobId.value,
      );
      fail(
        'Retry exhaustion timed out: first=${firstStored?.phase}/'
        '${firstStored?.automaticRetryCount}, second=${secondStored?.phase}/'
        '${secondStored?.automaticRetryCount}, probes=$probeCounts',
      );
    }

    final resuming = service.resumeRetries();
    await bothResumed.future.timeout(const Duration(seconds: 2));
    expect(resumedRooms, <String>{'rooma123', 'roomb123'});
    allowResumedProbes.complete();
    await resuming;
    await Future.wait([
      first.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      ),
      second.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
      ),
    ]);
    expect(probeCounts, <String, int>{'rooma123': 3, 'roomb123': 3});
  });
}
