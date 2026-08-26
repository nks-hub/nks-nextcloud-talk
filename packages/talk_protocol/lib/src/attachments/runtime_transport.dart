part of 'runtime.dart';

AttachmentRuntimeResult _planUpload(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentRequestId requestId,
) {
  final context = _context(job, requestId);
  AttachmentDavRequest request;
  if (job.draft.uploadMode == AttachmentUploadMode.normal) {
    request = AttachmentDavRequest.normalPut(
      context: context,
      davUserId: job.davUserId,
      remotePath: job.remoteTemporaryPath!,
      source: job.draft.source,
    );
  } else if (!job.chunkCollectionReady) {
    request = AttachmentDavRequest.chunkMkcol(
      context: context,
      davUserId: job.davUserId,
      uploadSessionId: job.draft.uploadSessionId!,
    );
  } else if (!job.chunkManifestLoaded) {
    request = AttachmentDavRequest.chunkPropfind(
      context: context,
      davUserId: job.davUserId,
      uploadSessionId: job.draft.uploadSessionId!,
    );
  } else {
    final missing = _firstMissingChunk(job);
    if (missing != null) {
      request = AttachmentDavRequest.chunkPut(
        context: context,
        davUserId: job.davUserId,
        uploadSessionId: job.draft.uploadSessionId!,
        source: job.draft.source,
        range: missing,
      );
    } else {
      request = AttachmentDavRequest.chunkMove(
        context: context,
        davUserId: job.davUserId,
        uploadSessionId: job.draft.uploadSessionId!,
        remotePath: job.remoteTemporaryPath!,
        totalLength: job.draft.source.byteLength,
      );
    }
  }
  return _startRequest(
    snapshot,
    account,
    job,
    request,
    AttachmentJobPhase.uploading,
    AttachmentRuntimeOutcome.uploading,
  );
}

AttachmentRuntimeResult _planCleanup(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentRequestId requestId,
) {
  if (!job.cleanupChunkSession && !job.cleanupDraftFile) {
    return _replaceJob(
      snapshot,
      account,
      job.copyWith(phase: AttachmentJobPhase.cancelled, errorClass: null),
      AttachmentRuntimeOutcome.cancelled,
    );
  }
  final context = _context(job, requestId);
  final request = job.cleanupChunkSession
      ? AttachmentDavRequest.cleanupChunkSession(
          context: context,
          davUserId: job.davUserId,
          uploadSessionId: job.draft.uploadSessionId!,
        )
      : AttachmentDavRequest.cleanupDraftFile(
          context: context,
          davUserId: job.davUserId,
          remotePath: job.remoteTemporaryPath!,
        );
  return _startRequest(
    snapshot,
    account,
    job,
    request,
    AttachmentJobPhase.cancelling,
    AttachmentRuntimeOutcome.cancelling,
  );
}

AttachmentRuntimeResult _applyProbeResponse(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentProbeResponse response,
) {
  return switch (response.classification) {
    AttachmentProbeClassification.confirmed => _replaceJob(
      snapshot,
      account,
      job.copyWith(
        phase: AttachmentJobPhase.draftResolved,
        remoteDraftFolder: response.folder!,
        remoteTemporaryPath: response.folder!.append(
          job.draft.stableTemporaryName,
        ),
        inFlightRequest: null,
        errorClass: null,
      ),
      AttachmentRuntimeOutcome.draftResolved,
    ),
    AttachmentProbeClassification.reauthenticationRequired =>
      _reauthenticationRequired(
        snapshot,
        account,
        job,
        AttachmentJobPhase.localPrepared,
      ),
    AttachmentProbeClassification.deterministicFailure => _replaceJob(
      snapshot,
      account,
      job.copyWith(
        phase: AttachmentJobPhase.failed,
        inFlightRequest: null,
        errorClass: 'probe-rejected',
      ),
      AttachmentRuntimeOutcome.failed,
    ),
    AttachmentProbeClassification.transientFailure => _replaceJob(
      snapshot,
      account,
      job.copyWith(
        phase: AttachmentJobPhase.retryable,
        resumePhase: AttachmentJobPhase.localPrepared,
        inFlightRequest: null,
        errorClass: 'probe-transient',
      ),
      AttachmentRuntimeOutcome.retryable,
    ),
  };
}

