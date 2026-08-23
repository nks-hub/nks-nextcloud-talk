import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';

const String attachmentReplayContractRevision =
    'talk-attachment-f2958bb-core-a0bf541-a599620-r1';

enum AttachmentAccountLane { ready, reauthenticationRequired }

enum AttachmentJobPhase {
  localPrepared,
  probing,
  draftResolved,
  uploading,
  uploaded,
  finalizing,
  awaitingConfirmation,
  completed,
  retryable,
  failed,
  cancelling,
  cancelled,
  cleanupFailed,
}

final class AttachmentJob {
  AttachmentJob({
    required this.accountId,
    required this.server,
    required this.capabilityGeneration,
    required this.replayContractRevision,
    required this.davUserId,
    required this.draft,
    required this.phase,
    required this.resumePhase,
    required this.remoteDraftFolder,
    required this.remoteTemporaryPath,
    required this.chunkCollectionReady,
    required this.chunkManifestLoaded,
    required Iterable<DavChunkRange> verifiedChunks,
    required this.inFlightRequest,
    required this.attemptCount,
    required this.finalizationDispatched,
    required this.cleanupChunkSession,
    required this.cleanupDraftFile,
    required Iterable<int> messageIds,
    required this.errorClass,
  }) : verifiedChunks = List.unmodifiable(verifiedChunks),
       messageIds = List.unmodifiable(messageIds) {
    _validate();
  }

  final AccountId accountId;
  final ServerBase server;
  final int capabilityGeneration;
  final String replayContractRevision;
  final DavUserId davUserId;
  final AttachmentJobDraft draft;
  final AttachmentJobPhase phase;
  final AttachmentJobPhase? resumePhase;
  final DavRelativePath? remoteDraftFolder;
  final DavRelativePath? remoteTemporaryPath;
  final bool chunkCollectionReady;
  final bool chunkManifestLoaded;
  final List<DavChunkRange> verifiedChunks;
  final AttachmentRequest? inFlightRequest;
  final int attemptCount;
  final bool finalizationDispatched;
  final bool cleanupChunkSession;
  final bool cleanupDraftFile;
  final List<int> messageIds;
  final String? errorClass;

  AttachmentJobId get jobId => draft.jobId;

  AttachmentJob copyWith({
    AttachmentJobPhase? phase,
    Object? resumePhase = _unchanged,
    Object? remoteDraftFolder = _unchanged,
    Object? remoteTemporaryPath = _unchanged,
    bool? chunkCollectionReady,
    bool? chunkManifestLoaded,
    Iterable<DavChunkRange>? verifiedChunks,
    Object? inFlightRequest = _unchanged,
    int? attemptCount,
    bool? finalizationDispatched,
    bool? cleanupChunkSession,
    bool? cleanupDraftFile,
    Iterable<int>? messageIds,
    Object? errorClass = _unchanged,
  }) => AttachmentJob(
    accountId: accountId,
    server: server,
    capabilityGeneration: capabilityGeneration,
    replayContractRevision: replayContractRevision,
    davUserId: davUserId,
    draft: draft,
    phase: phase ?? this.phase,
    resumePhase: identical(resumePhase, _unchanged)
        ? this.resumePhase
        : resumePhase as AttachmentJobPhase?,
    remoteDraftFolder: identical(remoteDraftFolder, _unchanged)
        ? this.remoteDraftFolder
        : remoteDraftFolder as DavRelativePath?,
    remoteTemporaryPath: identical(remoteTemporaryPath, _unchanged)
        ? this.remoteTemporaryPath
        : remoteTemporaryPath as DavRelativePath?,
    chunkCollectionReady: chunkCollectionReady ?? this.chunkCollectionReady,
    chunkManifestLoaded: chunkManifestLoaded ?? this.chunkManifestLoaded,
    verifiedChunks: verifiedChunks ?? this.verifiedChunks,
    inFlightRequest: identical(inFlightRequest, _unchanged)
        ? this.inFlightRequest
        : inFlightRequest as AttachmentRequest?,
    attemptCount: attemptCount ?? this.attemptCount,
    finalizationDispatched:
        finalizationDispatched ?? this.finalizationDispatched,
    cleanupChunkSession: cleanupChunkSession ?? this.cleanupChunkSession,
    cleanupDraftFile: cleanupDraftFile ?? this.cleanupDraftFile,
    messageIds: messageIds ?? this.messageIds,
    errorClass: identical(errorClass, _unchanged)
        ? this.errorClass
        : errorClass as String?,
  );

