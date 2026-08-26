import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'app_database.dart';
import 'attachment_thread_binding.dart';

typedef AttachmentPersistenceKey = ({String accountId, String jobId});

final class AttachmentConfirmationBatch {
  AttachmentConfirmationBatch({
    required this.accountId,
    required this.jobId,
    required Iterable<AttachmentMessageConfirmation> confirmations,
  }) : confirmations = List<AttachmentMessageConfirmation>.unmodifiable(
         confirmations,
       );

  final AccountId accountId;
  final AttachmentJobId jobId;
  final List<AttachmentMessageConfirmation> confirmations;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AttachmentConfirmationBatch &&
          other.accountId == accountId &&
          other.jobId == jobId &&
          _confirmationListsEqual(other.confirmations, confirmations);

  @override
  int get hashCode => Object.hash(
    accountId,
    jobId,
    Object.hashAll(confirmations.map(_confirmationHash)),
  );
}

final class AttachmentConfirmationSnapshot {
  AttachmentConfirmationSnapshot(Iterable<AttachmentConfirmationBatch> batches)
    : batches = List<AttachmentConfirmationBatch>.unmodifiable(batches);

  final List<AttachmentConfirmationBatch> batches;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AttachmentConfirmationSnapshot &&
          _batchListsEqual(other.batches, batches);

  @override
  int get hashCode => Object.hashAll(batches);
}

final class AttachmentExecutionMetadata {
  const AttachmentExecutionMetadata({
    required this.profile,
    required this.roomCanWrite,
    required this.automaticRetryCount,
    required this.nextAttemptAt,
    required this.sourceReleased,
    required this.localCleanupError,
    required this.createdAt,
  });

  final AttachmentCapabilityProfile profile;
  final bool roomCanWrite;
  final int automaticRetryCount;
  final DateTime? nextAttemptAt;
  final bool sourceReleased;
  final String? localCleanupError;
  final DateTime createdAt;

  AttachmentExecutionMetadata copyWith({
    int? automaticRetryCount,
    Object? nextAttemptAt = _unchanged,
    bool? sourceReleased,
    Object? localCleanupError = _unchanged,
  }) => AttachmentExecutionMetadata(
    profile: profile,
    roomCanWrite: roomCanWrite,
    automaticRetryCount: automaticRetryCount ?? this.automaticRetryCount,
    nextAttemptAt: identical(nextAttemptAt, _unchanged)
        ? this.nextAttemptAt
        : nextAttemptAt as DateTime?,
    sourceReleased: sourceReleased ?? this.sourceReleased,
    localCleanupError: identical(localCleanupError, _unchanged)
        ? this.localCleanupError
        : localCleanupError as String?,
    createdAt: createdAt,
  );
}

final class LoadedAttachmentRuntime {
  LoadedAttachmentRuntime({
    required this.snapshot,
    required Map<AttachmentPersistenceKey, AttachmentExecutionMetadata>
    metadata,
  }) : metadata = Map.unmodifiable(metadata);

  final AttachmentRuntimeSnapshot snapshot;
  final Map<AttachmentPersistenceKey, AttachmentExecutionMetadata> metadata;
}

final class AttachmentRepository {
  const AttachmentRepository(this._database);

  final AppDatabase _database;

  Stream<StoredAttachmentJob?> watchJob({
    required String accountId,
    required String jobId,
  }) =>
      (_database.select(_database.attachmentJobs)
            ..where(
              (row) =>
                  row.accountId.equals(accountId) & row.jobId.equals(jobId),
            )
            ..limit(1))
          .watchSingleOrNull();

