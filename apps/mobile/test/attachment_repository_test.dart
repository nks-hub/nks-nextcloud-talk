import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/data/attachment_thread_binding.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'attachment_repository_thread_binding.part.dart';

void main() {
  _registerAttachmentRepositoryThreadBindingTests();

  test(
    'persists and reconstructs an in-flight chunk job across reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nctalk-attachment-repository-',
      );
      final databaseFile = File(
        '${directory.path}${Platform.pathSeparator}attachments.sqlite',
      );
      AppDatabase? database;
      try {
        database = AppDatabase.forTesting(NativeDatabase(databaseFile));
        await _insertAccount(database, 'account-a');
        final repository = AttachmentRepository(database);
        final initial = _runtime(
          accountId: 'account-a',
          sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        final planned = planNextAttachmentStep(
          initial.snapshot,
          accountId: AccountId.parse('account-a'),
          jobId: initial.job.jobId,
          authority: initial.authority,
          requestId: AttachmentRequestId.parse('persisted-request-1'),
          sourceObservation: AttachmentSourceObservation(
            handle: initial.job.draft.source.handle,
            byteLength: initial.job.draft.source.byteLength,
            sha256: initial.job.draft.source.sha256,
          ),
        );
        expect(planned.request?.step, AttachmentRequestStep.chunkPut);
        final snapshot = planned.plan!.commit(initial.snapshot);
        final job = snapshot.accounts.values.single.jobs.values.single;
        await repository.persistAdmission(
          account: snapshot.accounts.values.single,
          job: job,
          metadata: initial.metadata,
          updatedAt: DateTime.utc(2026, 8, 24),
        );
        await database.close();

        database = AppDatabase.forTesting(NativeDatabase(databaseFile));
        final reopened = await AttachmentRepository(database).loadRuntime();
        final restored =
            reopened.snapshot.accounts.values.single.jobs.values.single;

        expect(restored.phase, AttachmentJobPhase.uploading);
        expect(restored.inFlightRequest?.step, AttachmentRequestStep.chunkPut);
        expect(
          restored.inFlightRequest?.requestId.value,
          'persisted-request-1',
        );
        expect(restored.draft.source.handle, initial.job.draft.source.handle);
        expect(
          reopened.metadata.values.single.profile.threads,
          initial.metadata.profile.threads,
        );
        expect(reopened.metadata.values.single.sourceReleased, isFalse);
      } finally {
        await database?.close();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );

  test('persists a rotated upload destination across reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-attachment-collision-',
    );
    final databaseFile = File(
      '${directory.path}${Platform.pathSeparator}attachments.sqlite',
    );
    AppDatabase? database;
    try {
      database = AppDatabase.forTesting(NativeDatabase(databaseFile));
      await _insertAccount(database, 'account-a');
      final initial = _runtime(
        accountId: 'account-a',
        sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final rotatedPath = initial.job.remoteDraftFolder!.append(
        '${initial.job.jobId.value}-3.upload',
      );
      final rotated = initial.job.copyWith(remoteTemporaryPath: rotatedPath);
      final account = initial.snapshot.accounts.values.single.copyWith(
        jobs: <AttachmentJobId, AttachmentJob>{rotated.jobId: rotated},
      );
      await AttachmentRepository(database).persistAdmission(
        account: account,
        job: rotated,
        metadata: initial.metadata,
        updatedAt: DateTime.utc(2026, 8, 26),
      );
      await database.close();

      database = AppDatabase.forTesting(NativeDatabase(databaseFile));
      final reopened = await AttachmentRepository(database).loadRuntime();
      final restored =
          reopened.snapshot.accounts.values.single.jobs.values.single;

      expect(restored.remoteTemporaryPath, rotatedPath);
      expect(restored.chunkCollectionReady, isTrue);
      expect(restored.chunkManifestLoaded, isTrue);
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('keeps attachment runtime isolated by account', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _insertAccount(database, 'account-a');
    await _insertAccount(database, 'account-b');
    final repository = AttachmentRepository(database);
    for (final accountId in <String>['account-a', 'account-b']) {
      final runtime = _runtime(
        accountId: accountId,
        sourceHandle: accountId == 'account-a'
            ? 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            : 'nctalk-media-v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      await repository.persistAdmission(
        account: runtime.snapshot.accounts.values.single,
        job: runtime.job,
        metadata: runtime.metadata,
        updatedAt: DateTime.utc(2026, 8, 24),
      );
    }

    final loaded = await repository.loadRuntime();

    expect(loaded.snapshot.accounts.length, 2);
    expect(
      loaded
          .snapshot
          .accounts[AccountId.parse('account-a')]!
          .jobs
          .values
          .single
          .accountId
          .value,
      'account-a',
    );
    expect(
      loaded
          .snapshot
          .accounts[AccountId.parse('account-b')]!
          .jobs
          .values
          .single
          .accountId
          .value,
      'account-b',
    );
  });

  test(
    'watches deterministic confirmation batches when the job exists first',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _insertAccount(database, 'account-a');
      final repository = AttachmentRepository(database);
      final runtime = await _persistAwaitingJob(
        repository,
        accountId: 'account-a',
        sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final events = <AttachmentConfirmationSnapshot>[];
      final twoMatches = Completer<AttachmentConfirmationSnapshot>();
      final subscription = repository.watchConfirmationCandidates().listen((
        snapshot,
      ) {
        events.add(snapshot);
        if (snapshot.batches.length == 1 &&
            snapshot.batches.single.confirmations.length == 2 &&
            !twoMatches.isCompleted) {
          twoMatches.complete(snapshot);
        }
      });
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      await database.transaction(() async {
        await _insertCachedConfirmation(database, messageId: 102);
        await _insertCachedConfirmation(database, messageId: 101);
      });
      for (final row
          in await database.select(database.cachedChatMessages).get()) {
        expect(
          ChatMessage.fromJson(jsonDecode(row.rawJson)).messageId,
          row.messageId,
        );
      }
      final snapshot = await twoMatches.future;

      expect(snapshot.batches, hasLength(1));
      expect(snapshot.batches.single.accountId.value, 'account-a');
      expect(snapshot.batches.single.jobId, runtime.job.jobId);
      expect(
        snapshot.batches.single.confirmations.map((value) => value.messageId),
        [101, 102],
      );
      final eventCount = events.length;
      await (database.update(database.attachmentJobs)..where(
            (row) =>
                row.accountId.equals('account-a') &
                row.jobId.equals(runtime.job.jobId.value),
          ))
          .write(const AttachmentJobsCompanion(errorClass: Value('marker')));
      await pumpEventQueue();

      expect(events, hasLength(eventCount));
    },
  );

  test('watches a confirmation when the message exists first', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _insertAccount(database, 'account-a');
    await _insertCachedConfirmation(database, messageId: 201);
    final repository = AttachmentRepository(database);
    final match = repository.watchConfirmationCandidates().firstWhere(
      (snapshot) => snapshot.batches.isNotEmpty,
    );

    final runtime = await _persistAwaitingJob(
      repository,
      accountId: 'account-a',
      sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    final snapshot = await match;

    expect(snapshot.batches.single.jobId, runtime.job.jobId);
    expect(snapshot.batches.single.confirmations.single.messageId, 201);
  });

  test(
    'emits when an authoritative parent scope changes in cached JSON',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _insertAccount(database, 'account-a');
      final repository = AttachmentRepository(database);
      await _insertCachedThreadRoot(database, rootId: 42, named: false);
      await _persistAwaitingJob(
        repository,
        accountId: 'account-a',
        sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        replyTo: 42,
        threadId: null,
      );
      final invalidScope = Completer<void>();
      final correctedScope = Completer<AttachmentMessageConfirmation>();
      final subscription = repository.watchConfirmationCandidates().listen((
        snapshot,
      ) {
        if (snapshot.batches.isEmpty ||
            snapshot.batches.single.confirmations.isEmpty) {
          return;
        }
        final confirmation = snapshot.batches.single.confirmations.single;
        if (confirmation.parentThreadId == 76 && !invalidScope.isCompleted) {
          invalidScope.complete();
        }
        if (confirmation.parentThreadId == 77 && !correctedScope.isCompleted) {
          correctedScope.complete(confirmation);
        }
      });
      addTearDown(subscription.cancel);

      await _insertCachedConfirmation(
        database,
        messageId: 202,
        parentMessageId: 42,
        parentRoomToken: 'rooma123',
        parentThreadId: 76,
        threadId: 77,
      );
      await invalidScope.future;
      final row = await (database.select(
        database.cachedChatMessages,
      )..where((message) => message.messageId.equals(202))).getSingle();
      final wire = jsonDecode(row.rawJson) as Map<String, Object?>;
      final parent = wire['parent']! as Map<String, Object?>;
      parent['threadId'] = 77;
      await (database.update(database.cachedChatMessages)..where(
            (message) =>
                message.accountId.equals(row.accountId) &
                message.roomToken.equals(row.roomToken) &
                message.messageId.equals(row.messageId),
          ))
          .write(CachedChatMessagesCompanion(rawJson: Value(jsonEncode(wire))));

      final corrected = await correctedScope.future;
      expect(corrected.parentRoomToken?.value, 'rooma123');
      expect(corrected.parentThreadId, 77);
      expect(corrected.threadId, 77);
    },
  );

  test(
    'replays an existing confirmation snapshot after database reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nctalk-attachment-confirmation-',
      );
      final databaseFile = File(
        '${directory.path}${Platform.pathSeparator}confirmations.sqlite',
      );
      AppDatabase? database;
      try {
        database = AppDatabase.forTesting(NativeDatabase(databaseFile));
        await _insertAccount(database, 'account-a');
        final repository = AttachmentRepository(database);
        final runtime = await _persistAwaitingJob(
          repository,
          accountId: 'account-a',
          sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        await _insertCachedConfirmation(database, messageId: 301);
        await database.close();

        database = AppDatabase.forTesting(NativeDatabase(databaseFile));
        final snapshot = await AttachmentRepository(database)
            .watchConfirmationCandidates()
            .firstWhere((value) => value.batches.isNotEmpty);

        expect(snapshot.batches.single.jobId, runtime.job.jobId);
        expect(snapshot.batches.single.confirmations.single.messageId, 301);
      } finally {
        await database?.close();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );

  test(
    'recovery preserves reply and named-thread confirmation scope',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nctalk-attachment-scope-',
      );
      final databaseFile = File(
        '${directory.path}${Platform.pathSeparator}scope.sqlite',
      );
      AppDatabase? database;
      try {
        database = AppDatabase.forTesting(NativeDatabase(databaseFile));
        await _insertAccount(database, 'account-a');
        final repository = AttachmentRepository(database);
        await _insertCachedThreadRoot(database, rootId: 42, named: false);
        await _insertCachedThreadRoot(database, rootId: 84, named: true);
        final reply = await _persistAwaitingJob(
          repository,
          accountId: 'account-a',
          sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          jobId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          referenceId: '11111111-1111-4111-8111-111111111111',
          replyTo: 42,
          threadId: null,
        );
        final namedThread = await _persistAwaitingJob(
          repository,
          accountId: 'account-a',
          sourceHandle: 'nctalk-media-v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          jobId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          referenceId: '22222222-2222-4222-8222-222222222222',
          enqueueSequence: 2,
          threadId: 84,
        );
        await database.transaction(() async {
          await _insertCachedConfirmation(
            database!,
            messageId: 541,
            parentMessageId: 41,
            parentRoomToken: 'rooma123',
            parentThreadId: 77,
            threadId: 77,
          );
          await _insertCachedConfirmation(
            database,
            messageId: 542,
            parentMessageId: 42,
            parentRoomToken: 'rooma123',
            parentThreadId: 77,
            threadId: 77,
          );
          await _insertCachedConfirmation(
            database,
            messageId: 683,
            referenceId: '22222222-2222-4222-8222-222222222222',
            parentMessageId: 84,
            parentRoomToken: 'rooma123',
            parentThreadId: 83,
            threadId: 84,
          );
          await _insertCachedConfirmation(
            database,
            messageId: 684,
            referenceId: '22222222-2222-4222-8222-222222222222',
            parentMessageId: 84,
            parentRoomToken: 'rooma123',
            parentThreadId: 84,
            threadId: 84,
          );
        });
        await database.close();

        database = AppDatabase.forTesting(NativeDatabase(databaseFile));
        final reopened = AttachmentRepository(database);
        final loaded = await reopened.loadRuntime();
        var snapshot = loaded.snapshot;
        final restoredReply =
            snapshot.accounts.values.single.jobs[reply.job.jobId]!;
        final restoredThread =
            snapshot.accounts.values.single.jobs[namedThread.job.jobId]!;
        expect(restoredReply.draft.metadata.replyTo, 42);
        expect(restoredReply.draft.metadata.threadId, isNull);
        expect(restoredThread.draft.metadata.threadId, 84);

        final replyBatch = await reopened.loadConfirmationCandidates(
          accountId: 'account-a',
          jobId: restoredReply.jobId.value,
        );
        final replyResult = reconcileAttachmentConfirmation(
          snapshot,
          accountId: restoredReply.accountId,
          jobId: restoredReply.jobId,
          confirmations: replyBatch!.confirmations,
        );
        snapshot = replyResult.plan!.commit(snapshot);
        expect(replyResult.outcome, AttachmentRuntimeOutcome.completed);
        expect(
          snapshot.accounts.values.single.jobs[restoredReply.jobId]!.messageIds,
          <int>[542],
        );

        final threadBatch = await reopened.loadConfirmationCandidates(
          accountId: 'account-a',
          jobId: restoredThread.jobId.value,
        );
        final threadResult = reconcileAttachmentConfirmation(
          snapshot,
          accountId: restoredThread.accountId,
          jobId: restoredThread.jobId,
          confirmations: threadBatch!.confirmations,
        );
        snapshot = threadResult.plan!.commit(snapshot);
        expect(threadResult.outcome, AttachmentRuntimeOutcome.completed);
        expect(
          snapshot
              .accounts
              .values
              .single
              .jobs[restoredThread.jobId]!
              .messageIds,
          <int>[684],
        );
      } finally {
        await database?.close();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );

  test(
    'confirmation join rejects account room reference and server drift',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _insertAccount(database, 'account-a');
      await _insertAccount(database, 'account-b');
      await _insertAccount(database, 'account-c');
      final repository = AttachmentRepository(database);
      await _persistAwaitingJob(
        repository,
        accountId: 'account-a',
        sourceHandle: 'nctalk-media-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      await _persistAwaitingJob(
        repository,
        accountId: 'account-c',
        sourceHandle: 'nctalk-media-v1:cccccccccccccccccccccccccccccccc',
        serverUrl: 'https://other.example.invalid',
        jobId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        referenceId: '33333333-3333-4333-8333-333333333333',
      );
      await database.transaction(() async {
        await _insertCachedConfirmation(
          database,
          accountId: 'account-b',
          messageId: 401,
        );
        await _insertCachedConfirmation(
          database,
          messageId: 402,
          roomToken: 'wrongroom',
        );
        await _insertCachedConfirmation(
          database,
          messageId: 403,
          referenceId: '99999999-9999-4999-8999-999999999999',
        );
        await _insertCachedConfirmation(
          database,
          accountId: 'account-c',
          messageId: 404,
          referenceId: '33333333-3333-4333-8333-333333333333',
        );
      });

      expect(
        (await repository.watchConfirmationCandidates().first).batches,
        isEmpty,
      );
      final match = repository.watchConfirmationCandidates().firstWhere(
        (snapshot) => snapshot.batches.isNotEmpty,
      );
      await _insertCachedConfirmation(database, messageId: 405);
      final snapshot = await match;

      expect(snapshot.batches, hasLength(1));
      expect(snapshot.batches.single.accountId.value, 'account-a');
      expect(snapshot.batches.single.confirmations.single.messageId, 405);
      final targeted = await repository.loadConfirmationCandidates(
        accountId: 'account-a',
        jobId: snapshot.batches.single.jobId.value,
      );
      final drifted = await repository.loadConfirmationCandidates(
        accountId: 'account-c',
        jobId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );

      expect(targeted?.confirmations.single.messageId, 405);
      expect(drifted, isNull);
    },
  );
}

Future<void> _insertAccount(
  AppDatabase database,
  String accountId, {
  String serverUrl = 'https://cloud.example.invalid',
}) {
  return database
      .into(database.accounts)
      .insert(
        AccountsCompanion.insert(
          id: accountId,
          serverUrl: serverUrl,
          loginName: 'fixture-user-$accountId',
          serverProductName: 'Nextcloud',
          createdAtMillis: 1,
        ),
      );
}

typedef _AttachmentRuntimeFixture = ({
  AttachmentRuntimeSnapshot snapshot,
  AttachmentJob job,
  AttachmentAuthority authority,
  AttachmentExecutionMetadata metadata,
});

_AttachmentRuntimeFixture _runtime({
  required String accountId,
  required String sourceHandle,
  String serverUrl = 'https://cloud.example.invalid',
  String roomToken = 'rooma123',
  String? jobId,
  String? referenceId,
  int enqueueSequence = 1,
  int? replyTo,
  int? threadId,
  String? threadTitle,
}) {
  final id = AccountId.parse(accountId);
  final server = ServerBase.parse(serverUrl);
  final source = PreparedAttachmentSource(
    handle: AttachmentSourceHandle.parse(sourceHandle),
    ownership: AttachmentSourceOwnership.appOwnedCopy,
    byteLength: 8,
    sha256: AttachmentSha256.parse(
      '9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab',
    ),
    mimeType: 'application/octet-stream',
    displayName: 'source.bin',
  );
  final profile = AttachmentCapabilityProfile.fromSnapshot(
    _capabilities(),
    federated: false,
  );
  final room = ConversationToken.parse(
    roomToken,
    path: r'$.roomToken',
    code: TalkProtocolErrorCode.invalidAttachmentModel,
  );
  final authority = AttachmentAuthority(
    accountId: id,
    server: server,
    capabilityGeneration: 2,
    profile: profile,
    replayContractRevision: attachmentReplayContractRevision,
    roomCanWrite: true,
    roomToken: room,
  );
  final empty = AttachmentRuntimeSnapshot(
    accounts: <AccountId, AttachmentAccountState>{
      id: AttachmentAccountState(
        accountId: id,
        server: server,
        lane: AttachmentAccountLane.ready,
        credentialGeneration: 1,
        capabilityGeneration: 2,
        jobs: const {},
      ),
    },
  );
  final admission = admitAttachmentJob(
    empty,
    accountId: id,
    authority: authority,
    davUserId: DavUserId.parse('fixture-user'),
    draft: AttachmentJobDraft(
      jobId: AttachmentJobId.parse(
        jobId ??
            (accountId == 'account-a'
                ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                : 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
      ),
      roomToken: room,
      referenceId: ChatReferenceId.parse(
        referenceId ??
            (accountId == 'account-a'
                ? '11111111-1111-4111-8111-111111111111'
                : '22222222-2222-4222-8222-222222222222'),
      ),
      source: source,
      metadata: AttachmentMetadata(
        kind: AttachmentMessageKind.file,
        caption: 'Synthetic caption',
        replyTo: replyTo,
        threadId: threadId,
        threadTitle: threadId == null
            ? null
            : threadTitle ?? 'Synthetic thread',
        silent: true,
      ),
      enqueueSequence: enqueueSequence,
      policy: AttachmentUploadPolicy(
        normalUploadMaximumBytes: 4,
        chunkSizeBytes: 4,
      ),
      uploadSessionId: DavUploadSessionId.parse(
        accountId == 'account-a'
            ? 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
            : 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      ),
    ),
  );
  var snapshot = admission.plan!.commit(empty);
  var job = snapshot.accounts[id]!.jobs.values.single;
  job = job.copyWith(
    phase: AttachmentJobPhase.uploading,
    remoteDraftFolder: DavRelativePath.parse('Talk/Room/Draft'),
    remoteTemporaryPath: DavRelativePath.parse(
      'Talk/Room/Draft/${job.draft.stableTemporaryName}',
    ),
    chunkCollectionReady: true,
    chunkManifestLoaded: true,
  );
  final account = snapshot.accounts[id]!;
  snapshot = snapshot.replaceAccount(
    account.copyWith(jobs: <AttachmentJobId, AttachmentJob>{job.jobId: job}),
  );
  return (
    snapshot: snapshot,
    job: job,
    authority: authority,
    metadata: AttachmentExecutionMetadata(
      profile: profile,
      roomCanWrite: true,
      automaticRetryCount: 0,
      nextAttemptAt: null,
      sourceReleased: false,
      localCleanupError: null,
      createdAt: DateTime.utc(2026, 8, 24),
    ),
  );
}

Future<_AttachmentRuntimeFixture> _persistAwaitingJob(
  AttachmentRepository repository, {
  required String accountId,
  required String sourceHandle,
  String serverUrl = 'https://cloud.example.invalid',
  String roomToken = 'rooma123',
  String? jobId,
  String? referenceId,
  int enqueueSequence = 1,
  int? replyTo,
  int? threadId,
  String? threadTitle,
}) async {
  final runtime = _runtime(
    accountId: accountId,
    sourceHandle: sourceHandle,
    serverUrl: serverUrl,
    roomToken: roomToken,
    jobId: jobId,
    referenceId: referenceId,
    enqueueSequence: enqueueSequence,
    replyTo: replyTo,
    threadId: threadId,
    threadTitle: threadTitle,
  );
  final awaiting = runtime.job.copyWith(
    phase: AttachmentJobPhase.awaitingConfirmation,
    inFlightRequest: null,
    finalizationDispatched: true,
  );
  final account = runtime.snapshot.accounts.values.single.copyWith(
    jobs: <AttachmentJobId, AttachmentJob>{awaiting.jobId: awaiting},
  );
  final snapshot = runtime.snapshot.replaceAccount(account);
  await repository.persistAdmission(
    account: account,
    job: awaiting,
    metadata: runtime.metadata,
    updatedAt: DateTime.utc(2026, 8, 24),
  );
  return (
    snapshot: snapshot,
    job: awaiting,
    authority: runtime.authority,
    metadata: runtime.metadata,
  );
}

Future<void> _insertCachedConfirmation(
  AppDatabase database, {
  String accountId = 'account-a',
  int messageId = 101,
  String roomToken = 'rooma123',
  String referenceId = '11111111-1111-4111-8111-111111111111',
  String systemMessage = '',
  String messageType = 'comment',
  bool hasFileRichObject = true,
  int? parentMessageId,
  String? parentRoomToken,
  int? parentThreadId,
  bool parentDeleted = false,
  int? threadId,
  bool useMessageIdAsThread = true,
}) {
  final parameters = hasFileRichObject
      ? <String, Object?>{
          'file': <String, Object?>{
            'type': 'file',
            'id': 'fixture-file',
            'name': 'source.png',
            'link': '/remote.php/dav/files/fixture/source.png',
          },
        }
      : <String, Object?>{};
  final wire = <String, Object?>{
    'id': messageId,
    'token': roomToken,
    'actorType': 'users',
    'actorId': 'fixture-user',
    'actorDisplayName': 'Fixture User',
    'timestamp': 1770000000 + messageId,
    'systemMessage': systemMessage,
    'messageType': messageType,
    'isReplyable': true,
    'referenceId': referenceId,
    'message': hasFileRichObject ? '{file}' : 'Synthetic message',
    'messageParameters': parameters,
    'markdown': false,
    'reactions': <String, Object?>{},
    'reactionsSelf': <Object?>[],
    'deleted': null,
    'threadId': useMessageIdAsThread ? threadId ?? messageId : threadId,
    'isThread': false,
    'threadTitle': null,
    'threadReplies': 0,
    if (parentMessageId != null)
      'parent': parentDeleted
          ? <String, Object?>{'id': parentMessageId, 'deleted': true}
          : <String, Object?>{
              'id': parentMessageId,
              'token': parentRoomToken ?? roomToken,
              'actorType': 'users',
              'actorId': 'fixture-parent',
              'actorDisplayName': 'Fixture Parent',
              'timestamp': 1769990000 + parentMessageId,
              'systemMessage': '',
              'messageType': 'comment',
              'isReplyable': true,
              'referenceId': '',
              'message': 'Synthetic parent',
              'messageParameters': <String, Object?>{},
              'markdown': false,
              'reactions': <String, Object?>{},
              'reactionsSelf': <Object?>[],
              'deleted': null,
              'threadId': parentThreadId,
              'isThread': false,
              'threadTitle': null,
              'threadReplies': 0,
            },
  };
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          messageId: messageId,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 1770000000 + messageId,
          systemMessage: systemMessage,
          messageType: messageType,
          referenceId: referenceId,
          displayText: 'Synthetic attachment',
          deleted: false,
          rawJson: jsonEncode(wire),
        ),
      );
}

CapabilitySnapshot _capabilities() =>
    CapabilitySnapshot.fromJson(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': <String, Object?>{
          'version': <String, Object?>{
            'major': 34,
            'minor': 0,
            'micro': 0,
            'string': '34.0.0',
            'edition': '',
          },
          'capabilities': <String, Object?>{
            'spreed': <String, Object?>{
              'features': <String>[
                'chat-reference-id',
                'media-caption',
                'voice-message-sharing',
                'chat-replies',
                'threads',
                'silent-send',
              ],
              'config': <String, Object?>{
                'attachments': <String, Object?>{
                  'allowed': true,
                  'conversation-subfolders': true,
                },
              },
            },
          },
        },
      },
    }, context: CapabilityContext.authenticated);
