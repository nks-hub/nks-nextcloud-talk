part of 'attachment_service.dart';

const List<Duration> _localPersistenceRetryDelays = <Duration>[
  Duration(milliseconds: 25),
  Duration(milliseconds: 250),
  Duration(seconds: 1),
];

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
        phase == AttachmentJobPhase.cleanupFailed ||
        phase == AttachmentJobPhase.awaitingConfirmation &&
            row.errorClass == attachmentConfirmationReconciliationRequired,
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
