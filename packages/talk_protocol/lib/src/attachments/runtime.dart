import '../chat/confirmation_scope.dart';
import '../chat/models.dart';
import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';
import 'profile.dart';
import 'request.dart';
import 'response.dart';
import 'state.dart';

part 'runtime_transport.dart';

enum AttachmentRuntimeOutcome {
  admitted,
  probing,
  draftResolved,
  uploading,
  uploaded,
  finalizing,
  awaitingConfirmation,
  completed,
  retryable,
  failed,
  sourceMismatch,
  cancelling,
  cancelled,
  cleanupFailed,
  reauthenticationRequired,
  reauthenticationSucceeded,
  noMatch,
  ambiguousMatch,
  conflictAfterCompletion,
  unchanged,
  rejected,
}

enum AttachmentTransportBodyState { notSent, possiblySent }

final class AttachmentAuthority {
  AttachmentAuthority({
    required this.accountId,
    required this.server,
    required this.capabilityGeneration,
    required this.profile,
    required this.replayContractRevision,
    required this.roomCanWrite,
    required this.roomToken,
  }) {
    if (capabilityGeneration < 1 ||
        replayContractRevision.isEmpty ||
        replayContractRevision.length > 128) {
      _runtimeFailure(r'$.authority');
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final int capabilityGeneration;
  final AttachmentCapabilityProfile profile;
  final String replayContractRevision;
  final bool roomCanWrite;
  final ConversationToken roomToken;

  @override
  String toString() =>
      'AttachmentAuthority(capabilityGeneration: $capabilityGeneration, '
      'roomCanWrite: $roomCanWrite, sensitive: <redacted>)';
}

final class AttachmentMessageConfirmation {
  const AttachmentMessageConfirmation({
    required this.accountId,
    required this.server,
    required this.messageId,
    required this.roomToken,
    required this.referenceId,
    required this.systemMessage,
    required this.messageType,
    required this.hasFileRichObject,
    this.parentMessageId,
    this.parentRoomToken,
    this.parentThreadId,
    this.parentDeleted = false,
    this.replyToMessageId,
    this.replyToRoomToken,
    this.threadId,
  });

  factory AttachmentMessageConfirmation.fromMessage(
    ChatMessage message, {
    required AccountId accountId,
    required ServerBase server,
  }) {
    final scope = ChatConfirmationScope.fromMessage(message);
    return AttachmentMessageConfirmation(
      accountId: accountId,
      server: server,
      messageId: message.messageId,
      roomToken: message.roomToken,
      referenceId: message.referenceId,
      systemMessage: message.systemMessage,
      messageType: message.messageType,
      hasFileRichObject: message.messageParameters.values.any(
        (parameter) => parameter.type == 'file',
      ),
      parentMessageId: scope.parentMessageId,
      parentRoomToken: scope.parentRoomToken,
      parentThreadId: scope.parentThreadId,
      parentDeleted: scope.parentDeleted,
      replyToMessageId: scope.replyToMessageId,
      replyToRoomToken: scope.replyToRoomToken,
      threadId: scope.threadId,
    );
  }

  final AccountId accountId;
  final ServerBase server;
  final int messageId;
  final ConversationToken roomToken;
  final String referenceId;
  final String systemMessage;
  final String messageType;
  final bool hasFileRichObject;
  final int? parentMessageId;
  final ConversationToken? parentRoomToken;
  final int? parentThreadId;
  final bool parentDeleted;
  final int? replyToMessageId;
  final String? replyToRoomToken;
  final int? threadId;

  @override
  String toString() => 'AttachmentMessageConfirmation(<redacted>)';
}

final class AttachmentRuntimePlan {
  AttachmentRuntimePlan._(this._source, this._candidate);

  final AttachmentRuntimeSnapshot _source;
  final AttachmentRuntimeSnapshot _candidate;
  bool _consumed = false;

  AttachmentRuntimeSnapshot commit(AttachmentRuntimeSnapshot current) {
    _consume(current);
    return _candidate;
  }

  AttachmentRuntimeSnapshot discard(AttachmentRuntimeSnapshot current) {
    _consume(current);
    return current;
  }

  void _consume(AttachmentRuntimeSnapshot current) {
    if (_consumed || !identical(current, _source)) {
      _runtimeFailure(r'$.runtimePlan');
    }
    _consumed = true;
  }

  @override
  String toString() => 'AttachmentRuntimePlan()';
}

final class AttachmentRuntimeResult {
  const AttachmentRuntimeResult._({
    required this.outcome,
    required this.jobId,
    required this.request,
    required this.plan,
  });

  final AttachmentRuntimeOutcome outcome;
  final AttachmentJobId? jobId;
  final AttachmentRequest? request;
  final AttachmentRuntimePlan? plan;

  bool get canCommit => plan != null;

  @override
  String toString() =>
      'AttachmentRuntimeResult(outcome: ${outcome.name}, '
      'hasRequest: ${request != null})';
}

AttachmentRuntimeResult admitAttachmentJob(
  AttachmentRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required AttachmentAuthority authority,
  required DavUserId davUserId,
  required AttachmentJobDraft draft,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      account.lane != AttachmentAccountLane.ready ||
      !_authorityMatches(account, authority) ||
      !authority.roomCanWrite ||
      authority.roomToken != draft.roomToken ||
      !authority.profile.supports(draft.metadata) ||
      account.jobs.containsKey(draft.jobId) ||
      account.jobs.values.any(
        (job) => job.draft.referenceId == draft.referenceId,
      ) ||
      account.jobs.values.any(
        (job) =>
            job.draft.roomToken == draft.roomToken &&
            job.draft.enqueueSequence >= draft.enqueueSequence,
      )) {
    return _result(AttachmentRuntimeOutcome.rejected, jobId: draft.jobId);
  }
  final job = AttachmentJob(
    accountId: accountId,
    server: account.server,
    capabilityGeneration: authority.capabilityGeneration,
    replayContractRevision: authority.replayContractRevision,
    davUserId: davUserId,
    draft: draft,
    phase: AttachmentJobPhase.localPrepared,
    resumePhase: null,
    remoteDraftFolder: null,
    remoteTemporaryPath: null,
    chunkCollectionReady: false,
    chunkManifestLoaded: false,
    verifiedChunks: const <DavChunkRange>[],
    inFlightRequest: null,
    attemptCount: 0,
    finalizationDispatched: false,
    cleanupChunkSession: false,
    cleanupDraftFile: false,
    messageIds: const <int>[],
    errorClass: null,
  );
  return _replaceJob(snapshot, account, job, AttachmentRuntimeOutcome.admitted);
}

AttachmentRuntimeResult planNextAttachmentStep(
  AttachmentRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required AttachmentJobId jobId,
  required AttachmentAuthority authority,
  required AttachmentRequestId requestId,
  AttachmentSourceObservation? sourceObservation,
}) {
  final binding = _job(snapshot, accountId, jobId);
  if (binding == null ||
      binding.account.lane != AttachmentAccountLane.ready ||
      !_jobAuthorityMatches(binding.account, binding.job, authority) ||
      binding.job.inFlightRequest != null ||
      _requestIdInUse(binding.account, requestId)) {
    return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
  }

  var job = binding.job;
  if (job.phase == AttachmentJobPhase.retryable) {
    job = job.copyWith(phase: job.resumePhase!, resumePhase: null);
  } else if (job.phase == AttachmentJobPhase.cleanupFailed) {
    job = job.copyWith(phase: AttachmentJobPhase.cancelling);
  }

  switch (job.phase) {
    case AttachmentJobPhase.localPrepared:
      final request = AttachmentProbeRequest(
        context: _context(job, requestId),
        fileNames: <String>[job.draft.source.displayName],
      );
      return _startRequest(
        snapshot,
        binding.account,
        job,
        request,
        AttachmentJobPhase.probing,
        AttachmentRuntimeOutcome.probing,
      );
    case AttachmentJobPhase.draftResolved:
    case AttachmentJobPhase.uploading:
      if (sourceObservation == null) {
        return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
      }
      if (!sourceObservation.matches(job.draft.source)) {
        return _replaceJob(
          snapshot,
          binding.account,
          _sourceMismatch(job),
          AttachmentRuntimeOutcome.sourceMismatch,
        );
      }
      return _planUpload(snapshot, binding.account, job, requestId);
    case AttachmentJobPhase.uploaded:
      if (_finalizationBlocked(binding.account, job)) {
        return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
      }
      final request = AttachmentFinalizeRequest(
        context: _context(job, requestId),
        remoteTemporaryPath: job.remoteTemporaryPath!,
        source: job.draft.source,
        referenceId: job.draft.referenceId,
        metadata: job.draft.metadata,
      );
      return _startRequest(
        snapshot,
        binding.account,
        job,
        request,
        AttachmentJobPhase.finalizing,
        AttachmentRuntimeOutcome.finalizing,
      );
    case AttachmentJobPhase.cancelling:
      return _planCleanup(snapshot, binding.account, job, requestId);
    case AttachmentJobPhase.cancelled:
    case AttachmentJobPhase.completed:
      return _result(AttachmentRuntimeOutcome.unchanged, jobId: jobId);
    case AttachmentJobPhase.probing:
    case AttachmentJobPhase.finalizing:
    case AttachmentJobPhase.awaitingConfirmation:
    case AttachmentJobPhase.failed:
    case AttachmentJobPhase.retryable:
    case AttachmentJobPhase.cleanupFailed:
      return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
  }
}

