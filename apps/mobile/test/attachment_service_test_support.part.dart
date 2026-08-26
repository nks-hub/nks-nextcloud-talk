part of 'attachment_service_test.dart';

Future<void> _expectFileRemoved(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${file.path} to be removed');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Fixture {
  _Fixture._({
    required this.directory,
    required this.sourceFile,
    required this.bytes,
    required this.database,
    required this.databaseFile,
    required this.credentials,
    required this.repository,
  });

  static Future<_Fixture> create({bool fileBacked = false}) async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-attachment-service-',
    );
    final bytes = utf8.encode('12345678');
    final sourceFile = File(
      '${directory.path}${Platform.pathSeparator}source.bin',
    );
    await sourceFile.writeAsBytes(bytes, flush: true);
    final databaseFile = fileBacked
        ? File('${directory.path}${Platform.pathSeparator}attachments.sqlite')
        : null;
    final database = AppDatabase.forTesting(
      databaseFile == null
          ? NativeDatabase.memory()
          : NativeDatabase(databaseFile),
    );
    await database
        .into(database.accounts)
        .insert(
          AccountsCompanion.insert(
            id: 'account-a',
            serverUrl: 'https://cloud.example.invalid',
            loginName: 'fixture-user',
            serverProductName: 'Nextcloud',
            createdAtMillis: 1,
          ),
        );
    final credentials = MemoryCredentialVault();
    await credentials.writeAppPassword('account-a', 'fixture-password');
    return _Fixture._(
      directory: directory,
      sourceFile: sourceFile,
      bytes: bytes,
      database: database,
      databaseFile: databaseFile,
      credentials: credentials,
      repository: AttachmentRepository(database),
    );
  }

  final Directory directory;
  final File sourceFile;
  final List<int> bytes;
  AppDatabase database;
  final File? databaseFile;
  final MemoryCredentialVault credentials;
  AttachmentRepository repository;

  Future<void> reopenDatabase() async {
    final file = databaseFile;
    if (file == null) {
      throw StateError('Fixture database is not file-backed');
    }
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase(file));
    repository = AttachmentRepository(database);
  }

  AttachmentService service(
    http.Client client, {
    List<Duration> retryDelays = const [Duration(milliseconds: 1)],
    AttachmentSourceProvider? sourceProvider,
    WatchAttachmentConfirmationCandidates? watchConfirmationCandidates,
    PersistAttachmentTransition? persistTransition,
    ReleaseDurableAttachmentSource? releaseSource,
    CatchUpAttachmentConfirmation? catchUpConfirmation,
    BeforeAttachmentRoomIdle? beforeRoomIdle,
    List<Duration> confirmationRetryDelays = const <Duration>[],
    AttachmentIdentifierFactory? identifierFactory,
  }) {
    final sources = sourceProvider ?? _FileSourceProvider();
    return AttachmentService(
      repository: repository,
      credentials: credentials,
      releaseSource:
          releaseSource ??
          (source) async {
            if (source.ownership != AttachmentSourceOwnership.appOwnedCopy) {
              return;
            }
            final file = File.fromUri(Uri.parse(source.handle.value));
            if (await file.exists()) {
              await file.delete();
            }
          },
      transport: HttpAttachmentTransport(
        client: client,
        sourceProvider: sources,
      ),
      identifierFactory: identifierFactory ?? _IdentifierFactory(),
      retryDelays: retryDelays,
      watchConfirmationCandidates: watchConfirmationCandidates,
      persistTransition: persistTransition,
      catchUpConfirmation: catchUpConfirmation,
      beforeRoomIdle: beforeRoomIdle,
      confirmationRetryDelays: confirmationRetryDelays,
    );
  }

  AttachmentEnqueueRequest request({
    required int normalMaximum,
    AttachmentMessageKind kind = AttachmentMessageKind.file,
    String mimeType = 'image/png',
    String displayName = 'source.png',
    int? replyTo,
    int? threadId,
  }) => AttachmentEnqueueRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse(
      'rooma123',
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidAttachmentModel,
    ),
    source: PreparedAttachmentSource(
      handle: AttachmentSourceHandle.parse(sourceFile.uri.toString()),
      ownership: AttachmentSourceOwnership.appOwnedCopy,
      byteLength: bytes.length,
      sha256: AttachmentSha256.parse(
        'ef797c8118f02dfb649607dd5d3f8c7623048c9c063d532cc95c5ed7a898a64f',
      ),
      mimeType: mimeType,
      displayName: displayName,
    ),
    metadata: AttachmentMetadata(
      kind: kind,
      caption: null,
      replyTo: replyTo,
      threadId: threadId,
      threadTitle: threadId == null ? null : 'Synthetic thread',
      silent: false,
    ),
    davUserId: DavUserId.parse('fixture-user'),
    profile: _profile(),
    credentialGeneration: 1,
    capabilityGeneration: 1,
    roomCanWrite: true,
    policy: AttachmentUploadPolicy(
      normalUploadMaximumBytes: normalMaximum,
      chunkSizeBytes: 4,
    ),
  );

  Future<AttachmentJobId> seedInFlight(AttachmentRequestStep step) async {
    if (step != AttachmentRequestStep.normalPut &&
        step != AttachmentRequestStep.finalize) {
      throw ArgumentError.value(step, 'step');
    }
    final enqueue = request(normalMaximum: 32);
    final jobId = AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final referenceId = ChatReferenceId.parse(
      '11111111-1111-4111-8111-111111111111',
    );
    final authority = AttachmentAuthority(
      accountId: enqueue.accountId,
      server: enqueue.server,
      capabilityGeneration: enqueue.capabilityGeneration,
      profile: enqueue.profile,
      replayContractRevision: attachmentReplayContractRevision,
      roomCanWrite: enqueue.roomCanWrite,
      roomToken: enqueue.roomToken,
    );
    final account = AttachmentAccountState(
      accountId: enqueue.accountId,
      server: enqueue.server,
      lane: AttachmentAccountLane.ready,
      credentialGeneration: enqueue.credentialGeneration,
      capabilityGeneration: enqueue.capabilityGeneration,
      jobs: const {},
    );
    var snapshot = AttachmentRuntimeSnapshot(
      accounts: <AccountId, AttachmentAccountState>{enqueue.accountId: account},
    );
    final admission = admitAttachmentJob(
      snapshot,
      accountId: enqueue.accountId,
      authority: authority,
      davUserId: enqueue.davUserId,
      draft: AttachmentJobDraft(
        jobId: jobId,
        roomToken: enqueue.roomToken,
        referenceId: referenceId,
        source: enqueue.source,
        metadata: enqueue.metadata,
        enqueueSequence: 1,
        policy: enqueue.policy,
        uploadSessionId: null,
      ),
    );
    snapshot = admission.plan!.commit(snapshot);
    if (step == AttachmentRequestStep.normalPut ||
        step == AttachmentRequestStep.finalize) {
      final admitted = snapshot.accounts[enqueue.accountId]!.jobs[jobId]!;
      final folder = DavRelativePath.parse('Talk/Synthetic/Draft');
      final prepared = admitted.copyWith(
        phase: step == AttachmentRequestStep.normalPut
            ? AttachmentJobPhase.draftResolved
            : AttachmentJobPhase.uploaded,
        remoteDraftFolder: folder,
        remoteTemporaryPath: folder.append(admitted.draft.stableTemporaryName),
      );
      snapshot = snapshot.replaceAccount(
        snapshot.accounts[enqueue.accountId]!.copyWith(
          jobs: <AttachmentJobId, AttachmentJob>{jobId: prepared},
        ),
      );
    }
    final planned = planNextAttachmentStep(
      snapshot,
      accountId: enqueue.accountId,
      jobId: jobId,
      authority: authority,
      requestId: AttachmentRequestId.parse('persisted-request-1'),
      sourceObservation: step == AttachmentRequestStep.normalPut
          ? AttachmentSourceObservation(
              handle: enqueue.source.handle,
              byteLength: enqueue.source.byteLength,
              sha256: enqueue.source.sha256,
            )
          : null,
    );
    if (planned.request?.step != step) {
      throw StateError('Unexpected seeded attachment request');
    }
    snapshot = planned.plan!.commit(snapshot);
    final persistedAccount = snapshot.accounts[enqueue.accountId]!;
    final job = persistedAccount.jobs[jobId]!;
    await repository.persistAdmission(
      account: persistedAccount,
      job: job,
      metadata: AttachmentExecutionMetadata(
        profile: enqueue.profile,
        roomCanWrite: enqueue.roomCanWrite,
        automaticRetryCount: 0,
        nextAttemptAt: null,
        sourceReleased: false,
        localCleanupError: null,
        createdAt: DateTime.utc(2026, 8, 24),
      ),
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    return jobId;
  }

  Future<AttachmentJobId> seedTerminal({required int messageId}) async {
    final jobId = await seedInFlight(AttachmentRequestStep.finalize);
    final accountId = AccountId.parse('account-a');
    final key = (accountId: accountId.value, jobId: jobId.value);
    final loaded = await repository.loadRuntime();
    var snapshot = loaded.snapshot;
    final metadata = loaded.metadata[key]!;
    final recovered = recoverAttachmentAfterRestart(
      snapshot,
      accountId: accountId,
      jobId: jobId,
    );
    if (!recovered.canCommit) {
      throw StateError('Synthetic terminal job recovery failed');
    }
    snapshot = recovered.plan!.commit(snapshot);
    var account = snapshot.accounts[accountId]!;
    await repository.persistTransition(
      account: account,
      job: account.jobs[jobId]!,
      metadata: metadata,
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    final completed = reconcileAttachmentConfirmation(
      snapshot,
      accountId: accountId,
      jobId: jobId,
      confirmations: <AttachmentMessageConfirmation>[
        confirmation(jobId, messageId: messageId),
      ],
    );
    if (!completed.canCommit) {
      throw StateError('Synthetic terminal job confirmation failed');
    }
    snapshot = completed.plan!.commit(snapshot);
    account = snapshot.accounts[accountId]!;
    await repository.persistTransition(
      account: account,
      job: account.jobs[jobId]!,
      metadata: metadata,
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    return jobId;
  }

  AttachmentMessageConfirmation confirmation(
    AttachmentJobId _, {
    required int messageId,
    int? parentMessageId,
    ConversationToken? parentRoomToken,
    int? parentThreadId,
    bool parentDeleted = false,
    int? threadId,
    bool useMessageIdAsThread = true,
  }) => AttachmentMessageConfirmation(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    messageId: messageId,
    roomToken: ConversationToken.parse(
      'rooma123',
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidAttachmentModel,
    ),
    referenceId: '11111111-1111-4111-8111-111111111111',
    systemMessage: '',
    messageType: 'comment',
    hasFileRichObject: true,
    parentMessageId: parentMessageId,
    parentRoomToken: parentRoomToken,
    parentThreadId: parentThreadId,
    parentDeleted: parentDeleted,
    threadId: useMessageIdAsThread ? threadId ?? messageId : threadId,
  );

  Future<void> cacheThreadRoot(int rootMessageId) {
    final response =
        readFixtureJson(
              'chat-messages/fixtures/chat-thread-future.response.json',
            )!
            as Map<String, Object?>;
    final ocs = response['ocs']! as Map<String, Object?>;
    final data = ocs['data']! as List<Object?>;
    final message = data.single! as Map<String, Object?>;
    final root = message['parent']! as Map<String, Object?>
      ..['id'] = rootMessageId
      ..['threadId'] = rootMessageId
      ..['isThread'] = false
      ..['threadTitle'] = null
      ..['threadReplies'] = 1;
    return database
        .into(database.cachedChatMessages)
        .insertOnConflictUpdate(
          CachedChatMessagesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            messageId: rootMessageId,
            actorType: 'users',
            actorId: 'fixture-user',
            actorDisplayName: 'Fixture User',
            timestamp: 1770000000 + rootMessageId,
            systemMessage: '',
            messageType: 'comment',
            referenceId: '',
            displayText: 'Reply root',
            deleted: false,
            rawJson: jsonEncode(root),
          ),
        );
  }

  Future<void> cacheConfirmation({
    required int messageId,
    bool hasFileRichObject = true,
    int? deletedParentMessageId,
    int? threadId,
  }) {
    final wire = <String, Object?>{
      'id': messageId,
      'token': 'rooma123',
      'actorType': 'users',
      'actorId': 'fixture-user',
      'actorDisplayName': 'Fixture User',
      'timestamp': 1770000000 + messageId,
      'systemMessage': '',
      'messageType': 'comment',
      'isReplyable': true,
      'referenceId': '11111111-1111-4111-8111-111111111111',
      'message': hasFileRichObject ? '{file}' : 'Pending attachment',
      'messageParameters': hasFileRichObject
          ? <String, Object?>{
              'file': <String, Object?>{
                'type': 'file',
                'id': 'fixture-file',
                'name': 'source.png',
                'link': '/remote.php/dav/files/fixture/source.png',
              },
            }
          : <String, Object?>{},
      'markdown': false,
      'reactions': <String, Object?>{},
      'reactionsSelf': <Object?>[],
      'deleted': null,
      if (deletedParentMessageId != null)
        'parent': <String, Object?>{
          'id': deletedParentMessageId,
          'deleted': true,
        },
      'threadId': threadId ?? messageId,
      'isThread': false,
      'threadTitle': null,
      'threadReplies': 0,
    };
    return database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            messageId: messageId,
            actorType: 'users',
            actorId: 'fixture-user',
            actorDisplayName: 'Fixture User',
            timestamp: 1770000000 + messageId,
            systemMessage: '',
            messageType: 'comment',
            referenceId: '11111111-1111-4111-8111-111111111111',
            displayText: 'Synthetic attachment',
            deleted: false,
            rawJson: jsonEncode(wire),
          ),
        );
  }

  Future<void> close() async {
    await database.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

final class _FileSourceProvider implements AttachmentSourceProvider {
  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (cancellationSignal?.isCancelled ?? false) {
      throw StateError('Synthetic source open cancelled');
    }
    return _FileSourceLease(File.fromUri(Uri.parse(handle.value)));
  }
}

