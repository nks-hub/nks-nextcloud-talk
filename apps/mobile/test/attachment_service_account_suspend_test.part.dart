part of 'attachment_service_test.dart';

void _registerAttachmentServiceAccountSuspendTests() {
  for (final emitFirstChunk in <bool>[false, true]) {
    test(
      'suspension during upload ${emitFirstChunk ? 'after' : 'before'} body dispatch is restart safe',
      () => _verifyAccountSuspendDuringUpload(emitFirstChunk: emitFirstChunk),
    );
  }

  test(
    'transport failure cannot commit after suspension wins the gate',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final failureCommitReached = Completer<void>();
      final releaseFailureCommit = Completer<void>();
      var putRequests = 0;
      final service = fixture.service(
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/folder')) {
            return http.Response.bytes(_probeSuccess(), 200);
          }
          if (request.method == 'PUT') {
            putRequests++;
            throw http.ClientException('Synthetic upload transport failure');
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
        beforeTransportFailureCommit: () async {
          failureCommitReached.complete();
          await releaseFailureCommit.future;
        },
      );
      addTearDown(service.close);

      final session = await service.enqueue(fixture.request(normalMaximum: 32));
      await failureCommitReached.future.timeout(const Duration(seconds: 2));
      final suspension = service.suspendAccount(AccountId.parse('account-a'));
      await _waitForSuspendedLane(fixture.repository);
      releaseFailureCommit.complete();
      await suspension;

      final stored = await fixture.repository.getStoredJob(
        accountId: 'account-a',
        jobId: session.jobId.value,
      );
      expect(putRequests, 1);
      expect(stored?.phase, AttachmentJobPhase.uploading.name);
      expect(stored?.inFlightStep, AttachmentRequestStep.normalPut.name);
      expect(stored?.automaticRetryCount, 0);
      expect(stored?.nextAttemptAtMillis, isNull);
    },
  );
}

Future<void> _waitForSuspendedLane(AttachmentRepository repository) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (true) {
    final runtime = await repository.loadRuntime();
    if (runtime.snapshot.accounts[AccountId.parse('account-a')]?.lane ==
        AttachmentAccountLane.suspended) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the durable suspended lane');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _verifyAccountSuspendDuringUpload({
  required bool emitFirstChunk,
}) async {
  final fixture = await _Fixture.create(fileBacked: true);
  addTearDown(fixture.close);
  final source = _SuspendUploadSourceProvider(
    fixture.sourceFile,
    fixture.bytes,
    emitFirstChunk: emitFirstChunk,
  );
  final client = _SuspendUploadClient();
  final service = fixture.service(client, sourceProvider: source);

  final session = await service.enqueue(fixture.request(normalMaximum: 32));
  await source.uploadReadStarted.future.timeout(const Duration(seconds: 2));
  if (emitFirstChunk) {
    await client.firstBodyChunk.future.timeout(const Duration(seconds: 2));
  }

  await service.suspendAccount(AccountId.parse('account-a'));

  final beforeRetry = await fixture.repository.getStoredJob(
    accountId: 'account-a',
    jobId: session.jobId.value,
  );
  await expectLater(session.retry(), throwsStateError);
  final afterRetry = await fixture.repository.getStoredJob(
    accountId: 'account-a',
    jobId: session.jobId.value,
  );
  expect(afterRetry?.phase, beforeRetry?.phase);
  expect(afterRetry?.automaticRetryCount, beforeRetry?.automaticRetryCount);
  expect(afterRetry?.nextAttemptAtMillis, beforeRetry?.nextAttemptAtMillis);

  final stored = await fixture.repository.getStoredJob(
    accountId: 'account-a',
    jobId: session.jobId.value,
  );
  final runtime = await fixture.repository.loadRuntime();
  expect(
    runtime.snapshot.accounts[AccountId.parse('account-a')]?.lane,
    AttachmentAccountLane.suspended,
  );
  expect(stored?.phase, AttachmentJobPhase.uploading.name);
  expect(stored?.inFlightStep, AttachmentRequestStep.normalPut.name);
  expect(client.bodyBytes, emitFirstChunk ? isNotEmpty : isEmpty);

  await service.close();
  await fixture.reopenDatabase();
  final restarted = fixture.service(_unexpectedClient());
  addTearDown(restarted.close);
  await restarted.ready;
  final recovered = await fixture.repository.getStoredJob(
    accountId: 'account-a',
    jobId: session.jobId.value,
  );
  final recoveredRuntime = await fixture.repository.loadRuntime();
  expect(recovered?.phase, AttachmentJobPhase.retryable.name);
  expect(recovered?.errorClass, 'process-interrupted');
  expect(
    recoveredRuntime.snapshot.accounts[AccountId.parse('account-a')]?.lane,
    AttachmentAccountLane.suspended,
  );
  final beforeRestartRetry = await fixture.repository.getStoredJob(
    accountId: 'account-a',
    jobId: session.jobId.value,
  );
  await expectLater(
    restarted.enqueue(fixture.request(normalMaximum: 32)),
    throwsStateError,
  );
  await expectLater(
    restarted.retry(
      accountId: AccountId.parse('account-a'),
      jobId: session.jobId,
    ),
    throwsStateError,
  );
  final afterRestartRetry = await fixture.repository.getStoredJob(
    accountId: 'account-a',
    jobId: session.jobId.value,
  );
  expect(afterRestartRetry?.phase, beforeRestartRetry?.phase);
  expect(
    afterRestartRetry?.automaticRetryCount,
    beforeRestartRetry?.automaticRetryCount,
  );
  expect(
    afterRestartRetry?.nextAttemptAtMillis,
    beforeRestartRetry?.nextAttemptAtMillis,
  );
}