AttachmentRuntimeResult _applyDavResponse(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentDavResponse response,
) {
  switch (response.classification) {
    case AttachmentDavClassification.reauthenticationRequired:
      return _reauthenticationRequired(
        snapshot,
        account,
        job,
        _isCleanupStep(response.request.step)
            ? AttachmentJobPhase.cancelling
            : _resumePhaseFor(response.request.step),
      );
    case AttachmentDavClassification.transientFailure:
      if (_isCleanupStep(response.request.step)) {
        return _replaceJob(
          snapshot,
          account,
          job.copyWith(
            phase: AttachmentJobPhase.cleanupFailed,
            inFlightRequest: null,
            errorClass: 'cleanup-transient',
          ),
          AttachmentRuntimeOutcome.cleanupFailed,
        );
      }
      return _replaceJob(
        snapshot,
        account,
        job.copyWith(
          phase: AttachmentJobPhase.retryable,
          resumePhase: _resumePhaseFor(response.request.step),
          inFlightRequest: null,
          errorClass: 'dav-transient',
        ),
        AttachmentRuntimeOutcome.retryable,
      );
    case AttachmentDavClassification.deterministicFailure:
    case AttachmentDavClassification.quotaExceeded:
    case AttachmentDavClassification.permissionDenied:
      if (_isCleanupStep(response.request.step)) {
        return _replaceJob(
          snapshot,
          account,
          job.copyWith(
            phase: AttachmentJobPhase.cleanupFailed,
            inFlightRequest: null,
            errorClass: 'cleanup-rejected',
          ),
          AttachmentRuntimeOutcome.cleanupFailed,
        );
      }
      return _replaceJob(
        snapshot,
        account,
        job.copyWith(
          phase: AttachmentJobPhase.failed,
          inFlightRequest: null,
          cleanupChunkSession:
              job.draft.uploadMode == AttachmentUploadMode.chunked,
          cleanupDraftFile: job.remoteTemporaryPath != null,
          errorClass: switch (response.classification) {
            AttachmentDavClassification.quotaExceeded => 'dav-quota-exceeded',
            AttachmentDavClassification.permissionDenied =>
              'dav-permission-denied',
            _ => 'dav-rejected',
          },
        ),
        AttachmentRuntimeOutcome.failed,
      );
    case AttachmentDavClassification.success:
      break;
  }

  switch (response.request.step) {
    case AttachmentRequestStep.normalPut:
    case AttachmentRequestStep.chunkMove:
      return _replaceJob(
        snapshot,
        account,
        job.copyWith(
          phase: AttachmentJobPhase.uploaded,
          inFlightRequest: null,
          errorClass: null,
        ),
        AttachmentRuntimeOutcome.uploaded,
      );
    case AttachmentRequestStep.chunkMkcol:
      return _replaceJob(
        snapshot,
        account,
        job.copyWith(
          phase: AttachmentJobPhase.uploading,
          chunkCollectionReady: true,
          inFlightRequest: null,
          errorClass: null,
        ),
        AttachmentRuntimeOutcome.uploading,
      );
    case AttachmentRequestStep.chunkPropfind:
      final manifest = response.manifest!;
      manifest.validateAgainst(
        policy: job.draft.policy,
        fileSize: job.draft.source.byteLength,
      );
      return _replaceJob(
        snapshot,
        account,
        job.copyWith(
          phase: AttachmentJobPhase.uploading,
          chunkManifestLoaded: true,
          verifiedChunks: manifest.chunks,
          inFlightRequest: null,
          errorClass: null,
        ),
        AttachmentRuntimeOutcome.uploading,
      );
    case AttachmentRequestStep.chunkPut:
      final values = <DavChunkRange>[
        ...job.verifiedChunks,
        response.request.chunkRange!,
      ]..sort();
      return _replaceJob(
        snapshot,
        account,
        job.copyWith(
          phase: AttachmentJobPhase.uploading,
          verifiedChunks: values,
          inFlightRequest: null,
          errorClass: null,
        ),
        AttachmentRuntimeOutcome.uploading,
      );
    case AttachmentRequestStep.cleanupChunkSession:
    case AttachmentRequestStep.cleanupDraftFile:
      final chunk =
          response.request.step == AttachmentRequestStep.cleanupChunkSession
          ? false
          : job.cleanupChunkSession;
      final draft =
          response.request.step == AttachmentRequestStep.cleanupDraftFile
          ? false
          : job.cleanupDraftFile;
      final done = !chunk && !draft;
      return _replaceJob(
        snapshot,
        account,
        job.copyWith(
          phase: done
              ? AttachmentJobPhase.cancelled
              : AttachmentJobPhase.cancelling,
          inFlightRequest: null,
          cleanupChunkSession: chunk,
          cleanupDraftFile: draft,
          errorClass: null,
        ),
        done
            ? AttachmentRuntimeOutcome.cancelled
            : AttachmentRuntimeOutcome.cancelling,
      );
    case AttachmentRequestStep.probe:
    case AttachmentRequestStep.finalize:
      _runtimeFailure(r'$.response.request.step');
  }
}