final class _FileSourceLease implements AttachmentSourceLease {
  const _FileSourceLease(this.file);

  final File file;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) =>
      file.openRead(offset, length == null ? null : offset + length);

  @override
  Future<void> close() async {}
}

final class _BlockingSourceProvider implements AttachmentSourceProvider {
  _BlockingSourceProvider(this.file);

  final File file;
  final Completer<void> opened = Completer<void>();
  final Completer<void> leaseClosed = Completer<void>();

  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    if (!opened.isCompleted) {
      opened.complete();
    }
    final signal = cancellationSignal;
    if (signal == null) {
      throw StateError('Cancellation signal is required');
    }
    final cancelled = Completer<void>();
    final registration = signal.register(() {
      if (!cancelled.isCompleted) {
        cancelled.complete();
      }
    });
    try {
      await cancelled.future;
    } finally {
      registration.detach();
    }
    return _TrackedFileSourceLease(file, leaseClosed);
  }
}

final class _TrackedFileSourceLease implements AttachmentSourceLease {
  const _TrackedFileSourceLease(this.file, this.closed);

  final File file;
  final Completer<void> closed;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) =>
      file.openRead(offset, length == null ? null : offset + length);

  @override
  Future<void> close() async {
    if (!closed.isCompleted) {
      closed.complete();
    }
  }
}