  void _validate() {
    if (capabilityGeneration < 1 ||
        replayContractRevision.isEmpty ||
        replayContractRevision.length > 128 ||
        attemptCount < 0) {
      _stateFailure(r'$.jobs');
    }
    if ((remoteDraftFolder == null) != (remoteTemporaryPath == null)) {
      _stateFailure(r'$.jobs.remotePath');
    }
    if (remoteDraftFolder != null &&
        remoteDraftFolder!.append(draft.stableTemporaryName) !=
            remoteTemporaryPath) {
      _stateFailure(r'$.jobs.remotePath');
    }
    if (resumePhase != null &&
        !<AttachmentJobPhase>{
          AttachmentJobPhase.localPrepared,
          AttachmentJobPhase.draftResolved,
          AttachmentJobPhase.uploaded,
          AttachmentJobPhase.cancelling,
        }.contains(resumePhase)) {
      _stateFailure(r'$.jobs.resumePhase');
    }
    if ((phase == AttachmentJobPhase.retryable) != (resumePhase != null)) {
      _stateFailure(r'$.jobs.resumePhase');
    }
    if (phase == AttachmentJobPhase.retryable && inFlightRequest != null) {
      _stateFailure(r'$.jobs.inFlightRequest');
    }
    if (inFlightRequest != null &&
        !<AttachmentJobPhase>{
          AttachmentJobPhase.probing,
          AttachmentJobPhase.uploading,
          AttachmentJobPhase.finalizing,
          AttachmentJobPhase.cancelling,
        }.contains(phase)) {
      _stateFailure(r'$.jobs.inFlightRequest');
    }
    if (phase == AttachmentJobPhase.probing &&
        inFlightRequest?.step != AttachmentRequestStep.probe) {
      _stateFailure(r'$.jobs.inFlightRequest');
    }
    if (phase == AttachmentJobPhase.finalizing &&
        inFlightRequest?.step != AttachmentRequestStep.finalize) {
      _stateFailure(r'$.jobs.inFlightRequest');
    }
    if (phase == AttachmentJobPhase.cancelling &&
        inFlightRequest != null &&
        !<AttachmentRequestStep>{
          AttachmentRequestStep.cleanupChunkSession,
          AttachmentRequestStep.cleanupDraftFile,
        }.contains(inFlightRequest!.step)) {
      _stateFailure(r'$.jobs.inFlightRequest');
    }
    if (inFlightRequest != null) {
      final context = inFlightRequest!.context;
      if (context.accountId != accountId ||
          context.jobId != jobId ||
          context.server != server ||
          context.roomToken != draft.roomToken ||
          context.capabilityGeneration != capabilityGeneration ||
          context.contractRevision != replayContractRevision) {
        _stateFailure(r'$.jobs.inFlightRequest');
      }
      final request = inFlightRequest;
      if (request is AttachmentDavRequest && request.davUserId != davUserId) {
        _stateFailure(r'$.jobs.inFlightRequest');
      }
    }
    if (draft.uploadMode == AttachmentUploadMode.normal) {
      if (chunkCollectionReady ||
          chunkManifestLoaded ||
          verifiedChunks.isNotEmpty ||
          cleanupChunkSession) {
        _stateFailure(r'$.jobs.chunks');
      }
    } else if (!chunkCollectionReady &&
        (chunkManifestLoaded || verifiedChunks.isNotEmpty)) {
      _stateFailure(r'$.jobs.chunks');
    }
    DavChunkRange? previous;
    for (final chunk in verifiedChunks) {
      if (previous != null &&
          (previous.compareTo(chunk) >= 0 || previous.overlaps(chunk))) {
        _stateFailure(r'$.jobs.chunks');
      }
      if (chunk.start >= draft.source.byteLength ||
          chunk.start % draft.policy.chunkSizeBytes != 0 ||
          draft.policy.chunkAt(
                chunk.start,
                fileSize: draft.source.byteLength,
              ) !=
              chunk) {
        _stateFailure(r'$.jobs.chunks');
      }
      previous = chunk;
    }
    if (verifiedChunks.isNotEmpty && !chunkManifestLoaded) {
      _stateFailure(r'$.jobs.chunks');
    }
    if (finalizationDispatched &&
        !<AttachmentJobPhase>{
          AttachmentJobPhase.awaitingConfirmation,
          AttachmentJobPhase.completed,
        }.contains(phase)) {
      _stateFailure(r'$.jobs.finalization');
    }
    var previousMessageId = 0;
    for (final messageId in messageIds) {
      if (messageId < 1 || messageId <= previousMessageId) {
        _stateFailure(r'$.jobs.messageIds');
      }
      previousMessageId = messageId;
    }
    if (messageIds.isNotEmpty &&
        !<AttachmentJobPhase>{
          AttachmentJobPhase.awaitingConfirmation,
          AttachmentJobPhase.completed,
        }.contains(phase)) {
      _stateFailure(r'$.jobs.messageIds');
    }
    if (phase == AttachmentJobPhase.completed && messageIds.length != 1) {
      _stateFailure(r'$.jobs.messageIds');
    }
    if (phase == AttachmentJobPhase.awaitingConfirmation &&
        messageIds.length == 1) {
      _stateFailure(r'$.jobs.messageIds');
    }
    if (<AttachmentJobPhase>{
          AttachmentJobPhase.draftResolved,
          AttachmentJobPhase.uploading,
          AttachmentJobPhase.uploaded,
          AttachmentJobPhase.finalizing,
          AttachmentJobPhase.awaitingConfirmation,
          AttachmentJobPhase.completed,
          AttachmentJobPhase.cancelling,
          AttachmentJobPhase.cleanupFailed,
        }.contains(phase) &&
        remoteTemporaryPath == null) {
      _stateFailure(r'$.jobs.remotePath');
    }
    if (<AttachmentJobPhase>{
          AttachmentJobPhase.cancelling,
          AttachmentJobPhase.cleanupFailed,
        }.contains(phase) &&
        !cleanupChunkSession &&
        !cleanupDraftFile) {
      _stateFailure(r'$.jobs.cleanup');
    }
    if (<AttachmentJobPhase>{
          AttachmentJobPhase.cancelled,
          AttachmentJobPhase.completed,
        }.contains(phase) &&
        (cleanupChunkSession || cleanupDraftFile)) {
      _stateFailure(r'$.jobs.cleanup');
    }
  }