AttachmentRuntimeResult _applyFinalizeResponse(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentFinalizeResponse response,
) {
  return switch (response.classification) {
    AttachmentFinalizeClassification.accepted ||
    AttachmentFinalizeClassification.ambiguous => _replaceJob(
      snapshot,
      account,
      job.copyWith(
        phase: AttachmentJobPhase.awaitingConfirmation,
        inFlightRequest: null,
        finalizationDispatched: true,
        messageIds: const <int>[],
        errorClass:
            response.classification == AttachmentFinalizeClassification.accepted
            ? null
            : 'ambiguous-finalize-response',
      ),
      AttachmentRuntimeOutcome.awaitingConfirmation,
    ),
    AttachmentFinalizeClassification.reauthenticationRequired =>
      _reauthenticationRequired(
        snapshot,
        account,
        job,
        AttachmentJobPhase.uploaded,
      ),
    AttachmentFinalizeClassification.deterministicFailure => _replaceJob(
      snapshot,
      account,
      job.copyWith(
        phase: AttachmentJobPhase.failed,
        inFlightRequest: null,
        finalizationDispatched: false,
        cleanupChunkSession:
            job.draft.uploadMode == AttachmentUploadMode.chunked,
        cleanupDraftFile: true,
        errorClass: 'finalize-rejected',
      ),
      AttachmentRuntimeOutcome.failed,
    ),
  };
}

AttachmentRuntimeResult _reauthenticationRequired(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentJobPhase resumePhase,
) {
  final updated = job.copyWith(
    phase: AttachmentJobPhase.retryable,
    resumePhase: resumePhase,
    inFlightRequest: null,
    finalizationDispatched: false,
    errorClass: 'reauthentication-required',
  );
  final jobs = Map<AttachmentJobId, AttachmentJob>.of(account.jobs);
  jobs[job.jobId] = updated;
  return _replaceAccount(
    snapshot,
    account.copyWith(
      lane: AttachmentAccountLane.reauthenticationRequired,
      jobs: jobs,
    ),
    AttachmentRuntimeOutcome.reauthenticationRequired,
    jobId: job.jobId,
  );
}

AttachmentRuntimeResult _startRequest(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentRequest request,
  AttachmentJobPhase phase,
  AttachmentRuntimeOutcome outcome,
) => _replaceJob(
  snapshot,
  account,
  job.copyWith(
    phase: phase,
    resumePhase: null,
    inFlightRequest: request,
    attemptCount: job.attemptCount + 1,
    errorClass: null,
  ),
  outcome,
  request: request,
);

AttachmentRequestContext _context(
  AttachmentJob job,
  AttachmentRequestId requestId,
) => AttachmentRequestContext(
  accountId: job.accountId,
  requestId: requestId,
  jobId: job.jobId,
  server: job.server,
  roomToken: job.draft.roomToken,
  capabilityGeneration: job.capabilityGeneration,
  contractRevision: job.replayContractRevision,
);

AttachmentJob _sourceMismatch(AttachmentJob job) => job.copyWith(
  phase: AttachmentJobPhase.failed,
  resumePhase: null,
  inFlightRequest: null,
  cleanupChunkSession:
      job.draft.uploadMode == AttachmentUploadMode.chunked &&
      job.remoteTemporaryPath != null,
  cleanupDraftFile: job.remoteTemporaryPath != null,
  errorClass: 'source-mismatch',
);

DavChunkRange? _firstMissingChunk(AttachmentJob job) {
  var lower = 0;
  var upper = job.verifiedChunks.length;
  while (lower < upper) {
    final middle = lower + ((upper - lower) >> 1);
    final ordinal =
        job.verifiedChunks[middle].start ~/ job.draft.policy.chunkSizeBytes;
    if (ordinal == middle) {
      lower = middle + 1;
    } else {
      upper = middle;
    }
  }
  final chunkCount = job.draft.policy.chunkCountFor(
    job.draft.source.byteLength,
  );
  if (lower >= chunkCount) {
    return null;
  }
  return job.draft.policy.chunkAt(
    lower * job.draft.policy.chunkSizeBytes,
    fileSize: job.draft.source.byteLength,
  );
}

bool _confirmationMatches(
  AttachmentJob job,
  AttachmentMessageConfirmation confirmation,
) =>
    confirmation.messageId > 0 &&
    confirmation.accountId == job.accountId &&
    confirmation.server == job.server &&
    confirmation.roomToken == job.draft.roomToken &&
    confirmation.referenceId == job.draft.referenceId.value &&
    confirmation.systemMessage.isEmpty &&
    confirmation.hasFileRichObject &&
    confirmation.messageType == job.draft.expectedMessageType &&
    _confirmationScopeMatches(job, confirmation);