final class _IdentifierFactory implements AttachmentIdentifierFactory {
  int _request = 0;

  @override
  AttachmentJobId newJobId() =>
      AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

  @override
  AttachmentRequestId newRequestId() =>
      AttachmentRequestId.parse('attachment-request-${++_request}');

  @override
  ChatReferenceId newReferenceId() =>
      ChatReferenceId.parse('11111111-1111-4111-8111-111111111111');

  @override
  DavUploadSessionId newUploadSessionId() =>
      DavUploadSessionId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
}

final class _SequentialIdentifierFactory
    implements AttachmentIdentifierFactory {
  int _job = 0;
  int _reference = 0;
  int _request = 0;
  int _upload = 0;

  @override
  AttachmentJobId newJobId() =>
      AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa${++_job}');

  @override
  AttachmentRequestId newRequestId() =>
      AttachmentRequestId.parse('attachment-request-${++_request}');

  @override
  ChatReferenceId newReferenceId() => ChatReferenceId.parse(
    '11111111-1111-4111-8111-11111111111${++_reference}',
  );

  @override
  DavUploadSessionId newUploadSessionId() => DavUploadSessionId.parse(
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb${++_upload}',
  );
}

http.Client _unexpectedClient() => MockClient((request) async {
  fail('Restart recovery dispatched an unexpected request: $request');
});

AttachmentCapabilityProfile _profile() =>
    AttachmentCapabilityProfile.fromSnapshot(
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
                  'chat-replies',
                  'threads',
                  'voice-message-sharing',
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
      }, context: CapabilityContext.authenticated),
      federated: false,
    );

List<int> _probeSuccess() => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'folder': 'Talk/Synthetic/Draft',
        'renames': <Object?>[],
      },
    },
  }),
);

List<int> _finalizeSuccess({String fileName = 'source.png'}) => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'renames': <Object?>[
          <String, Object?>{fileName: fileName},
        ],
      },
    },
  }),
);

List<int> _ocsFailure(int statusCode) => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'failure',
        'statuscode': statusCode,
        'message': 'Synthetic transient failure',
      },
      'data': <String, Object?>{},
    },
  }),
);

String _emptyManifest(Uri sessionUri) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">'
    '<d:response><d:href>${sessionUri.path}/</d:href>'
    '<d:propstat><d:prop><d:resourcetype><d:collection/>'
    '</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
    '</d:propstat></d:response></d:multistatus>';