AttachmentRuntimeResult applyAttachmentResponse(
  AttachmentRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required AttachmentJobId jobId,
  required AttachmentResponse response,
}) {
  final binding = _job(snapshot, accountId, jobId);
  if (binding == null ||
      binding.job.inFlightRequest == null ||
      !identical(binding.job.inFlightRequest, response.request)) {
    return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
  }
  return switch (response) {
    final AttachmentProbeResponse value => _applyProbeResponse(
      snapshot,
      binding.account,
      binding.job,
      value,
    ),
    final AttachmentDavResponse value => _applyDavResponse(
      snapshot,
      binding.account,
      binding.job,
      value,
    ),
    final AttachmentFinalizeResponse value => _applyFinalizeResponse(
      snapshot,
      binding.account,
      binding.job,
      value,
    ),
  };
}

AttachmentRuntimeResult recordAttachmentTransportFailure(
  AttachmentRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required AttachmentJobId jobId,
  required AttachmentRequest request,
  required AttachmentTransportBodyState bodyState,
}) {
  final binding = _job(snapshot, accountId, jobId);
  if (binding == null ||
      binding.job.inFlightRequest == null ||
      !identical(binding.job.inFlightRequest, request)) {
    return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
  }
  final job = binding.job;
  if (request.step == AttachmentRequestStep.finalize &&
      bodyState == AttachmentTransportBodyState.possiblySent) {
    return _replaceJob(
      snapshot,
      binding.account,
      job.copyWith(
        phase: AttachmentJobPhase.awaitingConfirmation,
        inFlightRequest: null,
        finalizationDispatched: true,
        messageIds: const <int>[],
        errorClass: 'ambiguous-finalize-transport',
      ),
      AttachmentRuntimeOutcome.awaitingConfirmation,
    );
  }
  if (<AttachmentRequestStep>{
    AttachmentRequestStep.cleanupChunkSession,
    AttachmentRequestStep.cleanupDraftFile,
  }.contains(request.step)) {
    return _replaceJob(
      snapshot,
      binding.account,
      job.copyWith(
        phase: AttachmentJobPhase.cleanupFailed,
        inFlightRequest: null,
        errorClass: 'cleanup-transport',
      ),
      AttachmentRuntimeOutcome.cleanupFailed,
    );
  }
  final resume = _resumePhaseFor(request.step);
  return _replaceJob(
    snapshot,
    binding.account,
    job.copyWith(
      phase: AttachmentJobPhase.retryable,
      resumePhase: resume,
      inFlightRequest: null,
      finalizationDispatched: false,
      errorClass: bodyState == AttachmentTransportBodyState.notSent
          ? 'transport-before-send'
          : 'transport-replay-safe',
    ),
    AttachmentRuntimeOutcome.retryable,
  );
}

