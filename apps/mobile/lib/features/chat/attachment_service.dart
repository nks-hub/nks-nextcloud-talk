import 'dart:async';
import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../core/attachment_upload_telemetry.dart';
import '../../core/performance_telemetry.dart';
import '../../data/app_database.dart';
import '../../data/attachment_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/attachment_transport.dart';

part 'attachment_service_runtime.part.dart';
part 'attachment_service_support.part.dart';

typedef ReleaseDurableAttachmentSource =
    Future<void> Function(PreparedAttachmentSource source);
typedef WatchAttachmentConfirmationCandidates =
    Stream<AttachmentConfirmationSnapshot> Function();
typedef PersistAttachmentTransition =
    Future<void> Function({
      required AttachmentAccountState account,
      required AttachmentJob job,
      required AttachmentExecutionMetadata metadata,
      required DateTime updatedAt,
    });
typedef CatchUpAttachmentConfirmation =
    Future<void> Function({
      required AccountId accountId,
      required ConversationToken roomToken,
      required int? threadId,
    });
typedef BeforeAttachmentRoomIdle = Future<void> Function();
typedef BeforeAttachmentTransportFailureCommit = Future<void> Function();
typedef BeforeAttachmentStepPlan =
    Future<void> Function({
      required AttachmentJobId jobId,
      required AttachmentJobPhase phase,
    });
typedef CreateAttachmentRetryTimer =
    Timer Function(Duration delay, void Function() callback);

const String attachmentConfirmationReconciliationRequired =
    'confirmation-reconciliation-required';

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
    this.resumePhase,
    required this.progress,
    required this.attemptCount,
    required this.automaticRetryCount,
    required this.retryAllowed,
    this.retryScheduled = false,
    required this.errorClass,
    required this.messageIds,
  });

  final AccountId accountId;
  final AttachmentJobId jobId;
  final AttachmentJobPhase phase;
  final AttachmentJobPhase? resumePhase;
  final double progress;
  final int attemptCount;
  final int automaticRetryCount;
  final bool retryAllowed;
  final bool retryScheduled;
  final String? errorClass;
  final List<int> messageIds;

  bool get confirmationReconciliationRequired =>
      phase == AttachmentJobPhase.awaitingConfirmation &&
      errorClass == attachmentConfirmationReconciliationRequired;

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

/// Why an upload was refused before it ever became a durable job.
///
/// These were untyped `StateError`s with an English sentence. Every one of
/// them is a distinct, actionable cause — a room the user may not write to, an
/// account whose server no longer matches, a credential that is gone — and
/// collapsing them into one class is why the first field report of a refused
/// gallery pick could only be described as "dispatch failed".
enum AttachmentAdmissionError {
  /// The room, the capability profile or the source refuses this attachment.
  roomUnsupported,

  /// The stored account is gone, or its server is no longer the one the
  /// request was built against.
  accountBinding,

  /// No app password for this account; nothing can be uploaded with it.
  credentialMissing,

  /// The account was switched or re-registered while admission ran.
  accountStale,

  /// The durable store refused the job.
  rejected,

  /// The app never returned to the foreground after the picker closed, so
  /// admission gave up waiting instead of uploading from the background.
  lifecycleTimeout,

  /// The screen that owns the upload was gone before admission finished.
  composerGone,
}

final class AttachmentAdmissionException implements Exception {
  const AttachmentAdmissionException(this.error);

  final AttachmentAdmissionError error;

  @override
  String toString() => 'AttachmentAdmissionException(${error.name})';
}

final class AttachmentService with _AttachmentServiceRuntime {
  static const Duration _accountSuspendDrainTimeout = Duration(seconds: 5);

