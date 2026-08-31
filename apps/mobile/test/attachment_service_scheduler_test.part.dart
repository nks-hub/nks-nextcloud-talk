part of 'attachment_service_test.dart';

void _registerAttachmentServiceSchedulerTests() {
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
}

Future<({File file, PreparedAttachmentSource source})>
_createDistinctAttachmentSource(_Fixture fixture) async {
  final file = File(
    '${fixture.directory.path}${Platform.pathSeparator}source-second.bin',
  );
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