  Stream<AttachmentConfirmationSnapshot> watchConfirmationCandidates() {
    final jobs = _database.attachmentJobs;
    final accounts = _database.accounts;
    final messages = _database.cachedChatMessages;
    final query = _database.select(jobs).join([
      innerJoin(
        accounts,
        accounts.id.equalsExp(jobs.accountId) &
            accounts.serverUrl.equalsExp(jobs.serverUrl),
      ),
      innerJoin(
        messages,
        messages.accountId.equalsExp(jobs.accountId) &
            messages.roomToken.equalsExp(jobs.roomToken) &
            messages.referenceId.equalsExp(jobs.referenceId),
      ),
    ])..where(jobs.phase.equals(AttachmentJobPhase.awaitingConfirmation.name));
    return query.watch().map((rows) {
      final grouped = <AttachmentPersistenceKey, _ConfirmationAccumulator>{};
      for (final row in rows) {
        final job = row.readTable(jobs);
        final account = row.readTable(accounts);
        final message = row.readTable(messages);
        final confirmation = _confirmationFromCache(
          account: account,
          row: message,
        );
        if (confirmation == null) {
          continue;
        }
        final key = (accountId: job.accountId, jobId: job.jobId);
        grouped
                .putIfAbsent(
                  key,
                  () => _ConfirmationAccumulator(
                    accountId: AccountId.parse(job.accountId),
                    jobId: AttachmentJobId.parse(job.jobId),
                  ),
                )
                .confirmations[confirmation.messageId] =
            confirmation;
      }
      final batches = grouped.values.map((value) => value.build()).toList()
        ..sort((left, right) {
          final accountOrder = left.accountId.value.compareTo(
            right.accountId.value,
          );
          return accountOrder != 0
              ? accountOrder
              : left.jobId.value.compareTo(right.jobId.value);
        });
      return AttachmentConfirmationSnapshot(batches);
    }).distinct();
  }

  Future<AttachmentConfirmationBatch?> loadConfirmationCandidates({
    required String accountId,
    required String jobId,
  }) async {
    final jobs = _database.attachmentJobs;
    final accounts = _database.accounts;
    final messages = _database.cachedChatMessages;
    final query =
        _database.select(jobs).join([
          innerJoin(
            accounts,
            accounts.id.equalsExp(jobs.accountId) &
                accounts.serverUrl.equalsExp(jobs.serverUrl),
          ),
          innerJoin(
            messages,
            messages.accountId.equalsExp(jobs.accountId) &
                messages.roomToken.equalsExp(jobs.roomToken) &
                messages.referenceId.equalsExp(jobs.referenceId),
          ),
        ])..where(
          jobs.accountId.equals(accountId) &
              jobs.jobId.equals(jobId) &
              jobs.phase.equals(AttachmentJobPhase.awaitingConfirmation.name),
        );
    _ConfirmationAccumulator? accumulator;
    for (final row in await query.get()) {
      final job = row.readTable(jobs);
      final account = row.readTable(accounts);
      final message = row.readTable(messages);
      final confirmation = _confirmationFromCache(
        account: account,
        row: message,
      );
      if (confirmation == null) {
        continue;
      }
      accumulator ??= _ConfirmationAccumulator(
        accountId: AccountId.parse(job.accountId),
        jobId: AttachmentJobId.parse(job.jobId),
      );
      accumulator.confirmations[confirmation.messageId] = confirmation;
    }
    return accumulator?.build();
  }

  Future<StoredAttachmentJob?> getStoredJob({
    required String accountId,
    required String jobId,
  }) =>
      (_database.select(_database.attachmentJobs)..where(
            (row) => row.accountId.equals(accountId) & row.jobId.equals(jobId),
          ))
          .getSingleOrNull();

  Future<StoredAccount?> getAccount(String accountId) => (_database.select(
    _database.accounts,
  )..where((row) => row.id.equals(accountId))).getSingleOrNull();