AttachmentRuntimeResult recoverAttachmentAfterRestart(
  AttachmentRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required AttachmentJobId jobId,
}) {
  final binding = _job(snapshot, accountId, jobId);
  if (binding == null) {
    return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
  }
  final request = binding.job.inFlightRequest;
  if (request == null) {
    return _result(AttachmentRuntimeOutcome.unchanged, jobId: jobId);
  }
  if (request.step == AttachmentRequestStep.finalize) {
    return _replaceJob(
      snapshot,
      binding.account,
      binding.job.copyWith(
        phase: AttachmentJobPhase.awaitingConfirmation,
        inFlightRequest: null,
        finalizationDispatched: true,
        messageIds: const <int>[],
        errorClass: 'restart-during-finalize',
      ),
      AttachmentRuntimeOutcome.awaitingConfirmation,
    );
  }
  if (<AttachmentRequestStep>{
    AttachmentRequestStep.cleanupChunkSession,
    AttachmentRequestStep.cleanupDraftFile,
  }.contains(request.step)) {
    return _replaceJob(
      snapshot,
      binding.account,
      binding.job.copyWith(
        phase: AttachmentJobPhase.cleanupFailed,
        inFlightRequest: null,
        errorClass: 'restart-during-cleanup',
      ),
      AttachmentRuntimeOutcome.cleanupFailed,
    );
  }
  return _replaceJob(
    snapshot,
    binding.account,
    binding.job.copyWith(
      phase: AttachmentJobPhase.retryable,
      resumePhase: _resumePhaseFor(request.step),
      inFlightRequest: null,
      errorClass: 'process-interrupted',
    ),
    AttachmentRuntimeOutcome.retryable,
  );
}

