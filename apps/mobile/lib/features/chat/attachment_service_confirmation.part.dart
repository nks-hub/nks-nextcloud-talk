part of 'attachment_service.dart';

extension _AttachmentConfirmationRuntime on _AttachmentServiceRuntime {
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
      final resume = _confirmationResumeRequests.remove(key);
      if (resume && !_closed && _deferredConfirmations.remove(key)) {
        _queueConfirmationCatchUp(key);
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
      final result = await _catchUpConfirmation!(
        accountId: job.accountId,
        roomToken: job.draft.roomToken,
        threadId: job.draft.metadata.threadId,
      );
      if (result == ChatSynchronizationResult.deferred) {
        if (!_closed &&
            !_suspendedAccounts.contains(job.accountId) &&
            _jobForKey(key)?.phase == AttachmentJobPhase.awaitingConfirmation) {
          _deferredConfirmations.add(key);
        }
        return;
      }
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
    _AttachmentRoomKey? parkedRoom;
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
          parkedRoom = _AttachmentRoomKey(accountId, job.draft.roomToken);
        });
        _confirmationRetryCounts.remove(key);
        final room = parkedRoom;
        if (room != null && !_closed) {
          // The parked job no longer holds room order, so whatever it was
          // holding back can finalize now instead of on the next upload.
          unawaited(_scheduleRoom(room));
        }
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
    _deferredConfirmations.remove(key);
    _confirmationResumeRequests.remove(key);
    _confirmationRetryTimers.remove(key)?.cancel();
    _confirmationRetryCounts.remove(key);
  }
}