  Future<LoadedAttachmentRuntime> loadRuntime() async {
    final accountRows = await _database
        .select(_database.attachmentRuntimeAccounts)
        .get();
    final jobRows = await _database.select(_database.attachmentJobs).get();
    final jobsByAccount = <String, List<StoredAttachmentJob>>{};
    for (final row in jobRows) {
      jobsByAccount.putIfAbsent(row.accountId, () => []).add(row);
    }

    final accounts = <AccountId, AttachmentAccountState>{};
    final metadata = <AttachmentPersistenceKey, AttachmentExecutionMetadata>{};
    for (final row in accountRows) {
      final accountId = AccountId.parse(row.accountId);
      final server = ServerBase.parse(row.serverUrl);
      final jobs = <AttachmentJobId, AttachmentJob>{};
      for (final jobRow in jobsByAccount.remove(row.accountId) ?? const []) {
        if (jobRow.serverUrl != row.serverUrl) {
          throw StateError('Attachment job server binding is inconsistent');
        }
        final job = _decodeJob(jobRow);
        jobs[job.jobId] = job;
        metadata[(accountId: row.accountId, jobId: jobRow.jobId)] =
            _decodeMetadata(jobRow);
      }
      accounts[accountId] = AttachmentAccountState(
        accountId: accountId,
        server: server,
        lane: _enumValue(
          AttachmentAccountLane.values,
          row.lane,
          'attachment account lane',
        ),
        credentialGeneration: row.credentialGeneration,
        capabilityGeneration: row.capabilityGeneration,
        jobs: jobs,
      );
    }
    if (jobsByAccount.isNotEmpty) {
      throw StateError('Attachment job is missing its runtime account');
    }
    return LoadedAttachmentRuntime(
      snapshot: AttachmentRuntimeSnapshot(accounts: accounts),
      metadata: metadata,
    );
  }

  Future<void> persistAccountState({
    required AttachmentAccountState account,
    required DateTime updatedAt,
  }) => _database
      .into(_database.attachmentRuntimeAccounts)
      .insertOnConflictUpdate(
        AttachmentRuntimeAccountsCompanion.insert(
          accountId: account.accountId.value,
          serverUrl: account.server.value,
          lane: account.lane.name,
          credentialGeneration: account.credentialGeneration,
          capabilityGeneration: account.capabilityGeneration,
          updatedAtMillis: updatedAt.toUtc().millisecondsSinceEpoch,
        ),
      );

  Future<void> persistAdmission({
    required AttachmentAccountState account,
    required AttachmentJob job,
    required AttachmentExecutionMetadata metadata,
    required DateTime updatedAt,
  }) {
    final updatedAtMillis = updatedAt.toUtc().millisecondsSinceEpoch;
    return _database.transaction(() async {
      await _verifyThreadBinding(job);
      await _database
          .into(_database.attachmentRuntimeAccounts)
          .insertOnConflictUpdate(
            AttachmentRuntimeAccountsCompanion.insert(
              accountId: account.accountId.value,
              serverUrl: account.server.value,
              lane: account.lane.name,
              credentialGeneration: account.credentialGeneration,
              capabilityGeneration: account.capabilityGeneration,
              updatedAtMillis: updatedAtMillis,
            ),
          );
      await _database
          .into(_database.attachmentJobs)
          .insert(
            _jobCompanion(job, metadata, updatedAtMillis: updatedAtMillis),
          );
    });
  }

  Future<void> _verifyThreadBinding(AttachmentJob job) async {
    final metadata = job.draft.metadata;
    final rootMessageId = metadata.threadId ?? metadata.replyTo;
    if (rootMessageId == null) {
      return;
    }
    final root =
        await (_database.select(_database.cachedChatMessages)..where(
              (message) =>
                  message.accountId.equals(job.accountId.value) &
                  message.roomToken.equals(job.draft.roomToken.value) &
                  message.messageId.equals(rootMessageId),
            ))
            .getSingleOrNull();
    final binding = AttachmentThreadBinding.fromCachedRoot(
      root: root,
      accountId: job.accountId.value,
      roomToken: job.draft.roomToken.value,
      rootMessageId: rootMessageId,
    );
    if (!binding.matches(metadata)) {
      throw StateError('Attachment thread binding changed before admission');
    }
  }

  Future<void> persistTransition({
    required AttachmentAccountState account,
    required AttachmentJob job,
    required AttachmentExecutionMetadata metadata,
    required DateTime updatedAt,
  }) {
    final updatedAtMillis = updatedAt.toUtc().millisecondsSinceEpoch;
    return _database.transaction(() async {
      await _database
          .into(_database.attachmentRuntimeAccounts)
          .insertOnConflictUpdate(
            AttachmentRuntimeAccountsCompanion.insert(
              accountId: account.accountId.value,
              serverUrl: account.server.value,
              lane: account.lane.name,
              credentialGeneration: account.credentialGeneration,
              capabilityGeneration: account.capabilityGeneration,
              updatedAtMillis: updatedAtMillis,
            ),
          );
      await _database
          .into(_database.attachmentJobs)
          .insertOnConflictUpdate(
            _jobCompanion(job, metadata, updatedAtMillis: updatedAtMillis),
          );
    });
  }

