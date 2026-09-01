part of 'attachment_service.dart';

/// Older jobs that own no active request cannot enforce room FIFO while a
/// later user-selected upload is ready to finalize. That covers a scheduled or
/// exhausted retry, and a confirmation that gave up its automatic catch-up:
/// all three move only on an explicit retry, so holding the room for them
/// would block every later attachment for as long as the account exists.
Set<AttachmentJobId> _inactiveFinalizationBlockExemptions(
  _AttachmentServiceRuntime service,
  AttachmentJob current,
) {
  final account = service._snapshot.accounts[current.accountId];
  if (account == null) {
    return const <AttachmentJobId>{};
  }
  final now = service._clock().toUtc();
  final result = <AttachmentJobId>{};
  for (final other in account.jobs.values) {
    if (other.jobId == current.jobId ||
        other.draft.roomToken != current.draft.roomToken ||
        other.draft.enqueueSequence >= current.draft.enqueueSequence) {
      continue;
    }
    if (other.phase == AttachmentJobPhase.awaitingConfirmation) {
      if (other.errorClass == attachmentConfirmationReconciliationRequired) {
        result.add(other.jobId);
      }
      continue;
    }
    if (other.phase != AttachmentJobPhase.retryable &&
        other.phase != AttachmentJobPhase.cleanupFailed) {
      continue;
    }
    final metadata = service._metadata[_jobKey(other.accountId, other.jobId)];
    if (metadata == null) {
      continue;
    }
    final next = metadata.nextAttemptAt;
    if (next != null ? next.isAfter(now) : metadata.automaticRetryCount > 0) {
      result.add(other.jobId);
    }
  }
  return result;
}

const List<Duration> _localPersistenceRetryDelays = <Duration>[
  Duration(milliseconds: 25),
  Duration(milliseconds: 250),
  Duration(seconds: 1),
];

/// Why one room step returned. [blocked] means the state machine refused the
/// plan for this job alone, so the room must try its next job instead of
/// going idle.
enum _AttachmentStepOutcome { progressed, blocked, stopped }

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
    resumePhase: row.resumePhase == null
        ? null
        : AttachmentJobPhase.values.singleWhere(
            (value) => value.name == row.resumePhase,
          ),
    progress: progress,
    attemptCount: row.attemptCount,
    automaticRetryCount: row.automaticRetryCount,
    retryAllowed:
        phase == AttachmentJobPhase.retryable ||
        phase == AttachmentJobPhase.cleanupFailed ||
        phase == AttachmentJobPhase.awaitingConfirmation &&
            row.errorClass == attachmentConfirmationReconciliationRequired,
    retryScheduled: row.nextAttemptAtMillis != null,
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
