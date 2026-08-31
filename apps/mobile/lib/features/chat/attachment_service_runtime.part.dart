part of 'attachment_service.dart';

mixin _AttachmentServiceRuntime {
  AttachmentRepository get _repository;
  CredentialVault get _credentials;
  ReleaseDurableAttachmentSource get _releaseSource;
  HttpAttachmentTransport get _transport;
  AttachmentIdentifierFactory get _identifierFactory;
  DateTime Function() get _clock;
  WatchAttachmentConfirmationCandidates get _watchConfirmationCandidates;
  PersistAttachmentTransition get _persistTransition;
  CatchUpAttachmentConfirmation? get _catchUpConfirmation;
  BeforeAttachmentRoomIdle? get _beforeRoomIdle;
  List<Duration> get _confirmationRetryDelays;
  List<Duration> get _retryDelays;
  _AsyncMutex get _stateMutex;
  Map<_AttachmentRoomKey, Future<void>> get _roomRuns;
  Set<_AttachmentRoomKey> get _roomRerunRequests;
  Map<_AttachmentRoomKey, Timer> get _retryTimers;
  Map<AttachmentPersistenceKey, Future<void>> get _confirmationCatchUps;
  Map<AttachmentPersistenceKey, Timer> get _confirmationRetryTimers;
  Map<AttachmentPersistenceKey, int> get _confirmationRetryCounts;
  Map<AttachmentPersistenceKey, AttachmentVerifiedSource> get _verifiedSources;
  Map<AttachmentPersistenceKey, AttachmentCancellationController>
  get _cancellations;
  Map<AttachmentPersistenceKey, Completer<void>> get _terminalSourceReleases;
  Set<AccountId> get _suspendedAccounts;
  Future<void> get _ready;
  set _startupMaintenance(Future<void> value);
  set _confirmationSubscription(
    StreamSubscription<AttachmentConfirmationSnapshot>? value,
  );
  Future<void> get _confirmationTail;
  set _confirmationTail(Future<void> value);
  AttachmentRuntimeSnapshot get _snapshot;
  set _snapshot(AttachmentRuntimeSnapshot value);
  Map<AttachmentPersistenceKey, AttachmentExecutionMetadata> get _metadata;
  set _metadata(
    Map<AttachmentPersistenceKey, AttachmentExecutionMetadata> value,
  );
  bool get _closed;

  Future<void> _initialize() async {
    final loaded = await _repository.loadRuntime();
    _snapshot = loaded.snapshot;
    _metadata = Map.of(loaded.metadata);
    for (final account in _snapshot.accounts.values.toList(growable: false)) {
      if (account.lane == AttachmentAccountLane.suspended) {
        _suspendedAccounts.add(account.accountId);
      }
      for (final job in account.jobs.values.toList(growable: false)) {
        if (job.inFlightRequest == null) {
          continue;
        }
        final result = recoverAttachmentAfterRestart(
          _snapshot,
          accountId: account.accountId,
          jobId: job.jobId,
        );
        if (result.canCommit) {
          await _commitTransition(
            result,
            _jobKey(account.accountId, job.jobId),
          );
        }
      }
    }
    _confirmationSubscription = _watchConfirmationCandidates().listen(
      _queueConfirmationSnapshot,
      onError: (Object _, StackTrace _) {},
    );
    _startupMaintenance = Future<void>.microtask(_runStartupMaintenance);
  }

  Future<void> _runStartupMaintenance() async {
    final terminal = <AttachmentPersistenceKey>[];
    final awaitingConfirmation = <AttachmentPersistenceKey>[];
    final rooms = <_AttachmentRoomKey>{};
    for (final account in _snapshot.accounts.values) {
      for (final job in account.jobs.values) {
        final key = _jobKey(account.accountId, job.jobId);
        if (_isSourceReleasePhase(job.phase)) {
          terminal.add(key);
        } else if (!_isTerminal(job.phase)) {
          if (job.phase == AttachmentJobPhase.awaitingConfirmation &&
              job.errorClass != attachmentConfirmationReconciliationRequired) {
            awaitingConfirmation.add(key);
          }
          rooms.add(_AttachmentRoomKey(account.accountId, job.draft.roomToken));
        }
      }
    }
    for (final key in terminal) {
      await _releaseTerminalSource(key);
    }
    for (final key in awaitingConfirmation) {
      _queueConfirmationCatchUp(key);
    }
    for (final room in rooms) {
      unawaited(_scheduleRoom(room));
    }
  }

  void _queueConfirmationSnapshot(AttachmentConfirmationSnapshot snapshot) {
    final previous = _confirmationTail;
    _confirmationTail = () async {
      try {
        await previous;
      } on Object {
        // A failed observation must not poison later database snapshots.
      }
      if (_closed) {
        return;
      }
      await _reconcileObservedConfirmationsWithRetry(snapshot);
    }();
  }

  Future<void> _reconcileObservedConfirmationsWithRetry(
    AttachmentConfirmationSnapshot snapshot,
  ) async {
    for (var attempt = 0; ; attempt++) {
      if (_closed) {
        return;
      }
      try {
        await _reconcileObservedConfirmations(snapshot);
        return;
      } on Object {
        if (attempt >= _localPersistenceRetryDelays.length) {
          return;
        }
        await Future<void>.delayed(_localPersistenceRetryDelays[attempt]);
      }
    }
  }

  Future<void> _reconcileObservedConfirmations(
    AttachmentConfirmationSnapshot snapshot,
  ) async {
    for (final batch in snapshot.batches) {
      if (_suspendedAccounts.contains(batch.accountId)) {
        continue;
      }
      AttachmentPersistenceKey? completedKey;
      _AttachmentRoomKey? completedRoom;
      await _stateMutex.protect(() async {
        if (_closed) {
          return;
        }
        final job = _snapshot.accounts[batch.accountId]?.jobs[batch.jobId];
        if (job == null ||
            job.phase != AttachmentJobPhase.awaitingConfirmation) {
          return;
        }
        final result = reconcileAttachmentConfirmation(
          _snapshot,
          accountId: batch.accountId,
          jobId: batch.jobId,
          confirmations: batch.confirmations,
        );
        if (!result.canCommit) {
          return;
        }
        final key = _jobKey(batch.accountId, batch.jobId);
        await _commitTransition(result, key);
        final updated = _snapshot.accounts[batch.accountId]!.jobs[batch.jobId]!;
        if (updated.phase == AttachmentJobPhase.completed) {
          completedKey = key;
          completedRoom = _AttachmentRoomKey(
            batch.accountId,
            updated.draft.roomToken,
          );
        }
      });
      final key = completedKey;
      if (key != null) {
        _clearConfirmationCatchUp(key);
        await _releaseTerminalSource(key);
      }
      final room = completedRoom;
      if (room != null && !_closed) {
        unawaited(_scheduleRoom(room));
      }
    }
  }

  void _queueConfirmationCatchUp(AttachmentPersistenceKey key) {
    if (_closed ||
        _catchUpConfirmation == null ||
        _suspendedAccounts.contains(AccountId.parse(key.accountId))) {
      return;
    }
    _confirmationRetryTimers.remove(key)?.cancel();
    if (_confirmationCatchUps.containsKey(key)) {
      return;
    }
    late final Future<void> operation;
    operation = _runConfirmationCatchUp(key).whenComplete(() {
      if (identical(_confirmationCatchUps[key], operation)) {
        _confirmationCatchUps.remove(key);
      }
    });
    _confirmationCatchUps[key] = operation;
  }

  Future<void> _runConfirmationCatchUp(AttachmentPersistenceKey key) async {
    var shouldRetry = false;
    try {
      final job = _jobForKey(key);
      if (job == null || job.phase != AttachmentJobPhase.awaitingConfirmation) {
        _clearConfirmationCatchUp(key);
        return;
      }
      await _catchUpConfirmation!(
        accountId: job.accountId,
        roomToken: job.draft.roomToken,
        threadId: job.draft.metadata.threadId,
      );
      final current = _jobForKey(key);
      if (current == null ||
          current.phase != AttachmentJobPhase.awaitingConfirmation) {
        _clearConfirmationCatchUp(key);
        return;
      }
      final batch = await _repository.loadConfirmationCandidates(
        accountId: key.accountId,
        jobId: key.jobId,
      );
      if (batch == null) {
        shouldRetry = true;
      } else {
        await _reconcileObservedConfirmations(
          AttachmentConfirmationSnapshot(<AttachmentConfirmationBatch>[batch]),
        );
        if (_jobForKey(key)?.phase == AttachmentJobPhase.completed) {
          _clearConfirmationCatchUp(key);
        } else if (_jobForKey(key)?.phase ==
            AttachmentJobPhase.awaitingConfirmation) {
          shouldRetry = true;
        }
      }
    } on Object {
      shouldRetry = true;
    }
    if (shouldRetry) {
      await _scheduleConfirmationRetry(key);
    }
  }

  Future<void> _scheduleConfirmationRetry(AttachmentPersistenceKey key) async {
    if (_catchUpConfirmation == null ||
        _confirmationRetryTimers.containsKey(key) ||
        _suspendedAccounts.contains(AccountId.parse(key.accountId))) {
      return;
    }
    final retryCount = _confirmationRetryCounts[key] ?? 0;
    if (_closed || retryCount >= _confirmationRetryDelays.length) {
      await _markConfirmationReconciliationRequired(
        key,
        attemptCount: retryCount + 1,
      );
      return;
    }
    _confirmationRetryCounts[key] = retryCount + 1;
    _confirmationRetryTimers[key] = Timer(
      _confirmationRetryDelays[retryCount],
      () {
        _confirmationRetryTimers.remove(key);
        _queueConfirmationCatchUp(key);
      },
    );
  }

  Future<void> _markConfirmationReconciliationRequired(
    AttachmentPersistenceKey key, {
    required int attemptCount,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _stateMutex.protect(() async {
          final accountId = AccountId.parse(key.accountId);
          final jobId = AttachmentJobId.parse(key.jobId);
          final account = _snapshot.accounts[accountId];
          final job = account?.jobs[jobId];
          final metadata = _metadata[key];
          if (account == null ||
              job == null ||
              metadata == null ||
              job.phase != AttachmentJobPhase.awaitingConfirmation) {
            return;
          }
          final jobs = Map<AttachmentJobId, AttachmentJob>.of(account.jobs);
          final updatedJob = job.copyWith(
            errorClass: attachmentConfirmationReconciliationRequired,
          );
          jobs[jobId] = updatedJob;
          final updatedAccount = account.copyWith(jobs: jobs);
          final updatedMetadata = metadata.copyWith(
            automaticRetryCount: attemptCount,
            nextAttemptAt: null,
          );
          await _persistTransition(
            account: updatedAccount,
            job: updatedJob,
            metadata: updatedMetadata,
            updatedAt: _clock().toUtc(),
          );
          _snapshot = _snapshot.replaceAccount(updatedAccount);
          _metadata[key] = updatedMetadata;
        });
        _confirmationRetryCounts.remove(key);
        return;
      } on Object {
        if (attempt >= _localPersistenceRetryDelays.length) {
          rethrow;
        }
        await Future<void>.delayed(_localPersistenceRetryDelays[attempt]);
      }
    }
  }

  void _clearConfirmationCatchUp(AttachmentPersistenceKey key) {
    _confirmationRetryTimers.remove(key)?.cancel();
    _confirmationRetryCounts.remove(key);
  }

  Future<void> _scheduleRoom(_AttachmentRoomKey roomKey) async {
    await _ready;
    if (_closed || _suspendedAccounts.contains(roomKey.accountId)) {
      return;
    }
    _roomRerunRequests.add(roomKey);
    final active = _roomRuns[roomKey];
    if (active != null) {
      return active;
    }
    late final Future<void> run;
    run = _drainRoom(roomKey).whenComplete(() {
      if (identical(_roomRuns[roomKey], run)) {
        _roomRuns.remove(roomKey);
      }
      if (!_closed && _roomRerunRequests.remove(roomKey)) {
        unawaited(_scheduleRoom(roomKey));
      }
    });
    _roomRuns[roomKey] = run;
    return run;
  }

  Future<void> _drainRoom(_AttachmentRoomKey roomKey) async {
    while (!_closed) {
      _roomRerunRequests.remove(roomKey);
      await _runRoom(roomKey);
      if (!_roomRerunRequests.contains(roomKey)) {
        return;
      }
    }
  }

  Future<void> _runRoom(_AttachmentRoomKey roomKey) async {
    while (!_closed) {
      final selection = await _stateMutex.protect(
        () async => _selectNextJob(roomKey),
      );
      if (selection == null) {
        await _beforeRoomIdle?.call();
        return;
      }
      final progressed = await _executeOneStep(selection);
      if (!progressed) {
        return;
      }
    }
  }

  _SelectedAttachmentJob? _selectNextJob(_AttachmentRoomKey roomKey) {
    final account = _snapshot.accounts[roomKey.accountId];
    if (account == null || account.lane != AttachmentAccountLane.ready) {
      return null;
    }
    final jobs =
        account.jobs.values
            .where((job) => job.draft.roomToken == roomKey.roomToken)
            .toList()
          ..sort(
            (left, right) => left.draft.enqueueSequence.compareTo(
              right.draft.enqueueSequence,
            ),
          );
    for (final job in jobs) {
      final phase = job.phase;
      if (_isTerminal(phase)) {
        continue;
      }
      if (phase == AttachmentJobPhase.awaitingConfirmation) {
        continue;
      }
      if (phase == AttachmentJobPhase.finalizing ||
          phase == AttachmentJobPhase.probing ||
          phase == AttachmentJobPhase.uploading &&
              job.inFlightRequest != null) {
        return null;
      }
      final key = _jobKey(account.accountId, job.jobId);
      if (phase == AttachmentJobPhase.retryable ||
          phase == AttachmentJobPhase.cleanupFailed) {
        final metadata = _metadata[key]!;
        final next = metadata.nextAttemptAt;
        if (next == null && metadata.automaticRetryCount > 0) {
          return null;
        }
        if (next != null && next.isAfter(_clock().toUtc())) {
          _armRetry(roomKey, next);
          return null;
        }
      }
      return _SelectedAttachmentJob(key, roomKey);
    }
    return null;
  }

  Future<bool> _executeOneStep(_SelectedAttachmentJob selection) async {
    final key = selection.key;
    AttachmentJob? job = _jobForKey(key);
    if (job == null || _suspendedAccounts.contains(job.accountId)) {
      return false;
    }
    final storedAccount = await _repository.getAccount(key.accountId);
    final password = await _credentials.readAppPassword(key.accountId);
    if (storedAccount == null || password == null || password.isEmpty) {
      return false;
    }
    final authorization = AttachmentTransportAuthorization(
      accountId: job.accountId,
      server: job.server,
      loginName: storedAccount.loginName,
      appPassword: password,
    );
    final cancellation = AttachmentCancellationController();
    AttachmentRequest? dispatchedRequest;
    _cancellations[key] = cancellation;
    try {
      AttachmentSourceObservation? observation;
      if (job.phase == AttachmentJobPhase.draftResolved ||
          job.phase == AttachmentJobPhase.uploading ||
          job.phase == AttachmentJobPhase.retryable &&
              job.resumePhase == AttachmentJobPhase.draftResolved) {
        try {
          await _ensureVerifiedSource(
            key,
            job,
            authorization,
            cancellation.signal,
          );
          observation = AttachmentSourceObservation(
            handle: job.draft.source.handle,
            byteLength: job.draft.source.byteLength,
            sha256: job.draft.source.sha256,
          );
        } on AttachmentTransportException catch (error) {
          if (error.code == AttachmentTransportError.cancelled ||
              cancellation.isCancelled) {
            return false;
          }
          return _recordUnavailableSource(key, job);
        }
      }
      if (cancellation.isCancelled) {
        return false;
      }

      AttachmentRequest? request;
      var planningRejected = false;
      await _stateMutex.protect(() async {
        final currentJob = _jobForKey(key);
        if (cancellation.isCancelled ||
            currentJob == null ||
            currentJob.phase != job!.phase) {
          return;
        }
        final account = _snapshot.accounts[currentJob.accountId]!;
        final metadata = _metadata[key]!;
        final authority = AttachmentAuthority(
          accountId: currentJob.accountId,
          server: currentJob.server,
          capabilityGeneration: account.capabilityGeneration,
          profile: metadata.profile,
          replayContractRevision: attachmentReplayContractRevision,
          roomCanWrite: metadata.roomCanWrite,
          roomToken: currentJob.draft.roomToken,
        );
        final result = planNextAttachmentStep(
          _snapshot,
          accountId: currentJob.accountId,
          jobId: currentJob.jobId,
          authority: authority,
          requestId: _identifierFactory.newRequestId(),
          sourceObservation: observation,
        );
        if (!result.canCommit) {
          planningRejected = true;
          return;
        }
        await _commitTransition(result, key);
        request = result.request;
        job = _jobForKey(key);
      });
      final plannedRequest = request;
      if (plannedRequest == null) {
        if (planningRejected) {
          return false;
        }
        final current = _jobForKey(key);
        if (current != null && _isSourceReleasePhase(current.phase)) {
          await _releaseTerminalSource(key);
        }
        return !cancellation.isCancelled;
      }

      dispatchedRequest = plannedRequest;
      final response = await _dispatch(
        plannedRequest,
        authorization,
        key,
        cancellation.signal,
      );
      await _stateMutex.protect(() async {
        if (_suspendedAccounts.contains(job!.accountId)) {
          return;
        }
        final result = applyAttachmentResponse(
          _snapshot,
          accountId: job!.accountId,
          jobId: job!.jobId,
          response: response,
        );
        if (result.canCommit) {
          await _commitTransition(result, key);
        }
      });
    } on AttachmentTransportException catch (error) {
      if (error.code == AttachmentTransportError.cancelled ||
          cancellation.isCancelled) {
        return false;
      }
      final failedRequest = dispatchedRequest;
      if (failedRequest == null) {
        rethrow;
      }
      await _stateMutex.protect(() async {
        final result = recordAttachmentTransportFailure(
          _snapshot,
          accountId: job!.accountId,
          jobId: job!.jobId,
          request: failedRequest,
          bodyState: error.requestMayHaveReachedServer
              ? AttachmentTransportBodyState.possiblySent
              : AttachmentTransportBodyState.notSent,
        );
        if (result.canCommit) {
          await _commitTransition(result, key);
        }
      });
    } finally {
      if (identical(_cancellations[key], cancellation)) {
        _cancellations.remove(key);
      }
    }

    final current = _jobForKey(key);
    if (current == null) {
      return false;
    }
    if (current.phase == AttachmentJobPhase.uploaded ||
        current.phase == AttachmentJobPhase.awaitingConfirmation ||
        _isSourceReleasePhase(current.phase)) {
      await _releaseVerifiedSource(key);
    }
    if (current.phase == AttachmentJobPhase.awaitingConfirmation) {
      _queueConfirmationCatchUp(key);
    }
    if (_isSourceReleasePhase(current.phase)) {
      await _releaseTerminalSource(key);
    }
    final metadata = _metadata[key]!;
    if (metadata.nextAttemptAt != null) {
      _armRetry(selection.roomKey, metadata.nextAttemptAt!);
      return false;
    }
    if ((current.phase == AttachmentJobPhase.retryable ||
            current.phase == AttachmentJobPhase.cleanupFailed) &&
        metadata.automaticRetryCount > _retryDelays.length) {
      return false;
    }
    return true;
  }

  Future<AttachmentResponse> _dispatch(
    AttachmentRequest request,
    AttachmentTransportAuthorization authorization,
    AttachmentPersistenceKey key,
    AttachmentCancellationSignal cancellation,
  ) => switch (request) {
    final AttachmentProbeRequest probe => _transport.probe(
      request: probe,
      authorization: authorization,
      cancellationSignal: cancellation,
    ),
    final AttachmentFinalizeRequest finalize => _transport.finalize(
      request: finalize,
      authorization: authorization,
      cancellationSignal: cancellation,
    ),
    final AttachmentDavRequest dav => _transport.sendDav(
      request: dav,
      authorization: authorization,
      cancellationSignal: cancellation,
      verifiedSource: dav.body is AttachmentSourceBody
          ? _verifiedSources[key]
          : null,
      fileSize: dav.step == AttachmentRequestStep.chunkPropfind
          ? _jobForKey(key)!.draft.source.byteLength
          : null,
    ),
  };

  Future<void> _ensureVerifiedSource(
    AttachmentPersistenceKey key,
    AttachmentJob job,
    AttachmentTransportAuthorization authorization,
    AttachmentCancellationSignal cancellation,
  ) async {
    final existing = _verifiedSources[key];
    if (existing != null && !existing.isClosed) {
      return;
    }
    _verifiedSources[key] = await _transport.verifySource(
      source: job.draft.source,
      authorization: authorization,
      cancellationSignal: cancellation,
    );
  }

  Future<bool> _recordUnavailableSource(
    AttachmentPersistenceKey key,
    AttachmentJob expected,
  ) async {
    var changed = false;
    await _stateMutex.protect(() async {
      final current = _jobForKey(key);
      if (!identical(current, expected)) {
        return;
      }
      final alternate = expected.draft.source.sha256.value == _zeroSha256
          ? _oneSha256
          : _zeroSha256;
      final metadata = _metadata[key]!;
      final account = _snapshot.accounts[expected.accountId]!;
      final result = planNextAttachmentStep(
        _snapshot,
        accountId: expected.accountId,
        jobId: expected.jobId,
        authority: AttachmentAuthority(
          accountId: expected.accountId,
          server: expected.server,
          capabilityGeneration: account.capabilityGeneration,
          profile: metadata.profile,
          replayContractRevision: attachmentReplayContractRevision,
          roomCanWrite: metadata.roomCanWrite,
          roomToken: expected.draft.roomToken,
        ),
        requestId: _identifierFactory.newRequestId(),
        sourceObservation: AttachmentSourceObservation(
          handle: expected.draft.source.handle,
          byteLength: expected.draft.source.byteLength,
          sha256: AttachmentSha256.parse(alternate),
        ),
      );
      if (result.canCommit) {
        await _commitTransition(result, key);
        changed = true;
      }
    });
    return changed;
  }

  Future<void> _commitTransition(
    AttachmentRuntimeResult result,
    AttachmentPersistenceKey key,
  ) async {
    final candidate = result.plan!.commit(_snapshot);
    final accountId = AccountId.parse(key.accountId);
    final jobId = AttachmentJobId.parse(key.jobId);
    final account = candidate.accounts[accountId]!;
    final job = account.jobs[jobId]!;
    var metadata = _metadata[key]!;
    if (result.outcome == AttachmentRuntimeOutcome.retryable ||
        result.outcome == AttachmentRuntimeOutcome.cleanupFailed) {
      final retryCount = metadata.automaticRetryCount + 1;
      final nextAttempt = retryCount <= _retryDelays.length
          ? _clock().toUtc().add(_retryDelays[retryCount - 1])
          : null;
      metadata = metadata.copyWith(
        automaticRetryCount: retryCount,
        nextAttemptAt: nextAttempt,
      );
    } else if (result.request == null &&
        result.outcome != AttachmentRuntimeOutcome.unchanged) {
      metadata = metadata.copyWith(automaticRetryCount: 0, nextAttemptAt: null);
    }
    await _persistTransition(
      account: account,
      job: job,
      metadata: metadata,
      updatedAt: _clock().toUtc(),
    );
    _snapshot = candidate;
    _metadata[key] = metadata;
  }

  Future<void> _persistCurrentJob(
    AttachmentPersistenceKey key,
    AttachmentExecutionMetadata metadata,
  ) {
    final accountId = AccountId.parse(key.accountId);
    final jobId = AttachmentJobId.parse(key.jobId);
    final account = _snapshot.accounts[accountId]!;
    return _persistTransition(
      account: account,
      job: account.jobs[jobId]!,
      metadata: metadata,
      updatedAt: _clock().toUtc(),
    );
  }

  Future<void> _releaseVerifiedSource(AttachmentPersistenceKey key) async {
    final verified = _verifiedSources.remove(key);
    if (verified == null) {
      return;
    }
    try {
      await _transport.releaseSource(verified);
    } on AttachmentTransportException {
      // The durable source remains available for a later reopen or retry.
    }
  }

  Future<void> _releaseTerminalSource(AttachmentPersistenceKey key) async {
    await _releaseVerifiedSource(key);
    Completer<void>? claim;
    AttachmentJob? claimedJob;
    var ownsClaim = false;
    await _stateMutex.protect(() async {
      final active = _terminalSourceReleases[key];
      if (active != null) {
        claim = active;
        return;
      }
      final job = _jobForKey(key);
      final metadata = _metadata[key];
      if (job == null || metadata == null || metadata.sourceReleased) {
        return;
      }
      claim = Completer<void>();
      claimedJob = job;
      ownsClaim = true;
      _terminalSourceReleases[key] = claim!;
    });
    final activeClaim = claim;
    if (activeClaim == null) {
      return;
    }
    if (ownsClaim) {
      unawaited(_executeTerminalSourceRelease(key, claimedJob!, activeClaim));
    }
    await activeClaim.future;
  }

  Future<void> _executeTerminalSourceRelease(
    AttachmentPersistenceKey key,
    AttachmentJob job,
    Completer<void> claim,
  ) async {
    Object? failure;
    StackTrace? failureStack;
    var released = false;
    try {
      await _releaseSource(job.draft.source);
      released = true;
    } on Object {
      released = false;
    }
    try {
      await _recordTerminalSourceRelease(
        key,
        released: released,
        error: released ? null : 'local-source-cleanup-failed',
      );
    } on Object catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    try {
      await _stateMutex.protect(() async {
        if (identical(_terminalSourceReleases[key], claim)) {
          _terminalSourceReleases.remove(key);
        }
      });
    } on Object catch (error, stackTrace) {
      failure ??= error;
      failureStack ??= stackTrace;
    }
    if (failure == null) {
      claim.complete();
    } else {
      claim.completeError(failure, failureStack);
    }
  }

  Future<void> _recordTerminalSourceRelease(
    AttachmentPersistenceKey key, {
    required bool released,
    required String? error,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _stateMutex.protect(() async {
          final metadata = _metadata[key];
          if (metadata == null) {
            return;
          }
          final updated = metadata.copyWith(
            sourceReleased: released,
            localCleanupError: error,
          );
          _metadata[key] = updated;
          await _persistCurrentJob(key, updated);
        });
        return;
      } on Object {
        if (attempt >= _localPersistenceRetryDelays.length) {
          rethrow;
        }
        await Future<void>.delayed(_localPersistenceRetryDelays[attempt]);
      }
    }
  }

  void _armRetry(_AttachmentRoomKey roomKey, DateTime at) {
    final delay = at.difference(_clock().toUtc());
    final current = _retryTimers[roomKey];
    current?.cancel();
    _retryTimers[roomKey] = Timer(delay.isNegative ? Duration.zero : delay, () {
      _retryTimers.remove(roomKey);
      unawaited(_scheduleRoom(roomKey));
    });
  }

  AttachmentJob? _jobForKey(AttachmentPersistenceKey key) => _snapshot
      .accounts[AccountId.parse(key.accountId)]
      ?.jobs[AttachmentJobId.parse(key.jobId)];

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Attachment service is closed');
    }
  }
}