  AttachmentExecutionMetadata metadataFromRow(StoredAttachmentJob row) =>
      _decodeMetadata(row);
}

AttachmentJob _decodeJob(StoredAttachmentJob row) {
  final accountId = AccountId.parse(row.accountId);
  final server = ServerBase.parse(row.serverUrl);
  final source = PreparedAttachmentSource(
    handle: AttachmentSourceHandle.parse(row.sourceHandle),
    ownership: _enumValue(
      AttachmentSourceOwnership.values,
      row.sourceOwnership,
      'attachment source ownership',
    ),
    byteLength: row.sourceByteLength,
    sha256: AttachmentSha256.parse(row.sourceSha256),
    mimeType: row.sourceMimeType,
    displayName: row.sourceDisplayName,
  );
  final metadata = AttachmentMetadata(
    kind: _enumValue(
      AttachmentMessageKind.values,
      row.messageKind,
      'attachment message kind',
    ),
    caption: row.caption,
    replyTo: row.replyTo,
    threadId: row.threadId,
    threadTitle: row.threadTitle,
    silent: row.silent,
  );
  final draft = AttachmentJobDraft(
    jobId: AttachmentJobId.parse(row.jobId),
    roomToken: ConversationToken.parse(
      row.roomToken,
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidAttachmentModel,
    ),
    referenceId: ChatReferenceId.parse(row.referenceId),
    source: source,
    metadata: metadata,
    enqueueSequence: row.enqueueSequence,
    policy: AttachmentUploadPolicy(
      normalUploadMaximumBytes: row.normalUploadMaximumBytes,
      chunkSizeBytes: row.chunkSizeBytes,
    ),
    uploadSessionId: row.uploadSessionId == null
        ? null
        : DavUploadSessionId.parse(row.uploadSessionId),
  );
  final verifiedChunks = _decodeStringList(row.verifiedChunksJson)
      .map((value) => DavChunkRange.parse(value, fileSize: source.byteLength))
      .toList(growable: false);
  final inFlightRequest = row.inFlightStep == null
      ? null
      : _rebuildRequest(
          row: row,
          accountId: accountId,
          server: server,
          draft: draft,
          davUserId: DavUserId.parse(row.davUserId),
          verifiedChunks: verifiedChunks,
        );
  return AttachmentJob(
    accountId: accountId,
    server: server,
    capabilityGeneration: row.capabilityGeneration,
    replayContractRevision: row.replayContractRevision,
    davUserId: DavUserId.parse(row.davUserId),
    draft: draft,
    phase: _enumValue(
      AttachmentJobPhase.values,
      row.phase,
      'attachment job phase',
    ),
    resumePhase: row.resumePhase == null
        ? null
        : _enumValue(
            AttachmentJobPhase.values,
            row.resumePhase!,
            'attachment resume phase',
          ),
    remoteDraftFolder: row.remoteDraftFolder == null
        ? null
        : DavRelativePath.parse(row.remoteDraftFolder),
    remoteTemporaryPath: row.remoteTemporaryPath == null
        ? null
        : DavRelativePath.parse(row.remoteTemporaryPath),
    chunkCollectionReady: row.chunkCollectionReady,
    chunkManifestLoaded: row.chunkManifestLoaded,
    verifiedChunks: verifiedChunks,
    inFlightRequest: inFlightRequest,
    attemptCount: row.attemptCount,
    finalizationDispatched: row.finalizationDispatched,
    cleanupChunkSession: row.cleanupChunkSession,
    cleanupDraftFile: row.cleanupDraftFile,
    messageIds: _decodeIntList(row.messageIdsJson),
    errorClass: row.errorClass,
  );
}