bool _confirmationScopeMatches(
  AttachmentJob job,
  AttachmentMessageConfirmation confirmation,
) {
  final threadId = job.draft.metadata.threadId;
  if (threadId != null) {
    return confirmation.threadId == threadId &&
        confirmation.parentMessageId == threadId;
  }
  final replyTo = job.draft.metadata.replyTo;
  return replyTo == null || confirmation.parentMessageId == replyTo;
}

bool _authorityMatches(
  AttachmentAccountState account,
  AttachmentAuthority authority,
) =>
    authority.accountId == account.accountId &&
    authority.server == account.server &&
    authority.capabilityGeneration == account.capabilityGeneration &&
    authority.replayContractRevision == attachmentReplayContractRevision;

bool _jobAuthorityMatches(
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentAuthority authority,
) =>
    _authorityMatches(account, authority) &&
    job.accountId == authority.accountId &&
    job.server == authority.server &&
    job.capabilityGeneration == authority.capabilityGeneration &&
    job.replayContractRevision == authority.replayContractRevision &&
    job.draft.roomToken == authority.roomToken &&
    authority.roomCanWrite &&
    authority.profile.supports(job.draft.metadata);

bool _requestIdInUse(
  AttachmentAccountState account,
  AttachmentRequestId requestId,
) => account.jobs.values.any(
  (job) => job.inFlightRequest?.requestId == requestId,
);

bool _finalizationBlocked(AttachmentAccountState account, AttachmentJob job) {
  for (final other in account.jobs.values) {
    if (other.jobId == job.jobId ||
        other.draft.roomToken != job.draft.roomToken) {
      continue;
    }
    if (other.phase == AttachmentJobPhase.finalizing) {
      return true;
    }
    if (other.draft.enqueueSequence < job.draft.enqueueSequence &&
        !<AttachmentJobPhase>{
          AttachmentJobPhase.completed,
          AttachmentJobPhase.failed,
          AttachmentJobPhase.cancelled,
        }.contains(other.phase)) {
      return true;
    }
  }
  return false;
}

AttachmentJobPhase _resumePhaseFor(AttachmentRequestStep step) =>
    switch (step) {
      AttachmentRequestStep.probe => AttachmentJobPhase.localPrepared,
      AttachmentRequestStep.normalPut ||
      AttachmentRequestStep.chunkMkcol ||
      AttachmentRequestStep.chunkPropfind ||
      AttachmentRequestStep.chunkPut ||
      AttachmentRequestStep.chunkMove => AttachmentJobPhase.draftResolved,
      AttachmentRequestStep.finalize => AttachmentJobPhase.uploaded,
      AttachmentRequestStep.cleanupChunkSession ||
      AttachmentRequestStep.cleanupDraftFile => AttachmentJobPhase.cancelling,
    };

bool _isCleanupStep(AttachmentRequestStep step) =>
    step == AttachmentRequestStep.cleanupChunkSession ||
    step == AttachmentRequestStep.cleanupDraftFile;

AttachmentRuntimeResult _replaceJob(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentJob job,
  AttachmentRuntimeOutcome outcome, {
  AttachmentRequest? request,
}) {
  final jobs = Map<AttachmentJobId, AttachmentJob>.of(account.jobs);
  jobs[job.jobId] = job;
  return _replaceAccount(
    snapshot,
    account.copyWith(jobs: jobs),
    outcome,
    jobId: job.jobId,
    request: request,
  );
}

AttachmentRuntimeResult _replaceAccount(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentAccountState account,
  AttachmentRuntimeOutcome outcome, {
  AttachmentJobId? jobId,
  AttachmentRequest? request,
}) => AttachmentRuntimeResult._(
  outcome: outcome,
  jobId: jobId,
  request: request,
  plan: AttachmentRuntimePlan._(snapshot, snapshot.replaceAccount(account)),
);

AttachmentRuntimeResult _result(
  AttachmentRuntimeOutcome outcome, {
  AttachmentJobId? jobId,
}) => AttachmentRuntimeResult._(
  outcome: outcome,
  jobId: jobId,
  request: null,
  plan: null,
);

_AttachmentJobBinding? _job(
  AttachmentRuntimeSnapshot snapshot,
  AccountId accountId,
  AttachmentJobId jobId,
) {
  final account = snapshot.accounts[accountId];
  final job = account?.jobs[jobId];
  return account == null || job == null
      ? null
      : _AttachmentJobBinding(account, job);
}

Never _runtimeFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentRuntime, path);

final class _AttachmentJobBinding {
  const _AttachmentJobBinding(this.account, this.job);

  final AttachmentAccountState account;
  final AttachmentJob job;
}
