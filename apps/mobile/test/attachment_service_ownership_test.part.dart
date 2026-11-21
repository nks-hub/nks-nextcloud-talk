part of 'attachment_service_test.dart';

void _registerAttachmentOwnershipTests() {
  test(
    'account suspension follows the replacement after provider invalidation',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final accountId = AccountId.parse('account-a');
      await fixture.seedInFlight(AttachmentRequestStep.finalize);
      final queue = AttachmentRuntimeQueue();
      final priorOwner = AttachmentRuntimeOwner(queue.reserve());
      final prior = await priorOwner.open(
        () => fixture.service(_unexpectedClient()),
      );
      await prior.ready;
      AttachmentRuntimeOwner? nextOwner;
      var generation = 0;
      final container = ProviderContainer(
        overrides: [
          attachmentServiceProvider.overrideWith((_) async {
            if (generation++ == 0) return prior;
            final owner = nextOwner = AttachmentRuntimeOwner(queue.reserve());
            return owner.open(() => fixture.service(_unexpectedClient()));
          }),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await priorOwner.close();
        await nextOwner?.close();
      });
      final oldFuture = container.read(attachmentServiceProvider.future);
      expect(await oldFuture, same(prior));
      final reads = <Future<AttachmentService>>[];
      final suspending = suspendAttachmentRuntime(accountId, () {
        final read = container.read(attachmentServiceProvider.future);
        reads.add(read);
        return read;
      });
      final closing = priorOwner.close();
      container.invalidate(attachmentServiceProvider);

      await closing;
      await suspending;

      expect(reads, hasLength(2));
      expect(await reads.first, same(prior));
      expect(reads.last, isNot(same(reads.first)));
      final runtime = await fixture.repository.loadRuntime();
      expect(
        runtime.snapshot.accounts[accountId]!.lane,
        AttachmentAccountLane.suspended,
      );
    },
  );

  test(
    'close preserves an account suspension already writing to disk',
    () async {
      final fixture = await _Fixture.create(fileBacked: true);
      addTearDown(fixture.close);
      final accountId = AccountId.parse('account-a');
      await fixture.seedInFlight(AttachmentRequestStep.finalize);
      final gate = _HeldAttachmentInsert(
        'attachment_runtime_accounts',
        marker: 'suspended',
      );
      final database = AppDatabase.forTesting(
        NativeDatabase(fixture.databaseFile!).interceptWith(gate),
      );
      addTearDown(database.close);
      final service = fixture.service(
        _unexpectedClient(),
        attachmentRepository: AttachmentRepository(database),
      );
      addTearDown(() async {
        if (!gate.allow.isCompleted) gate.allow.complete();
        await service.close();
      });

      final suspension = service.suspendAccount(accountId);
      await gate.started.future;
      final closing = service.close();

      expect(service.suspendAccount(accountId), same(suspension));
      gate.allow.complete();
      await suspension;
      await closing;
      final runtime = await fixture.repository.loadRuntime();
      expect(
        runtime.snapshot.accounts[accountId]!.lane,
        AttachmentAccountLane.suspended,
      );
    },
  );

  test(
    'headless drain reports completion after attachment close settles',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final closing = Completer<void>();
      final allowClose = Completer<void>();
      final events = StreamController<AttachmentConfirmationSnapshot>(
        onCancel: () {
          closing.complete();
          return allowClose.future;
        },
      );
      final attachments = fixture.service(
        _unexpectedClient(),
        watchConfirmationCandidates: () => events.stream,
      );
      final api = HttpNextcloudApi(client: _unexpectedClient());
      addTearDown(api.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(fixture.database),
          credentialVaultProvider.overrideWithValue(fixture.credentials),
          attachmentServiceProvider.overrideWith((_) async => attachments),
          nextcloudApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() async {
        if (!allowClose.isCompleted) allowClose.complete();
        await attachments.close();
        await events.close();
      });
      const channel = MethodChannel('test/attachment_runtime/background');
      final messages = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        messages.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final drain = runBackgroundDrainIsolate(
        drain: () => drainForBackground(container),
        channel: channel,
      );
      await closing.future;
      expect(messages, isEmpty);

      allowClose.complete();
      await drain;
      expect(messages.single.method, 'finished');
      expect(messages.single.arguments, {'retry': false});
    },
  );

  test(
    'headless drain finishes a recovered PUT before reporting completion',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final fixture = await _Fixture.create(fileBacked: true);
      addTearDown(fixture.close);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.normalPut);

      final putStarted = Completer<void>();
      final allowPut = Completer<void>();
      var finalized = 0;
      final attachments = fixture.service(
        MockClient((request) async {
          if (request.method == 'PUT') {
            expect(request.bodyBytes, fixture.bytes);
            putStarted.complete();
            await allowPut.future;
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            finalized++;
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        retryDelays: const [Duration.zero],
      );
      final api = HttpNextcloudApi(client: _unexpectedClient());
      addTearDown(api.close);
      final wakeRead = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(fixture.database),
          credentialVaultProvider.overrideWithValue(fixture.credentials),
          attachmentServiceProvider.overrideWith((_) async {
            wakeRead.complete();
            return attachments;
          }),
          nextcloudApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() async {
        if (!allowPut.isCompleted) allowPut.complete();
        await attachments.close();
      });
      const channel = MethodChannel('test/attachment_runtime/held_put');
      final messages = <MethodCall>[];
      (int, String?)? outcomeAtCompletion;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        messages.add(call);
        final stored = await fixture.repository.getStoredJob(
          accountId: 'account-a',
          jobId: jobId.value,
        );
        outcomeAtCompletion = (finalized, stored?.phase);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await putStarted.future.timeout(const Duration(seconds: 5));
      final drain = runBackgroundDrainIsolate(
        drain: () => drainForBackground(container),
        channel: channel,
      );
      await wakeRead.future.timeout(const Duration(seconds: 5));
      await pumpEventQueue();
      final completedWhilePutHeld = messages.isNotEmpty;
      allowPut.complete();
      await drain.timeout(const Duration(seconds: 5));

      expect(messages.single.method, 'finished');
      expect(messages.single.arguments, {'retry': false});
      expect(
        (completedWhilePutHeld, outcomeAtCompletion),
        (false, (1, AttachmentJobPhase.awaitingConfirmation.name)),
      );
    },
  );

  test(
    'headless drain waits for rooms scheduled at the end of startup',
    () async {
      final fixture = await _Fixture.create(fileBacked: true);
      addTearDown(fixture.close);
      await fixture.seedTerminal(messageId: 101, seed: 1);
      final jobId = await fixture.seedInFlight(AttachmentRequestStep.normalPut);
      final accountId = AccountId.parse('account-a');
      final runtime = await fixture.repository.loadRuntime();
      final account = runtime.snapshot.accounts[accountId]!;
      final key = (accountId: accountId.value, jobId: jobId.value);
      await fixture.repository.persistTransition(
        account: account,
        job: account.jobs[jobId]!.copyWith(
          phase: AttachmentJobPhase.draftResolved,
          inFlightRequest: null,
        ),
        metadata: runtime.metadata[key]!,
        updatedAt: DateTime.utc(2026, 8, 24),
      );

      final releaseStarted = Completer<void>();
      final allowRelease = Completer<void>();
      final putStarted = Completer<void>();
      final allowPut = Completer<void>();
      var finalizations = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'PUT') {
            expect(request.bodyBytes, fixture.bytes);
            putStarted.complete();
            await allowPut.future;
            return http.Response('', 201);
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/attachment')) {
            finalizations++;
            return http.Response.bytes(_finalizeSuccess(), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        releaseSource: (_) async {
          releaseStarted.complete();
          await allowRelease.future;
        },
        retryDelays: const [],
      );
      addTearDown(() async {
        if (!allowRelease.isCompleted) allowRelease.complete();
        if (!allowPut.isCompleted) allowPut.complete();
        await service.close();
      });

      const waitLimit = Duration(seconds: 5);
      await releaseStarted.future.timeout(waitLimit);
      var finishedWhilePutHeld = false;
      final finished = service
          .drainForBackground()
          .whenComplete(service.close)
          .then((_) {
            finishedWhilePutHeld = !allowPut.isCompleted;
          });
      await pumpEventQueue();
      allowRelease.complete();
      await Future.any<void>([putStarted.future, finished]).timeout(waitLimit);
      allowPut.complete();
      await finished.timeout(waitLimit);

      final stored = await fixture.repository.getStoredJob(
        accountId: key.accountId,
        jobId: key.jobId,
      );
      expect(
        (finishedWhilePutHeld, finalizations, stored?.phase),
        (false, 1, AttachmentJobPhase.awaitingConfirmation.name),
      );
    },
  );

  test('a replacement waits for the prior admission to commit', () async {
    final fixture = await _Fixture.create(fileBacked: true);
    addTearDown(fixture.close);
    final gate = _HeldAttachmentInsert('attachment_jobs');
    final database = AppDatabase.forTesting(
      NativeDatabase(fixture.databaseFile!).interceptWith(gate),
    );
    addTearDown(database.close);
    final queue = AttachmentRuntimeQueue();
    final priorOwner = AttachmentRuntimeOwner(queue.reserve());
    final prior = await priorOwner.open(
      () => fixture.service(
        _unexpectedClient(),
        attachmentRepository: AttachmentRepository(database),
      ),
    );
    final nextOwner = AttachmentRuntimeOwner(queue.reserve());
    addTearDown(() async {
      if (!gate.allow.isCompleted) gate.allow.complete();
      await priorOwner.close();
      await nextOwner.close();
    });

    final admission = prior.enqueue(fixture.request(normalMaximum: 32));
    await gate.started.future;
    final closing = prior.close();
    expect(prior.close(), same(closing));
    final releasing = priorOwner.close();
    var replacementStarted = false;
    final replacement = nextOwner.open(() {
      replacementStarted = true;
      return fixture.service(
        MockClient((_) async => throw const SocketException('offline')),
        retryDelays: const [],
      );
    });
    await pumpEventQueue();
    expect(replacementStarted, isFalse);

    gate.allow.complete();
    final admitted = await admission;
    await releasing;
    final next = await replacement;
    await next.ready;
    final stored = await fixture.repository.getStoredJob(
      accountId: admitted.accountId.value,
      jobId: admitted.jobId.value,
    );
    expect(stored, isNotNull);
  });
}

final class _HeldAttachmentInsert extends QueryInterceptor {
  _HeldAttachmentInsert(this.table, {this.marker});

  final String table;
  final String? marker;
  final started = Completer<void>();
  final allow = Completer<void>();

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.toLowerCase().startsWith('insert into "$table"') &&
        (marker == null || args.contains(marker))) {
      if (!started.isCompleted) started.complete();
      await allow.future;
    }
    return super.runInsert(executor, statement, args);
  }
}