AttachmentRequest _rebuildRequest({
  required StoredAttachmentJob row,
  required AccountId accountId,
  required ServerBase server,
  required AttachmentJobDraft draft,
  required DavUserId davUserId,
  required List<DavChunkRange> verifiedChunks,
}) {
  final rawRequestId = row.inFlightRequestId;
  if (rawRequestId == null) {
    throw StateError('Attachment in-flight request ID is missing');
  }
  final step = _enumValue(
    AttachmentRequestStep.values,
    row.inFlightStep!,
    'attachment request step',
  );
  final context = AttachmentRequestContext(
    accountId: accountId,
    requestId: AttachmentRequestId.parse(rawRequestId),
    jobId: draft.jobId,
    server: server,
    roomToken: draft.roomToken,
    capabilityGeneration: row.capabilityGeneration,
    contractRevision: row.replayContractRevision,
  );
  final remotePath = row.remoteTemporaryPath == null
      ? null
      : DavRelativePath.parse(row.remoteTemporaryPath);
  return switch (step) {
    AttachmentRequestStep.probe => AttachmentProbeRequest(
      context: context,
      fileNames: <String>[draft.source.displayName],
    ),
    AttachmentRequestStep.normalPut => AttachmentDavRequest.normalPut(
      context: context,
      davUserId: davUserId,
      remotePath: remotePath!,
      source: draft.source,
    ),
    AttachmentRequestStep.chunkMkcol => AttachmentDavRequest.chunkMkcol(
      context: context,
      davUserId: davUserId,
      uploadSessionId: draft.uploadSessionId!,
    ),
    AttachmentRequestStep.chunkPropfind => AttachmentDavRequest.chunkPropfind(
      context: context,
      davUserId: davUserId,
      uploadSessionId: draft.uploadSessionId!,
    ),
    AttachmentRequestStep.chunkPut => AttachmentDavRequest.chunkPut(
      context: context,
      davUserId: davUserId,
      uploadSessionId: draft.uploadSessionId!,
      source: draft.source,
      range: _firstMissingChunk(draft, verifiedChunks),
    ),
    AttachmentRequestStep.chunkMove => AttachmentDavRequest.chunkMove(
      context: context,
      davUserId: davUserId,
      uploadSessionId: draft.uploadSessionId!,
      remotePath: remotePath!,
      totalLength: draft.source.byteLength,
    ),
    AttachmentRequestStep.finalize => AttachmentFinalizeRequest(
      context: context,
      remoteTemporaryPath: remotePath!,
      source: draft.source,
      referenceId: draft.referenceId,
      metadata: draft.metadata,
    ),
    AttachmentRequestStep.cleanupChunkSession =>
      AttachmentDavRequest.cleanupChunkSession(
        context: context,
        davUserId: davUserId,
        uploadSessionId: draft.uploadSessionId!,
      ),
    AttachmentRequestStep.cleanupDraftFile =>
      AttachmentDavRequest.cleanupDraftFile(
        context: context,
        davUserId: davUserId,
        remotePath: remotePath!,
      ),
  };
}

DavChunkRange _firstMissingChunk(
  AttachmentJobDraft draft,
  List<DavChunkRange> verified,
) {
  for (
    var start = 0;
    start < draft.source.byteLength;
    start += draft.policy.chunkSizeBytes
  ) {
    final candidate = draft.policy.chunkAt(
      start,
      fileSize: draft.source.byteLength,
    );
    if (!verified.contains(candidate)) {
      return candidate;
    }
  }
  throw StateError('Persisted chunk PUT has no missing chunk');
}

AttachmentExecutionMetadata _decodeMetadata(StoredAttachmentJob row) =>
    AttachmentExecutionMetadata(
      profile: _profileFromRow(row),
      roomCanWrite: row.roomCanWrite,
      automaticRetryCount: row.automaticRetryCount,
      nextAttemptAt: row.nextAttemptAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row.nextAttemptAtMillis!,
              isUtc: true,
            ),
      sourceReleased: row.sourceReleased,
      localCleanupError: row.localCleanupError,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.createdAtMillis,
        isUtc: true,
      ),
    );

