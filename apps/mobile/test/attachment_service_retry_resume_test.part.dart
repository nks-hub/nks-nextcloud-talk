part of 'attachment_service_test.dart';

void _registerAttachmentServiceRetryResumeTests() {
  for (final reopenDuringUpload in [false, true]) {
    test(
      'a second attachment service cannot replace a live PUT '
      '(${reopenDuringUpload ? 'start while claimed' : 'start before claim'})',
      () async {
        final fixture = await _Fixture.create(fileBacked: true);
        addTearDown(fixture.close);
        final jobId = await fixture.seedInFlight(
          AttachmentRequestStep.normalPut,
        );
        final accountId = AccountId.parse('account-a');
        final key = (accountId: accountId.value, jobId: jobId.value);
        final loaded = await fixture.repository.loadRuntime();
        final recovered = recoverAttachmentAfterRestart(
          loaded.snapshot,
          accountId: accountId,
          jobId: jobId,
        );
        final account = recovered.plan!
            .commit(loaded.snapshot)
            .accounts[accountId]!;
        await fixture.repository.persistTransition(
          account: account,
          job: account.jobs[jobId]!,
          metadata: loaded.metadata[key]!.copyWith(automaticRetryCount: 1),
          updatedAt: DateTime.utc(2026, 8, 24),
        );

        final peerDatabase = AppDatabase.forTesting(
          NativeDatabase(fixture.databaseFile!),
        );
        addTearDown(peerDatabase.close);
        final peerRepository = AttachmentRepository(peerDatabase);
        final primaryStarted = Completer<void>();
        final releasePrimary = Completer<void>();
        final primarySettling = Completer<void>();
        final releaseSettling = Completer<void>();
        final execution = AttachmentRuntimeQueue();
        final primaryOwner = AttachmentRuntimeOwner(execution.reserve());
        final primary = await primaryOwner.open(
          () => fixture.service(
            MockClient((request) async {
              if (request.method == 'PUT') {
                primaryStarted.complete();
                await releasePrimary.future;
                return http.Response('', 201);
              }
              if (request.url.path.endsWith('/attachment')) {
                return http.Response.bytes(_finalizeSuccess(), 200);
              }
              fail('Unexpected request: ${request.method}');
            }),
            identifierFactory: const UuidAttachmentIdentifierFactory(),
            retryDelays: const [],
            beforeRoomIdle: () async {
              if (!primaryStarted.isCompleted) return;
              if (!primarySettling.isCompleted) primarySettling.complete();
              await releaseSettling.future;
            },
          ),
        );
        final peerRequests = <String>[];
        var peerOpened = false;
        AttachmentRuntimeOwner? peerOwner;
        Future<AttachmentService> openPeer() {
          peerOwner = AttachmentRuntimeOwner(execution.reserve());
          return peerOwner!.open(() {
            peerOpened = true;
            return AttachmentService(
              repository: peerRepository,
              credentials: fixture.credentials,
              releaseSource: (_) async {},
              transport: HttpAttachmentTransport(
                client: MockClient((request) async {
                  peerRequests.add(request.method);
                  throw const SocketException('second transport was reached');
                }),
                sourceProvider: _FileSourceProvider(),
              ),
              retryDelays: const [],
            );
          });
        }

        addTearDown(() async {
          if (!releasePrimary.isCompleted) releasePrimary.complete();
          if (!releaseSettling.isCompleted) releaseSettling.complete();
          await primaryOwner.close();
          await peerOwner?.close();
        });
        await primary.ready;
        final earlyPeer = reopenDuringUpload ? null : openPeer();

        final primaryRun = primary.resumeRetries();
        await primaryStarted.future;
        Future<AttachmentJob> persistedJob() async =>
            (await fixture.repository.loadRuntime())
                .snapshot
                .accounts[accountId]!
                .jobs[jobId]!;
        final requestId =
            (await persistedJob()).inFlightRequest!.context.requestId;

        final nextOwner = earlyPeer ?? openPeer();
        await pumpEventQueue();
        expect(peerOpened, isFalse);

        final after = (await persistedJob()).inFlightRequest;
        expect(
          (peerRequests.length, after?.context.requestId),
          (0, requestId),
          reason: 'Second service sent $peerRequests',
        );
        releasePrimary.complete();
        await primarySettling.future;
        final closing = primaryOwner.close();
        await pumpEventQueue();
        expect(peerOpened, isFalse);
        releaseSettling.complete();
        await primaryRun;
        await closing;
        final peer = await nextOwner;
        await peer.resumeRetries();
        expect(peerRequests, isEmpty);
        expect(
          (await persistedJob()).phase,
          AttachmentJobPhase.awaitingConfirmation,
        );
      },
    );
  }

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
          final roomToken = _attachmentProbeRoom(request.url);
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

  test('a network hint resumes at most four probes across accounts', () async {
    final fixture = await _Fixture.create(
      accountIds: const ['account-a', 'account-b'],
    );
    addTearDown(fixture.close);
    final releaseProbes = Completer<void>();
    final firstFour = Completer<void>();
    final fifth = Completer<void>();
    final probeGates = <String, Completer<void>>{};
    var connected = false;
    var inFlight = 0;
    var peakInFlight = 0;
    final service = fixture.service(
      MockClient((request) async {
        if (request.url.path.endsWith('/folder')) {
          if (!connected) throw const SocketException('offline');
          final room = _attachmentProbeRoom(request.url);
          final gate = probeGates[room] = Completer<void>();
          inFlight++;
          peakInFlight = max(peakInFlight, inFlight);
          if (probeGates.length == 4) firstFour.complete();
          if (probeGates.length == 5) fifth.complete();
          await Future.any([gate.future, releaseProbes.future]);
          inFlight--;
          return http.Response.bytes(_probeSuccess(), 200);
        }
        if (request.method == 'PUT') return http.Response('', 201);
        if (request.url.path.endsWith('/attachment')) {
          return http.Response.bytes(_finalizeSuccess(), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
      identifierFactory: const UuidAttachmentIdentifierFactory(),
      retryDelays: const [Duration.zero],
    );
    addTearDown(() async {
      if (!releaseProbes.isCompleted) releaseProbes.complete();
      await service.close();
    });

    final sessions = await Future.wait([
      for (var index = 0; index < 6; index++)
        service.enqueue(
          fixture.request(
            normalMaximum: 32,
            accountId: index.isEven ? 'account-a' : 'account-b',
            roomToken: 'room000$index',
          ),
        ),
    ]);
    await Future.wait(
      sessions.map(
        (session) => session.events.firstWhere(
          (event) =>
              event.phase == AttachmentJobPhase.retryable &&
              event.automaticRetryCount == 2,
        ),
      ),
    ).timeout(const Duration(seconds: 5));

    connected = true;
    final resumed = service.resumeRetries();
    await firstFour.future.timeout(const Duration(seconds: 2));
    await pumpEventQueue();
    expect(probeGates, hasLength(4));
    expect(inFlight, 4);

    probeGates.values.first.complete();
    await fifth.future.timeout(const Duration(seconds: 2));
    expect(inFlight, 4);

    releaseProbes.complete();
    await resumed.timeout(const Duration(seconds: 5));
    await Future.wait(
      sessions.map(
        (session) => session.events.firstWhere(
          (event) => event.phase == AttachmentJobPhase.awaitingConfirmation,
        ),
      ),
    ).timeout(const Duration(seconds: 5));
    expect(probeGates, hasLength(6));
    expect(peakInFlight, 4);
  });
}

String _attachmentProbeRoom(Uri uri) =>
    uri.pathSegments[uri.pathSegments.length - 3];