AttachmentRuntimeResult requestAttachmentCancel(
  AttachmentRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required AttachmentJobId jobId,
}) {
  final binding = _job(snapshot, accountId, jobId);
  if (binding == null) {
    return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
  }
  final job = binding.job;
  if (job.finalizationDispatched ||
      <AttachmentJobPhase>{
        AttachmentJobPhase.finalizing,
        AttachmentJobPhase.awaitingConfirmation,
        AttachmentJobPhase.completed,
      }.contains(job.phase)) {
    return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
  }
  if (job.phase == AttachmentJobPhase.cancelled) {
    return _result(AttachmentRuntimeOutcome.unchanged, jobId: jobId);
  }
  final cleanupChunk =
      job.draft.uploadMode == AttachmentUploadMode.chunked &&
      job.remoteTemporaryPath != null;
  final cleanupDraft = job.remoteTemporaryPath != null;
  if (!cleanupChunk && !cleanupDraft) {
    return _replaceJob(
      snapshot,
      binding.account,
      job.copyWith(
        phase: AttachmentJobPhase.cancelled,
        resumePhase: null,
        inFlightRequest: null,
        cleanupChunkSession: false,
        cleanupDraftFile: false,
        errorClass: null,
      ),
      AttachmentRuntimeOutcome.cancelled,
    );
  }
  return _replaceJob(
    snapshot,
    binding.account,
    job.copyWith(
      phase: AttachmentJobPhase.cancelling,
      resumePhase: null,
      inFlightRequest: null,
      cleanupChunkSession: cleanupChunk,
      cleanupDraftFile: cleanupDraft,
      errorClass: null,
    ),
    AttachmentRuntimeOutcome.cancelling,
  );
}

AttachmentRuntimeResult reconcileAttachmentConfirmation(
  AttachmentRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required AttachmentJobId jobId,
  required Iterable<AttachmentMessageConfirmation> confirmations,
}) {
  final binding = _job(snapshot, accountId, jobId);
  if (binding == null ||
      !<AttachmentJobPhase>{
        AttachmentJobPhase.awaitingConfirmation,
        AttachmentJobPhase.completed,
      }.contains(binding.job.phase)) {
    return _result(AttachmentRuntimeOutcome.rejected, jobId: jobId);
  }
  final matches = <int>{
    ...binding.job.messageIds,
    ...confirmations
        .where((value) => _confirmationMatches(binding.job, value))
        .map((value) => value.messageId),
  }.toList()..sort();
  if (binding.job.phase == AttachmentJobPhase.completed) {
    if (matches.isEmpty ||
        (matches.length == 1 &&
            matches.single == binding.job.messageIds.single)) {
      return _result(AttachmentRuntimeOutcome.unchanged, jobId: jobId);
    }
    return _result(
      AttachmentRuntimeOutcome.conflictAfterCompletion,
      jobId: jobId,
    );
  }
  if (matches.isEmpty) {
    return _result(AttachmentRuntimeOutcome.noMatch, jobId: jobId);
  }
  if (matches.length > 1) {
    return _replaceJob(
      snapshot,
      binding.account,
      binding.job.copyWith(
        messageIds: matches,
        errorClass: 'multiple-attachment-matches',
      ),
      AttachmentRuntimeOutcome.ambiguousMatch,
    );
  }
  return _replaceJob(
    snapshot,
    binding.account,
    binding.job.copyWith(
      phase: AttachmentJobPhase.completed,
      messageIds: matches,
      errorClass: null,
    ),
    AttachmentRuntimeOutcome.completed,
  );
}

AttachmentRuntimeResult completeAttachmentAccountReauthentication(
  AttachmentRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required int credentialGeneration,
  required int capabilityGeneration,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      account.lane != AttachmentAccountLane.reauthenticationRequired ||
      credentialGeneration <= account.credentialGeneration ||
      capabilityGeneration < account.capabilityGeneration) {
    return _result(AttachmentRuntimeOutcome.rejected);
  }
  return _replaceAccount(
    snapshot,
    account.copyWith(
      lane: AttachmentAccountLane.ready,
      credentialGeneration: credentialGeneration,
      capabilityGeneration: capabilityGeneration,
    ),
    AttachmentRuntimeOutcome.reauthenticationSucceeded,
  );
}