AttachmentCapabilityProfile _profileFromRow(StoredAttachmentJob row) {
  final features = <String>[
    if (row.profileEnabled) 'chat-reference-id',
    if (row.profileCaption) 'media-caption',
    if (row.profileVoice) 'voice-message-sharing',
    if (row.profileReply) 'chat-replies',
    if (row.profileThreads) 'threads',
    if (row.profileSilent) 'silent-send',
  ];
  final snapshot = CapabilitySnapshot.fromJson(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'version': <String, Object?>{
          'major': 0,
          'minor': 0,
          'micro': 0,
          'string': '0.0.0',
          'edition': '',
        },
        'capabilities': <String, Object?>{
          'spreed': <String, Object?>{
            'features': features,
            'config': <String, Object?>{
              'attachments': <String, Object?>{
                'allowed': row.profileEnabled,
                'conversation-subfolders': row.profileEnabled,
              },
            },
          },
        },
      },
    },
  }, context: CapabilityContext.authenticated);
  final profile = AttachmentCapabilityProfile.fromSnapshot(
    snapshot,
    federated: row.profileFederated,
  );
  if (profile.enabled != row.profileEnabled ||
      profile.caption != row.profileCaption ||
      profile.voice != row.profileVoice ||
      profile.reply != row.profileReply ||
      profile.threads != row.profileThreads ||
      profile.silent != row.profileSilent) {
    throw StateError('Persisted attachment capability profile is invalid');
  }
  return profile;
}

AttachmentJobsCompanion _jobCompanion(
  AttachmentJob job,
  AttachmentExecutionMetadata metadata, {
  required int updatedAtMillis,
}) => AttachmentJobsCompanion.insert(
  accountId: job.accountId.value,
  jobId: job.jobId.value,
  serverUrl: job.server.value,
  capabilityGeneration: job.capabilityGeneration,
  replayContractRevision: job.replayContractRevision,
  davUserId: job.davUserId.value,
  roomToken: job.draft.roomToken.value,
  referenceId: job.draft.referenceId.value,
  sourceHandle: job.draft.source.handle.value,
  sourceOwnership: job.draft.source.ownership.name,
  sourceByteLength: job.draft.source.byteLength,
  sourceSha256: job.draft.source.sha256.value,
  sourceMimeType: job.draft.source.mimeType,
  sourceDisplayName: job.draft.source.displayName,
  messageKind: job.draft.metadata.kind.name,
  caption: Value(job.draft.metadata.caption),
  replyTo: Value(job.draft.metadata.replyTo),
  threadId: Value(job.draft.metadata.threadId),
  threadTitle: Value(job.draft.metadata.threadTitle),
  silent: job.draft.metadata.silent,
  enqueueSequence: job.draft.enqueueSequence,
  normalUploadMaximumBytes: job.draft.policy.normalUploadMaximumBytes,
  chunkSizeBytes: job.draft.policy.chunkSizeBytes,
  uploadSessionId: Value(job.draft.uploadSessionId?.value),
  phase: job.phase.name,
  resumePhase: Value(job.resumePhase?.name),
  remoteDraftFolder: Value(job.remoteDraftFolder?.value),
  remoteTemporaryPath: Value(job.remoteTemporaryPath?.value),
  chunkCollectionReady: job.chunkCollectionReady,
  chunkManifestLoaded: job.chunkManifestLoaded,
  verifiedChunksJson: jsonEncode(
    job.verifiedChunks.map((range) => range.wireName).toList(),
  ),
  inFlightStep: Value(job.inFlightRequest?.step.name),
  inFlightRequestId: Value(job.inFlightRequest?.requestId.value),
  attemptCount: job.attemptCount,
  finalizationDispatched: job.finalizationDispatched,
  cleanupChunkSession: job.cleanupChunkSession,
  cleanupDraftFile: job.cleanupDraftFile,
  messageIdsJson: jsonEncode(job.messageIds),
  errorClass: Value(job.errorClass),
  profileFederated: metadata.profile.federated,
  profileEnabled: metadata.profile.enabled,
  profileCaption: metadata.profile.caption,
  profileVoice: metadata.profile.voice,
  profileReply: metadata.profile.reply,
  profileThreads: metadata.profile.threads,
  profileSilent: metadata.profile.silent,
  roomCanWrite: metadata.roomCanWrite,
  automaticRetryCount: Value(metadata.automaticRetryCount),
  nextAttemptAtMillis: Value(
    metadata.nextAttemptAt?.toUtc().millisecondsSinceEpoch,
  ),
  sourceReleased: Value(metadata.sourceReleased),
  localCleanupError: Value(metadata.localCleanupError),
  createdAtMillis: metadata.createdAt.toUtc().millisecondsSinceEpoch,
  updatedAtMillis: updatedAtMillis,
);