final class _SuspendUploadSourceProvider implements AttachmentSourceProvider {
  _SuspendUploadSourceProvider(
    this.file,
    this.bytes, {
    required this.emitFirstChunk,
  });

  final File file;
  final List<int> bytes;
  final bool emitFirstChunk;
  final Completer<void> uploadReadStarted = Completer<void>();
  var _openReadCount = 0;

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async => _SuspendUploadSourceLease(this);
}

final class _SuspendUploadSourceLease implements AttachmentSourceLease {
  const _SuspendUploadSourceLease(this.owner);

  final _SuspendUploadSourceProvider owner;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) {
    owner._openReadCount++;
    if (owner._openReadCount == 1) {
      return owner.file.openRead(
        offset,
        length == null ? null : offset + length,
      );
    }
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        owner.uploadReadStarted.complete();
        if (owner.emitFirstChunk) {
          controller.add(owner.bytes.sublist(0, owner.bytes.length ~/ 2));
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<void> close() async {}
}

final class _SuspendUploadClient extends http.BaseClient {
  final List<int> bodyBytes = <int>[];
  final Completer<void> firstBodyChunk = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
      await request.finalize().drain<void>();
      return http.StreamedResponse(Stream.value(_probeSuccess()), 200);
    }
    if (request.method != 'PUT') {
      fail('Unexpected request: ${request.method} ${request.url}');
    }
    final iterator = StreamIterator<List<int>>(request.finalize());
    final abort = (request as http.Abortable).abortTrigger!;
    while (true) {
      final moved = iterator.moveNext();
      final completed = await Future.any<Object?>(<Future<Object?>>[
        moved,
        abort.then<Object?>((_) => null),
      ]);
      if (completed == null) {
        await iterator.cancel();
        throw http.RequestAbortedException(request.url);
      }
      if (completed == false) {
        break;
      }
      bodyBytes.addAll(iterator.current);
      if (!firstBodyChunk.isCompleted) {
        firstBodyChunk.complete();
      }
    }
    return http.StreamedResponse(const Stream.empty(), 201);
  }
}