  @override
  String toString() =>
      'AttachmentJob(phase: ${phase.name}, mode: ${draft.uploadMode.name}, '
      'attemptCount: $attemptCount, chunkCount: ${verifiedChunks.length}, '
      'messageCount: ${messageIds.length}, sensitive: <redacted>)';
}

final class AttachmentAccountState {
  AttachmentAccountState({
    required this.accountId,
    required this.server,
    required this.lane,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required Map<AttachmentJobId, AttachmentJob> jobs,
  }) : jobs = UnmodifiableMapView(Map.of(jobs)) {
    if (credentialGeneration < 1 || capabilityGeneration < 1) {
      _stateFailure(r'$.accounts');
    }
    final references = <Object>{};
    final sequences = <Object>{};
    final requestIds = <AttachmentRequestId>{};
    final finalizingRooms = <Object>{};
    for (final entry in jobs.entries) {
      final job = entry.value;
      if (entry.key != job.jobId ||
          job.accountId != accountId ||
          job.server != server ||
          !references.add(job.draft.referenceId) ||
          !sequences.add((job.draft.roomToken, job.draft.enqueueSequence))) {
        _stateFailure(r'$.accounts.jobs');
      }
      final requestId = job.inFlightRequest?.requestId;
      if (requestId != null && !requestIds.add(requestId)) {
        _stateFailure(r'$.accounts.jobs');
      }
      if (job.phase == AttachmentJobPhase.finalizing &&
          !finalizingRooms.add(job.draft.roomToken)) {
        _stateFailure(r'$.accounts.jobs');
      }
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final AttachmentAccountLane lane;
  final int credentialGeneration;
  final int capabilityGeneration;
  final Map<AttachmentJobId, AttachmentJob> jobs;

  AttachmentAccountState copyWith({
    AttachmentAccountLane? lane,
    int? credentialGeneration,
    int? capabilityGeneration,
    Map<AttachmentJobId, AttachmentJob>? jobs,
  }) => AttachmentAccountState(
    accountId: accountId,
    server: server,
    lane: lane ?? this.lane,
    credentialGeneration: credentialGeneration ?? this.credentialGeneration,
    capabilityGeneration: capabilityGeneration ?? this.capabilityGeneration,
    jobs: jobs ?? this.jobs,
  );

  @override
  String toString() =>
      'AttachmentAccountState(lane: ${lane.name}, jobCount: ${jobs.length})';
}

final class AttachmentRuntimeSnapshot {
  AttachmentRuntimeSnapshot({
    required Map<AccountId, AttachmentAccountState> accounts,
  }) : accounts = UnmodifiableMapView(Map.of(accounts)) {
    for (final entry in accounts.entries) {
      if (entry.key != entry.value.accountId) {
        _stateFailure(r'$.accounts');
      }
    }
  }

  final Map<AccountId, AttachmentAccountState> accounts;

  AttachmentRuntimeSnapshot replaceAccount(AttachmentAccountState account) {
    final result = Map<AccountId, AttachmentAccountState>.of(accounts);
    result[account.accountId] = account;
    return AttachmentRuntimeSnapshot(accounts: result);
  }

  @override
  String toString() =>
      'AttachmentRuntimeSnapshot(accountCount: ${accounts.length})';
}

const Object _unchanged = Object();

Never _stateFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentState, path);