List<String> _decodeStringList(String source) {
  final value = jsonDecode(source);
  if (value is! List || value.any((item) => item is! String)) {
    throw StateError('Persisted attachment string list is invalid');
  }
  return value.cast<String>();
}

List<int> _decodeIntList(String source) {
  final value = jsonDecode(source);
  if (value is! List || value.any((item) => item is! int)) {
    throw StateError('Persisted attachment integer list is invalid');
  }
  return value.cast<int>();
}

T _enumValue<T extends Enum>(
  Iterable<T> values,
  String name,
  String description,
) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw StateError('Persisted $description is invalid');
}

const Object _unchanged = Object();

final class _ConfirmationAccumulator {
  _ConfirmationAccumulator({required this.accountId, required this.jobId});

  final AccountId accountId;
  final AttachmentJobId jobId;
  final Map<int, AttachmentMessageConfirmation> confirmations = {};

  AttachmentConfirmationBatch build() {
    final values = confirmations.values.toList()
      ..sort((left, right) => left.messageId.compareTo(right.messageId));
    return AttachmentConfirmationBatch(
      accountId: accountId,
      jobId: jobId,
      confirmations: values,
    );
  }
}

AttachmentMessageConfirmation? _confirmationFromCache({
  required StoredAccount account,
  required CachedChatMessage row,
}) {
  try {
    final message = ChatMessage.fromJson(jsonDecode(row.rawJson));
    if (message.messageId != row.messageId ||
        message.roomToken.value != row.roomToken ||
        message.referenceId != row.referenceId ||
        message.systemMessage != row.systemMessage ||
        message.messageType != row.messageType) {
      return null;
    }
    return AttachmentMessageConfirmation.fromMessage(
      message,
      accountId: AccountId.parse(account.id),
      server: ServerBase.parse(account.serverUrl),
    );
  } on Object {
    return null;
  }
}

bool _batchListsEqual(
  List<AttachmentConfirmationBatch> left,
  List<AttachmentConfirmationBatch> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

bool _confirmationListsEqual(
  List<AttachmentMessageConfirmation> left,
  List<AttachmentMessageConfirmation> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (!_confirmationsEqual(left[index], right[index])) {
      return false;
    }
  }
  return true;
}

bool _confirmationsEqual(
  AttachmentMessageConfirmation left,
  AttachmentMessageConfirmation right,
) =>
    left.accountId == right.accountId &&
    left.server == right.server &&
    left.messageId == right.messageId &&
    left.roomToken == right.roomToken &&
    left.referenceId == right.referenceId &&
    left.systemMessage == right.systemMessage &&
    left.messageType == right.messageType &&
    left.hasFileRichObject == right.hasFileRichObject &&
    left.parentMessageId == right.parentMessageId &&
    left.parentRoomToken == right.parentRoomToken &&
    left.parentThreadId == right.parentThreadId &&
    left.parentDeleted == right.parentDeleted &&
    left.replyToMessageId == right.replyToMessageId &&
    left.replyToRoomToken == right.replyToRoomToken &&
    left.threadId == right.threadId;

int _confirmationHash(AttachmentMessageConfirmation value) => Object.hash(
  value.accountId,
  value.server,
  value.messageId,
  value.roomToken,
  value.referenceId,
  value.systemMessage,
  value.messageType,
  value.hasFileRichObject,
  value.parentMessageId,
  value.parentRoomToken,
  value.parentThreadId,
  value.parentDeleted,
  value.replyToMessageId,
  value.replyToRoomToken,
  value.threadId,
);
