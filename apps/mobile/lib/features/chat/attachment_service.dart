import 'dart:async';
import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/app_database.dart';
import '../../data/attachment_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/attachment_transport.dart';

typedef ReleaseDurableAttachmentSource =
    Future<void> Function(PreparedAttachmentSource source);
typedef WatchAttachmentConfirmationCandidates =
    Stream<AttachmentConfirmationSnapshot> Function();

abstract interface class AttachmentIdentifierFactory {
  AttachmentJobId newJobId();

  AttachmentRequestId newRequestId();

  ChatReferenceId newReferenceId();

  DavUploadSessionId newUploadSessionId();
}

final class UuidAttachmentIdentifierFactory
    implements AttachmentIdentifierFactory {
  const UuidAttachmentIdentifierFactory();

  static const _uuid = Uuid();

  @override
  AttachmentJobId newJobId() => AttachmentJobId.parse(_uuid.v4());

  @override
  AttachmentRequestId newRequestId() => AttachmentRequestId.parse(_uuid.v4());

  @override
  ChatReferenceId newReferenceId() => ChatReferenceId.parse(_uuid.v4());

  @override
  DavUploadSessionId newUploadSessionId() =>
      DavUploadSessionId.parse(_uuid.v4());
}

final class AttachmentEnqueueRequest {
  AttachmentEnqueueRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.source,
    required this.metadata,
    required this.davUserId,
    required this.profile,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.roomCanWrite,
    required this.policy,
  }) {
    if (credentialGeneration < 1 || capabilityGeneration < 1) {
      throw ArgumentError('Attachment generations must be positive');
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final PreparedAttachmentSource source;
  final AttachmentMetadata metadata;
  final DavUserId davUserId;
  final AttachmentCapabilityProfile profile;
  final int credentialGeneration;
  final int capabilityGeneration;
  final bool roomCanWrite;
  final AttachmentUploadPolicy policy;
}

final class AttachmentJobProgress {
  const AttachmentJobProgress({
    required this.accountId,
    required this.jobId,
    required this.phase,
    required this.progress,
    required this.attemptCount,
    required this.automaticRetryCount,
    required this.retryAllowed,
    required this.errorClass,
    required this.messageIds,
  });

  final AccountId accountId;
  final AttachmentJobId jobId;
  final AttachmentJobPhase phase;
  final double progress;
  final int attemptCount;
  final int automaticRetryCount;
  final bool retryAllowed;
  final String? errorClass;
  final List<int> messageIds;

  bool get isTerminal => const <AttachmentJobPhase>{
    AttachmentJobPhase.completed,
    AttachmentJobPhase.failed,
    AttachmentJobPhase.cancelled,
  }.contains(phase);
}

final class DurableAttachmentSession {
  const DurableAttachmentSession._({
    required this.accountId,
    required this.jobId,
    required this.events,
    required this._cancel,
    required this._retry,
  });

  final AccountId accountId;
  final AttachmentJobId jobId;
  final Stream<AttachmentJobProgress> events;
  final Future<void> Function() _cancel;
  final Future<void> Function() _retry;

  Future<void> cancel() => _cancel();

  Future<void> retry() => _retry();
}

final class AttachmentService {
  factory AttachmentService({
    required AttachmentRepository repository,
    required CredentialVault credentials,
    required ReleaseDurableAttachmentSource releaseSource,
    required HttpAttachmentTransport transport,
    AttachmentIdentifierFactory identifierFactory =
        const UuidAttachmentIdentifierFactory(),
    DateTime Function()? clock,
    WatchAttachmentConfirmationCandidates? watchConfirmationCandidates,
    List<Duration> retryDelays = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 10),
      Duration(minutes: 1),
    ],
  }) {
    if (retryDelays.any((delay) => delay < Duration.zero)) {
      throw ArgumentError.value(retryDelays, 'retryDelays');
    }
    final service = AttachmentService._(
      repository: repository,
      credentials: credentials,
      releaseSource: releaseSource,
      transport: transport,
      identifierFactory: identifierFactory,
      clock: clock ?? DateTime.now,
      watchConfirmationCandidates:
          watchConfirmationCandidates ?? repository.watchConfirmationCandidates,
      retryDelays: List<Duration>.unmodifiable(retryDelays),
    );
    service._ready = service._initialize();
    return service;
  }

  AttachmentService._({
    required this._repository,
    required this._credentials,
    required this._releaseSource,
    required this._transport,
    required this._identifierFactory,
    required this._clock,
    required this._watchConfirmationCandidates,
    required this._retryDelays,
  });

  final AttachmentRepository _repository;
  final CredentialVault _credentials;
  final ReleaseDurableAttachmentSource _releaseSource;
  final HttpAttachmentTransport _transport;
  final AttachmentIdentifierFactory _identifierFactory;
  final DateTime Function() _clock;
  final WatchAttachmentConfirmationCandidates _watchConfirmationCandidates;
  final List<Duration> _retryDelays;
  final _AsyncMutex _stateMutex = _AsyncMutex();
  final Map<_AttachmentRoomKey, Future<void>> _roomRuns = {};
  final Map<_AttachmentRoomKey, Timer> _retryTimers = {};
  final Map<AttachmentPersistenceKey, AttachmentVerifiedSource>
  _verifiedSources = {};
  final Map<AttachmentPersistenceKey, AttachmentCancellationController>
  _cancellations = {};

  late final Future<void> _ready;
  StreamSubscription<AttachmentConfirmationSnapshot>? _confirmationSubscription;
  Future<void> _confirmationTail = Future<void>.value();
  AttachmentRuntimeSnapshot _snapshot = AttachmentRuntimeSnapshot(
    accounts: const {},
  );
  Map<AttachmentPersistenceKey, AttachmentExecutionMetadata> _metadata = {};
  bool _closed = false;

  Future<void> get ready => _ready;

  Future<DurableAttachmentSession> enqueue(
    AttachmentEnqueueRequest request,
  ) async {
    await _ready;
    _ensureOpen();
    if (!request.roomCanWrite ||
        !request.profile.supports(request.metadata) ||
        !request.metadata.supportsSource(request.source)) {
      throw StateError('Attachment request is not supported by this room');
    }
    final storedAccount = await _repository.getAccount(request.accountId.value);
    if (storedAccount == null ||
        ServerBase.parse(storedAccount.serverUrl) != request.server) {
      throw StateError('Attachment account binding is invalid');
    }
    final appPassword = await _credentials.readAppPassword(
      request.accountId.value,
    );
    if (appPassword == null || appPassword.isEmpty) {
      throw StateError('Attachment account credential is unavailable');
    }
    final authorization = AttachmentTransportAuthorization(
      accountId: request.accountId,
      server: request.server,
      loginName: storedAccount.loginName,
      appPassword: appPassword,
    );
    final verifiedSource = await _transport.verifySource(
      source: request.source,
      authorization: authorization,
    );

    AttachmentJobId? admittedJobId;
    try {
      await _stateMutex.protect(() async {
        _ensureOpen();
        var current = _snapshot;
        var account = current.accounts[request.accountId];
        if (account == null) {
          account = AttachmentAccountState(
            accountId: request.accountId,
            server: request.server,
            lane: AttachmentAccountLane.ready,
            credentialGeneration: request.credentialGeneration,
            capabilityGeneration: request.capabilityGeneration,
            jobs: const {},
          );
          current = current.replaceAccount(account);
        } else {
          if (account.server != request.server ||
              request.credentialGeneration < account.credentialGeneration ||
              request.capabilityGeneration < account.capabilityGeneration) {
            throw StateError('Attachment account generation is stale');
          }
          if (request.credentialGeneration != account.credentialGeneration ||
              request.capabilityGeneration != account.capabilityGeneration ||
              account.lane != AttachmentAccountLane.ready) {
            account = account.copyWith(
              lane: AttachmentAccountLane.ready,
              credentialGeneration: request.credentialGeneration,
              capabilityGeneration: request.capabilityGeneration,
            );
            current = current.replaceAccount(account);
          }
        }

        final jobId = _identifierFactory.newJobId();
        final referenceId = _identifierFactory.newReferenceId();
        final sequence = _nextSequence(account, request.roomToken);
        final draft = AttachmentJobDraft(
          jobId: jobId,
          roomToken: request.roomToken,
          referenceId: referenceId,
          source: request.source,
          metadata: request.metadata,
          enqueueSequence: sequence,
          policy: request.policy,
          uploadSessionId:
              request.policy.modeFor(request.source.byteLength) ==
                  AttachmentUploadMode.chunked
              ? _identifierFactory.newUploadSessionId()
              : null,
        );
        final authority = AttachmentAuthority(
          accountId: request.accountId,
          server: request.server,
          capabilityGeneration: request.capabilityGeneration,
          profile: request.profile,
          replayContractRevision: attachmentReplayContractRevision,
          roomCanWrite: request.roomCanWrite,
          roomToken: request.roomToken,
        );
        final admission = admitAttachmentJob(
          current,
          accountId: request.accountId,
          authority: authority,
          davUserId: request.davUserId,
          draft: draft,
        );
        if (!admission.canCommit) {
          throw StateError('Attachment job admission was rejected');
        }
        final candidate = admission.plan!.commit(current);
        final candidateAccount = candidate.accounts[request.accountId]!;
        final job = candidateAccount.jobs[jobId]!;
        final now = _clock().toUtc();
        final metadata = AttachmentExecutionMetadata(
          profile: request.profile,
          roomCanWrite: request.roomCanWrite,
          automaticRetryCount: 0,
          nextAttemptAt: null,
          sourceReleased: false,
          localCleanupError: null,
          createdAt: now,
        );
        await _repository.persistAdmission(
          account: candidateAccount,
          job: job,
          metadata: metadata,
          updatedAt: now,
        );
        final key = _jobKey(request.accountId, jobId);
        _snapshot = candidate;
        _metadata[key] = metadata;
        _verifiedSources[key] = verifiedSource;
        admittedJobId = jobId;
      });
    } on Object {
      await _transport.releaseSource(verifiedSource);
      rethrow;
    }

    final jobId = admittedJobId!;
    final roomKey = _AttachmentRoomKey(request.accountId, request.roomToken);
    unawaited(_scheduleRoom(roomKey));
    return DurableAttachmentSession._(
      accountId: request.accountId,
      jobId: jobId,
      events: watchJob(accountId: request.accountId, jobId: jobId),
      cancel: () => cancel(accountId: request.accountId, jobId: jobId),
      retry: () => retry(accountId: request.accountId, jobId: jobId),
    );
  }

  Stream<AttachmentJobProgress> watchJob({
    required AccountId accountId,
    required AttachmentJobId jobId,
  }) => _repository
      .watchJob(accountId: accountId.value, jobId: jobId.value)
      .where((row) => row != null)
      .cast<StoredAttachmentJob>()
      .map(_progressFromRow);

  Future<void> cancel({
    required AccountId accountId,
    required AttachmentJobId jobId,
  }) async {
    await _ready;
    _ensureOpen();
    final key = _jobKey(accountId, jobId);
    _cancellations[key]?.cancel();
    late final _AttachmentRoomKey roomKey;
    await _stateMutex.protect(() async {
      final job = _snapshot.accounts[accountId]?.jobs[jobId];
      if (job == null) {
        throw StateError('Attachment job does not exist');
      }
      roomKey = _AttachmentRoomKey(accountId, job.draft.roomToken);
      final result = requestAttachmentCancel(
        _snapshot,
        accountId: accountId,
        jobId: jobId,
      );
      if (!result.canCommit) {
        if (result.outcome == AttachmentRuntimeOutcome.unchanged) {
          return;
        }
        throw StateError('Attachment job can no longer be cancelled');
      }
      await _commitTransition(result, key);
    });
    final active = _roomRuns[roomKey];
    if (active != null) {
      await active;
    }
    if (_jobForKey(key)?.phase == AttachmentJobPhase.cancelled) {
      await _releaseTerminalSource(key);
    }
    await _scheduleRoom(roomKey);
  }

  Future<void> discardFailed({
    required AccountId accountId,
    required AttachmentJobId jobId,
  }) async {
    await _ready;
    _ensureOpen();
    final failed = await _stateMutex.protect(() async {
      return _snapshot.accounts[accountId]?.jobs[jobId]?.phase ==
          AttachmentJobPhase.failed;
    });
    if (!failed) {
      throw StateError('Only a failed attachment job can be discarded');
    }
    await cancel(accountId: accountId, jobId: jobId);
  }

  Future<void> retry({
    required AccountId accountId,
    required AttachmentJobId jobId,
  }) async {
    await _ready;
    _ensureOpen();
    late final _AttachmentRoomKey roomKey;
    await _stateMutex.protect(() async {
      final job = _snapshot.accounts[accountId]?.jobs[jobId];
      if (job == null) {
        throw StateError('Attachment job does not exist');
      }
      if (job.phase != AttachmentJobPhase.retryable &&
          job.phase != AttachmentJobPhase.cleanupFailed) {
        throw StateError('Attachment job is not retryable');
      }
      final key = _jobKey(accountId, jobId);
      final metadata = _metadata[key]!;
      final updated = metadata.copyWith(
        automaticRetryCount: 0,
        nextAttemptAt: null,
      );
      await _persistCurrentJob(key, updated);
      _metadata[key] = updated;
      roomKey = _AttachmentRoomKey(accountId, job.draft.roomToken);
    });
    _retryTimers.remove(roomKey)?.cancel();
    await _scheduleRoom(roomKey);
  }

  Future<void> completeReauthentication({
    required AccountId accountId,
    required int credentialGeneration,
    required int capabilityGeneration,
  }) async {
    await _ready;
    _ensureOpen();
    final password = await _credentials.readAppPassword(accountId.value);
    if (password == null || password.isEmpty) {
      throw StateError('Attachment account credential is unavailable');
    }
    final rooms = <_AttachmentRoomKey>{};
    await _stateMutex.protect(() async {
      final result = completeAttachmentAccountReauthentication(
        _snapshot,
        accountId: accountId,
        credentialGeneration: credentialGeneration,
        capabilityGeneration: capabilityGeneration,
      );
      if (!result.canCommit) {
        throw StateError('Attachment account reauthentication was rejected');
      }
      final candidate = result.plan!.commit(_snapshot);
      final account = candidate.accounts[accountId]!;
      await _repository.persistAccountState(
        account: account,
        updatedAt: _clock().toUtc(),
      );
      _snapshot = candidate;
      for (final job in account.jobs.values) {
        if (!_isTerminal(job.phase) &&
            job.phase != AttachmentJobPhase.awaitingConfirmation) {
          rooms.add(_AttachmentRoomKey(accountId, job.draft.roomToken));
        }
      }
    });
    for (final room in rooms) {
      unawaited(_scheduleRoom(room));
    }
  }

  Future<void> reconcileConfirmations({
    required AccountId accountId,
    required Iterable<AttachmentMessageConfirmation> confirmations,
  }) async {
    await _ready;
    _ensureOpen();
    final values = confirmations.toList(growable: false);
    final rooms = <_AttachmentRoomKey>{};
    final completed = <AttachmentPersistenceKey>[];
    await _stateMutex.protect(() async {
      final account = _snapshot.accounts[accountId];
      if (account == null) {
        return;
      }
      final jobs = account.jobs.values.toList(growable: false);
      for (final job in jobs) {
        if (job.phase != AttachmentJobPhase.awaitingConfirmation &&
            job.phase != AttachmentJobPhase.completed) {
          continue;
        }
        final result = reconcileAttachmentConfirmation(
          _snapshot,
          accountId: accountId,
          jobId: job.jobId,
          confirmations: values,
        );
        if (!result.canCommit) {
          continue;
        }
        final key = _jobKey(accountId, job.jobId);
        await _commitTransition(result, key);
        final updated = _snapshot.accounts[accountId]!.jobs[job.jobId]!;
        rooms.add(_AttachmentRoomKey(accountId, updated.draft.roomToken));
        if (updated.phase == AttachmentJobPhase.completed) {
          completed.add(key);
        }
      }
    });
    for (final key in completed) {
      await _releaseTerminalSource(key);
    }
    for (final room in rooms) {
      unawaited(_scheduleRoom(room));
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    await _ready;
    _closed = true;
    final confirmationSubscription = _confirmationSubscription;
    _confirmationSubscription = null;
    await confirmationSubscription?.cancel();
    await _confirmationTail;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    for (final cancellation in _cancellations.values) {
      cancellation.cancel();
    }
    await Future.wait<void>(_roomRuns.values.toList(growable: false));
    for (final entry in _verifiedSources.entries.toList(growable: false)) {
      try {
        await _transport.releaseSource(entry.value);
      } on AttachmentTransportException {
        // The durable source itself remains owned by the persisted job.
      }
    }
    _verifiedSources.clear();
    await _transport.close();
  }

  Future<void> _initialize() async {
    final loaded = await _repository.loadRuntime();
    _snapshot = loaded.snapshot;
    _metadata = Map.of(loaded.metadata);
    for (final account in _snapshot.accounts.values.toList(growable: false)) {
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
    Future<void>.microtask(() async {
      final terminal = <AttachmentPersistenceKey>[];
      final rooms = <_AttachmentRoomKey>{};
      for (final account in _snapshot.accounts.values) {
        for (final job in account.jobs.values) {
          final key = _jobKey(account.accountId, job.jobId);
          if (_isSourceReleasePhase(job.phase)) {
            terminal.add(key);
          } else if (!_isTerminal(job.phase)) {
            rooms.add(
              _AttachmentRoomKey(account.accountId, job.draft.roomToken),
            );
          }
        }
      }
      for (final key in terminal) {
        await _releaseTerminalSource(key);
      }
      for (final room in rooms) {
        unawaited(_scheduleRoom(room));
      }
    });
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
      try {
        await _reconcileObservedConfirmations(snapshot);
      } on Object {
        // Database observation never authorizes a transport retry or resend.
      }
    }();
  }

  Future<void> _reconcileObservedConfirmations(
    AttachmentConfirmationSnapshot snapshot,
  ) async {
    for (final batch in snapshot.batches) {
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
        await _releaseTerminalSource(key);
      }
      final room = completedRoom;
      if (room != null && !_closed) {
        unawaited(_scheduleRoom(room));
      }
    }
  }

  Future<void> _scheduleRoom(_AttachmentRoomKey roomKey) async {
    await _ready;
    if (_closed) {
      return;
    }
    final active = _roomRuns[roomKey];
    if (active != null) {
      return active;
    }
    late final Future<void> run;
    run = _runRoom(roomKey).whenComplete(() {
      if (identical(_roomRuns[roomKey], run)) {
        _roomRuns.remove(roomKey);
      }
    });
    _roomRuns[roomKey] = run;
    return run;
  }

  Future<void> _runRoom(_AttachmentRoomKey roomKey) async {
    while (!_closed) {
      final selection = await _stateMutex.protect(
        () async => _selectNextJob(roomKey),
      );
      if (selection == null) {
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
      if (phase == AttachmentJobPhase.awaitingConfirmation ||
          phase == AttachmentJobPhase.finalizing ||
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
    if (job == null) {
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
          return;
        }
        await _commitTransition(result, key);
        request = result.request;
        job = _jobForKey(key);
      });
      final plannedRequest = request;
      if (plannedRequest == null) {
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
    await _repository.persistTransition(
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
    return _repository.persistTransition(
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
    final job = _jobForKey(key);
    final metadata = _metadata[key];
    if (job == null || metadata == null || metadata.sourceReleased) {
      return;
    }
    try {
      await _releaseSource(job.draft.source);
      final updated = metadata.copyWith(
        sourceReleased: true,
        localCleanupError: null,
      );
      await _stateMutex.protect(() async {
        await _persistCurrentJob(key, updated);
        _metadata[key] = updated;
      });
    } on Object {
      final updated = metadata.copyWith(
        sourceReleased: false,
        localCleanupError: 'local-source-cleanup-failed',
      );
      await _stateMutex.protect(() async {
        await _persistCurrentJob(key, updated);
        _metadata[key] = updated;
      });
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

final class _SelectedAttachmentJob {
  const _SelectedAttachmentJob(this.key, this.roomKey);

  final AttachmentPersistenceKey key;
  final _AttachmentRoomKey roomKey;
}

final class _AttachmentRoomKey {
  const _AttachmentRoomKey(this.accountId, this.roomToken);

  final AccountId accountId;
  final ConversationToken roomToken;

  @override
  bool operator ==(Object other) =>
      other is _AttachmentRoomKey &&
      other.accountId == accountId &&
      other.roomToken == roomToken;

  @override
  int get hashCode => Object.hash(accountId, roomToken);
}

final class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> protect<T>(Future<T> Function() action) {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    return previous.then((_) => action()).whenComplete(() {
      if (!release.isCompleted) {
        release.complete();
      }
    });
  }
}

AttachmentPersistenceKey _jobKey(AccountId accountId, AttachmentJobId jobId) =>
    (accountId: accountId.value, jobId: jobId.value);

int _nextSequence(AttachmentAccountState account, ConversationToken roomToken) {
  var maximum = 0;
  for (final job in account.jobs.values) {
    if (job.draft.roomToken == roomToken &&
        job.draft.enqueueSequence > maximum) {
      maximum = job.draft.enqueueSequence;
    }
  }
  return maximum + 1;
}

AttachmentJobProgress _progressFromRow(StoredAttachmentJob row) {
  final phase = AttachmentJobPhase.values.singleWhere(
    (value) => value.name == row.phase,
  );
  final ranges = (jsonDecode(row.verifiedChunksJson) as List<Object?>)
      .cast<String>();
  var transferred = 0;
  for (final range in ranges) {
    transferred += DavChunkRange.parse(
      range,
      fileSize: row.sourceByteLength,
    ).length;
  }
  final progress = switch (phase) {
    AttachmentJobPhase.uploaded ||
    AttachmentJobPhase.finalizing ||
    AttachmentJobPhase.awaitingConfirmation ||
    AttachmentJobPhase.completed => 1.0,
    AttachmentJobPhase.uploading when row.uploadSessionId != null =>
      (transferred / row.sourceByteLength).clamp(0.0, 1.0),
    _ => 0.0,
  };
  final messageIds = (jsonDecode(row.messageIdsJson) as List<Object?>)
      .cast<int>();
  return AttachmentJobProgress(
    accountId: AccountId.parse(row.accountId),
    jobId: AttachmentJobId.parse(row.jobId),
    phase: phase,
    progress: progress,
    attemptCount: row.attemptCount,
    automaticRetryCount: row.automaticRetryCount,
    retryAllowed:
        phase == AttachmentJobPhase.retryable ||
        phase == AttachmentJobPhase.cleanupFailed,
    errorClass: row.localCleanupError ?? row.errorClass,
    messageIds: List<int>.unmodifiable(messageIds),
  );
}

bool _isTerminal(AttachmentJobPhase phase) => const <AttachmentJobPhase>{
  AttachmentJobPhase.completed,
  AttachmentJobPhase.failed,
  AttachmentJobPhase.cancelled,
}.contains(phase);

bool _isSourceReleasePhase(AttachmentJobPhase phase) =>
    phase == AttachmentJobPhase.completed ||
    phase == AttachmentJobPhase.cancelled;

const String _zeroSha256 =
    '0000000000000000000000000000000000000000000000000000000000000000';
const String _oneSha256 =
    '1111111111111111111111111111111111111111111111111111111111111111';