  factory AttachmentService({
    required AttachmentRepository repository,
    required CredentialVault credentials,
    required ReleaseDurableAttachmentSource releaseSource,
    required HttpAttachmentTransport transport,
    AttachmentIdentifierFactory identifierFactory =
        const UuidAttachmentIdentifierFactory(),
    DateTime Function()? clock,
    WatchAttachmentConfirmationCandidates? watchConfirmationCandidates,
    PersistAttachmentTransition? persistTransition,
    CatchUpAttachmentConfirmation? catchUpConfirmation,
    BeforeAttachmentRoomIdle? beforeRoomIdle,
    BeforeAttachmentTransportFailureCommit? beforeTransportFailureCommit,
    BeforeAttachmentStepPlan? beforeStepPlan,
    CreateAttachmentRetryTimer? createRetryTimer,
    ReportAttachmentUploadDiagnostic reportDiagnostic =
        reportAttachmentUploadDiagnostic,
    List<Duration> credentialRetryDelays = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 10),
      Duration(minutes: 1),
    ],
    List<Duration> confirmationRetryDelays = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 10),
      Duration(minutes: 1),
    ],
    List<Duration> retryDelays = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 10),
      Duration(minutes: 1),
    ],
  }) {
    if (retryDelays.any((delay) => delay < Duration.zero)) {
      throw ArgumentError.value(retryDelays, 'retryDelays');
    }
    if (confirmationRetryDelays.any((delay) => delay < Duration.zero)) {
      throw ArgumentError.value(
        confirmationRetryDelays,
        'confirmationRetryDelays',
      );
    }
    if (credentialRetryDelays.isEmpty ||
        credentialRetryDelays.any((delay) => delay < Duration.zero)) {
      throw ArgumentError.value(credentialRetryDelays, 'credentialRetryDelays');
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
      persistTransition: persistTransition ?? repository.persistTransition,
      catchUpConfirmation: catchUpConfirmation,
      beforeRoomIdle: beforeRoomIdle,
      beforeTransportFailureCommit: beforeTransportFailureCommit,
      beforeStepPlan: beforeStepPlan,
      createRetryTimer: createRetryTimer ?? Timer.new,
      reportDiagnostic: reportDiagnostic,
      credentialRetryDelays: List<Duration>.unmodifiable(credentialRetryDelays),
      confirmationRetryDelays: List<Duration>.unmodifiable(
        confirmationRetryDelays,
      ),
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
    required this._persistTransition,
    required this._catchUpConfirmation,
    required this._beforeRoomIdle,
    required this._beforeTransportFailureCommit,
    required this._beforeStepPlan,
    required this._createRetryTimer,
    required this._reportDiagnostic,
    required this._credentialRetryDelays,
    required this._confirmationRetryDelays,
    required this._retryDelays,
  });

  @override
  final AttachmentRepository _repository;
  @override
  final CredentialVault _credentials;
  @override
  final ReleaseDurableAttachmentSource _releaseSource;
  @override
  final HttpAttachmentTransport _transport;
  @override
  final AttachmentIdentifierFactory _identifierFactory;
  @override
  final DateTime Function() _clock;
  @override
  final WatchAttachmentConfirmationCandidates _watchConfirmationCandidates;
  @override
  final PersistAttachmentTransition _persistTransition;
  @override
  final CatchUpAttachmentConfirmation? _catchUpConfirmation;
  @override
  final BeforeAttachmentRoomIdle? _beforeRoomIdle;
  @override
  final BeforeAttachmentTransportFailureCommit? _beforeTransportFailureCommit;
  @override
  final BeforeAttachmentStepPlan? _beforeStepPlan;
  @override
  final CreateAttachmentRetryTimer _createRetryTimer;
  @override
  final ReportAttachmentUploadDiagnostic _reportDiagnostic;
  @override
  final List<Duration> _credentialRetryDelays;
  @override
  final List<Duration> _confirmationRetryDelays;
  @override
  final List<Duration> _retryDelays;
  @override
  final _AsyncMutex _stateMutex = _AsyncMutex();
  @override
  final Map<_AttachmentRoomKey, Future<void>> _roomRuns = {};
  @override
  final Set<_AttachmentRoomKey> _roomRerunRequests = {};
  @override
  final Map<_AttachmentRoomKey, Timer> _retryTimers = {};
  @override
  final Map<_AttachmentRoomKey, DateTime> _retryDeadlines = {};
  @override
  final Map<AttachmentPersistenceKey, int> _credentialRetryCounts = {};
  @override
  final Map<AttachmentPersistenceKey, Future<void>> _confirmationCatchUps = {};
  @override
  final Map<AttachmentPersistenceKey, Timer> _confirmationRetryTimers = {};
  @override
  final Map<AttachmentPersistenceKey, int> _confirmationRetryCounts = {};
  @override
  final Map<AttachmentPersistenceKey, AttachmentVerifiedSource>
  _verifiedSources = {};
  @override
  final Map<AttachmentPersistenceKey, AttachmentCancellationController>
  _cancellations = {};
  @override
  final Map<AttachmentPersistenceKey, Completer<void>> _terminalSourceReleases =
      {};
  @override
  final Set<AccountId> _suspendedAccounts = {};
  final Map<AccountId, Future<void>> _accountSuspensions = {};

  @override
  late final Future<void> _ready;
  @override
  Future<void> _startupMaintenance = Future<void>.value();
  @override
  StreamSubscription<AttachmentConfirmationSnapshot>? _confirmationSubscription;
  @override
  Future<void> _confirmationTail = Future<void>.value();
  @override
  AttachmentRuntimeSnapshot _snapshot = AttachmentRuntimeSnapshot(
    accounts: const {},
  );
  @override
  Map<AttachmentPersistenceKey, AttachmentExecutionMetadata> _metadata = {};
  @override
  final Map<AttachmentPersistenceKey, DateTime> _uploadStartedAt = {};
  @override
  bool _closed = false;

  Future<void> get ready => _ready;

  /// Persists an account-wide stop before its credential is revoked, aborts
  /// active requests, and waits a bounded time for their cleanup paths.
  Future<void> suspendAccount(AccountId accountId) {
    final existing = _accountSuspensions[accountId];
    if (existing != null) {
      return existing;
    }
    _suspendedAccounts.add(accountId);
    final operation = _suspendAccount(accountId);
    _accountSuspensions[accountId] = operation;
    return operation;
  }

  Future<void> _suspendAccount(AccountId accountId) async {
    await _ready;
    await _stateMutex.protect(() async {
      final account = _snapshot.accounts[accountId];
      if (account == null) {
        return;
      }
      final suspended = account.copyWith(lane: AttachmentAccountLane.suspended);
      await _repository.persistAccountState(
        account: suspended,
        updatedAt: _clock().toUtc(),
      );
      _snapshot = _snapshot.replaceAccount(suspended);
    });
    for (final entry in _retryTimers.entries.toList(growable: false)) {
      if (entry.key.accountId == accountId) {
        entry.value.cancel();
        _retryTimers.remove(entry.key);
        _retryDeadlines.remove(entry.key);
      }
    }
    for (final entry in _confirmationRetryTimers.entries.toList(
      growable: false,
    )) {
      if (entry.key.accountId == accountId.value) {
        entry.value.cancel();
        _confirmationRetryTimers.remove(entry.key);
      }
    }
    for (final entry in _cancellations.entries.toList(growable: false)) {
      if (entry.key.accountId == accountId.value) {
        entry.value.cancel();
      }
    }
    _roomRerunRequests.removeWhere((room) => room.accountId == accountId);
    final active = <Future<void>>[
      ..._roomRuns.entries
          .where((entry) => entry.key.accountId == accountId)
          .map((entry) => entry.value),
      ..._confirmationCatchUps.entries
          .where((entry) => entry.key.accountId == accountId.value)
          .map((entry) => entry.value),
    ];
    if (active.isNotEmpty) {
      final settled = active.map((operation) async {
        try {
          await operation;
        } on Object {
          // The durable request remains the restart recovery input.
        }
      });
      await Future.wait<void>(
        settled,
      ).timeout(_accountSuspendDrainTimeout, onTimeout: () => const <void>[]);
    }
  }

  Future<DurableAttachmentSession> enqueue(
    AttachmentEnqueueRequest request,
  ) async {
    await _ready;
    _ensureOpen();
    _ensureAccountActive(request.accountId);
    if (!request.roomCanWrite ||
        !request.profile.supports(request.metadata) ||
        !request.metadata.supportsSource(request.source)) {
      throw const AttachmentAdmissionException(
        AttachmentAdmissionError.roomUnsupported,
      );
    }
    final storedAccount = await _repository.getAccount(request.accountId.value);
    if (storedAccount == null ||
        ServerBase.parse(storedAccount.serverUrl) != request.server) {
      throw const AttachmentAdmissionException(
        AttachmentAdmissionError.accountBinding,
      );
    }
    final appPassword = await _credentials.readAppPassword(
      request.accountId.value,
    );
    if (appPassword == null || appPassword.isEmpty) {
      throw const AttachmentAdmissionException(
        AttachmentAdmissionError.credentialMissing,
      );
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
        _ensureAccountActive(request.accountId);
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
            throw const AttachmentAdmissionException(
              AttachmentAdmissionError.accountStale,
            );
          }
          if (account.lane != AttachmentAccountLane.ready) {
            throw const AttachmentAdmissionException(
              AttachmentAdmissionError.accountStale,
            );
          }
          if (request.credentialGeneration != account.credentialGeneration ||
              request.capabilityGeneration != account.capabilityGeneration) {
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
          throw const AttachmentAdmissionException(
            AttachmentAdmissionError.rejected,
          );
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
        _uploadStartedAt[key] = DateTime.now();
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
      _clearConfirmationCatchUp(key);
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
    _ensureAccountActive(accountId);
    final key = _jobKey(accountId, jobId);
    _AttachmentRoomKey? roomKey;
    var retryConfirmation = false;
    await _stateMutex.protect(() async {
      _ensureAccountActive(accountId);
      final job = _snapshot.accounts[accountId]?.jobs[jobId];
      if (job == null) {
        throw StateError('Attachment job does not exist');
      }
      if (job.phase == AttachmentJobPhase.awaitingConfirmation &&
          job.errorClass == attachmentConfirmationReconciliationRequired) {
        final account = _snapshot.accounts[accountId]!;
        final jobs = Map<AttachmentJobId, AttachmentJob>.of(account.jobs);
        final updatedJob = job.copyWith(errorClass: null);
        jobs[jobId] = updatedJob;
        final updatedAccount = account.copyWith(jobs: jobs);
        final updatedMetadata = _metadata[key]!.copyWith(
          automaticRetryCount: 0,
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
        retryConfirmation = true;
        return;
      }
      if (job.phase != AttachmentJobPhase.retryable &&
          job.phase != AttachmentJobPhase.cleanupFailed) {
        throw StateError('Attachment job is not retryable');
      }
      final metadata = _metadata[key]!;
      final updated = metadata.copyWith(
        automaticRetryCount: 0,
        nextAttemptAt: null,
      );
      await _persistCurrentJob(key, updated);
      _metadata[key] = updated;
      roomKey = _AttachmentRoomKey(accountId, job.draft.roomToken);
    });
    _ensureAccountActive(accountId);
    if (retryConfirmation) {
      _clearConfirmationCatchUp(key);
      final active = _confirmationCatchUps[key];
      if (active != null) {
        await active;
      }
      _queueConfirmationCatchUp(key);
      return;
    }
    final retryRoom = roomKey!;
    _retryTimers.remove(retryRoom)?.cancel();
    _retryDeadlines.remove(retryRoom);
    await _scheduleRoom(retryRoom);
  }

  /// Gives every upload that ran out of automatic retries, or is still
  /// waiting for its next one, a fresh attempt now.
  ///
  /// The automatic retries stop after about a minute, which is right for a
  /// server that keeps failing but wrong for a phone that simply had no
  /// network: a picture sent in a tunnel would sit on "could not be sent"
  /// until the sender found the retry button. A connectivity hint or a
  /// resumed app is the moment to try again; the probe still has to succeed,
  /// so a false hint costs one more failed attempt and nothing else.
  Future<void> resumeRetries() async {
    await _ready;
    if (_closed) {
      return;
    }
    final rooms = <_AttachmentRoomKey>{};
    await _stateMutex.protect(() async {
      for (final account in _snapshot.accounts.values) {
        if (_suspendedAccounts.contains(account.accountId)) {
          continue;
        }
        for (final job in account.jobs.values) {
          if (job.phase != AttachmentJobPhase.retryable &&
              job.phase != AttachmentJobPhase.cleanupFailed) {
            continue;
          }
          final key = _jobKey(account.accountId, job.jobId);
          final metadata = _metadata[key];
          if (metadata == null || metadata.automaticRetryCount == 0) {
            continue;
          }
          final updated = metadata.copyWith(
            automaticRetryCount: 0,
            nextAttemptAt: null,
          );
          await _persistCurrentJob(key, updated);
          _metadata[key] = updated;
          rooms.add(_AttachmentRoomKey(account.accountId, job.draft.roomToken));
        }
      }
    });
    for (final room in rooms) {
      _retryTimers.remove(room)?.cancel();
      _retryDeadlines.remove(room);
      await _scheduleRoom(room);
    }
  }

  Future<void> completeReauthentication({
    required AccountId accountId,
    required int credentialGeneration,
    required int capabilityGeneration,
  }) async {
    await _ready;
    _ensureOpen();
    _ensureAccountActive(accountId);
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

  void _ensureAccountActive(AccountId accountId) {
    if (_suspendedAccounts.contains(accountId)) {
      throw StateError('Attachment account is suspended');
    }
  }

  Future<void> reconcileConfirmations({
    required AccountId accountId,
    required Iterable<AttachmentMessageConfirmation> confirmations,
  }) async {
    await _ready;
    _ensureOpen();
    _ensureAccountActive(accountId);
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
      _clearConfirmationCatchUp(key);
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
    await _startupMaintenance;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _retryDeadlines.clear();
    _credentialRetryCounts.clear();
    for (final timer in _confirmationRetryTimers.values) {
      timer.cancel();
    }
    _confirmationRetryTimers.clear();
    _roomRerunRequests.clear();
    for (final cancellation in _cancellations.values) {
      cancellation.cancel();
    }
    await Future.wait<void>(_roomRuns.values.toList(growable: false));
    await Future.wait<void>(
      _confirmationCatchUps.values.toList(growable: false),
    );
    _confirmationRetryCounts.clear();
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
}
