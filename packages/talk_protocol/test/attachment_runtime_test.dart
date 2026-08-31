import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/attachment_test_support.dart';

part 'attachment_runtime_collision_test.part.dart';
part 'attachment_runtime_ordering_test.part.dart';

void main() {
  group('attachment runtime lifecycle', () {
    test('normal upload completes only after one typed file confirmation', () {
      final operation = draft();
      var snapshot = _admit(emptySnapshot(), operation);
      expect(
        _state(snapshot, operation).phase,
        AttachmentJobPhase.localPrepared,
      );

      final probe = _plan(snapshot, operation, 1);
      snapshot = commit(snapshot, probe);
      expect(probe.outcome, AttachmentRuntimeOutcome.probing);
      final probeResponse = decodeAttachmentProbeResponse(
        request: probe.request! as AttachmentProbeRequest,
        statusCode: 200,
        body: probeSuccessBody(),
      );
      snapshot = _apply(snapshot, operation, probeResponse);
      expect(
        _state(snapshot, operation).phase,
        AttachmentJobPhase.draftResolved,
      );

      final upload = _plan(
        snapshot,
        operation,
        2,
        observation: observation(operation.source),
      );
      snapshot = commit(snapshot, upload);
      expect(upload.request, isA<AttachmentDavRequest>());
      final uploadResponse = decodeAttachmentDavResponse(
        request: upload.request! as AttachmentDavRequest,
        statusCode: 201,
        body: Uint8List(0),
      );
      snapshot = _apply(snapshot, operation, uploadResponse);
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.uploaded);

      final finalize = _plan(snapshot, operation, 3);
      snapshot = commit(snapshot, finalize);
      expect(finalize.request, isA<AttachmentFinalizeRequest>());
      final finalizeResponse = decodeAttachmentFinalizeResponse(
        request: finalize.request! as AttachmentFinalizeRequest,
        statusCode: 200,
        body: finalizeSuccessBody(),
      );
      snapshot = _apply(snapshot, operation, finalizeResponse);
      expect(
        _state(snapshot, operation).phase,
        AttachmentJobPhase.awaitingConfirmation,
      );

      final noMatch = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: const <AttachmentMessageConfirmation>[],
      );
      expect(noMatch.outcome, AttachmentRuntimeOutcome.noMatch);
      expect(noMatch.canCommit, isFalse);

      final wrongType = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(operation, 500, messageType: 'voice-message'),
        ],
      );
      expect(wrongType.outcome, AttachmentRuntimeOutcome.noMatch);

      final legacySystemMessage = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(operation, 500, systemMessage: 'file_shared'),
        ],
      );
      expect(legacySystemMessage.outcome, AttachmentRuntimeOutcome.noMatch);

      final complete = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(operation, 501),
        ],
      );
      snapshot = commit(snapshot, complete);
      expect(complete.outcome, AttachmentRuntimeOutcome.completed);
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.completed);
      expect(_state(snapshot, operation).messageIds, <int>[501]);
    });

    test('voice job requires voice-message confirmation', () {
      final operation = draft(
        preparedSource: source(mime: 'audio/wav', name: 'voice.wav'),
        attachmentMetadata: metadata(kind: AttachmentMessageKind.voice),
      );
      var snapshot = _driveToAwaiting(operation);
      final comment = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(operation, 510),
        ],
      );
      expect(comment.outcome, AttachmentRuntimeOutcome.noMatch);

      final voice = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(operation, 511, messageType: 'voice-message'),
        ],
      );
      snapshot = commit(snapshot, voice);
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.completed);
    });

    test('plain completion rejects a parent or foreign thread scope', () {
      final operation = draft();
      final snapshot = _driveToAwaiting(operation);

      for (final candidate in <AttachmentMessageConfirmation>[
        confirmation(
          operation,
          520,
          parentMessageId: 42,
          parentRoomToken: roomA,
          parentThreadId: 42,
          threadId: 42,
        ),
        confirmation(operation, 521, threadId: 42),
      ]) {
        final mismatch = reconcileAttachmentConfirmation(
          snapshot,
          accountId: accountA,
          jobId: operation.jobId,
          confirmations: <AttachmentMessageConfirmation>[candidate],
        );
        expect(mismatch.outcome, AttachmentRuntimeOutcome.noMatch);
      }
    });

    test('reply completion requires its authoritative same-room thread', () {
      final operation = draft(attachmentMetadata: metadata(replyTo: 42));
      final snapshot = _driveToAwaiting(operation);

      for (final candidate in invalidReplyConfirmations(operation)) {
        final mismatch = reconcileAttachmentConfirmation(
          snapshot,
          accountId: accountA,
          jobId: operation.jobId,
          confirmations: <AttachmentMessageConfirmation>[candidate],
        );
        expect(mismatch.outcome, AttachmentRuntimeOutcome.noMatch);
      }

      final deletedParent = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(
            operation,
            561,
            parentMessageId: 42,
            parentDeleted: true,
            threadId: 77,
          ),
        ],
      );
      expect(deletedParent.outcome, AttachmentRuntimeOutcome.completed);
      expect(
        _state(commit(snapshot, deletedParent), operation).messageIds,
        <int>[561],
      );

      final complete = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(
            operation,
            562,
            parentMessageId: 42,
            parentRoomToken: roomA,
            parentThreadId: 77,
            threadId: 77,
          ),
        ],
      );
      expect(complete.outcome, AttachmentRuntimeOutcome.completed);
      expect(_state(commit(snapshot, complete), operation).messageIds, <int>[
        562,
      ]);
    });

    test('named-thread completion validates full and deleted root shapes', () {
      final operation = draft(attachmentMetadata: metadata(threadId: 42));
      for (final candidate in namedThreadConfirmationCases(operation)) {
        final snapshot = _driveToAwaiting(operation);
        final result = reconcileAttachmentConfirmation(
          snapshot,
          accountId: accountA,
          jobId: operation.jobId,
          confirmations: <AttachmentMessageConfirmation>[candidate.value],
        );
        expect(
          result.outcome,
          candidate.matches
              ? AttachmentRuntimeOutcome.completed
              : AttachmentRuntimeOutcome.noMatch,
        );
      }
    });

    test('planned finalization uses the job-bound message type metadata', () {
      for (final fixture in <({AttachmentJobDraft job, Object metadata})>[
        (job: draft(), metadata: <String, Object?>{}),
        (
          job: draft(
            id: jobId('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
            reference: referenceId('22222222-2222-4222-8222-222222222222'),
            preparedSource: source(mime: 'audio/wav', name: 'voice.wav'),
            attachmentMetadata: metadata(kind: AttachmentMessageKind.voice),
          ),
          metadata: <String, Object?>{'messageType': 'voice-message'},
        ),
      ]) {
        final snapshot = _driveToFinalizing(fixture.job);
        final request =
            _state(snapshot, fixture.job).inFlightRequest!
                as AttachmentFinalizeRequest;
        expect(request.expectedMessageType, fixture.job.expectedMessageType);
        expect(
          jsonDecode(request.body.fields['talkMetaData']! as String),
          fixture.metadata,
        );
      }
    });

    test('multiple matching confirmations remain explicitly ambiguous', () {
      final operation = draft();
      var snapshot = _driveToAwaiting(operation);
      final result = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(operation, 501),
          confirmation(operation, 502),
        ],
      );
      snapshot = commit(snapshot, result);
      expect(result.outcome, AttachmentRuntimeOutcome.ambiguousMatch);
      expect(
        _state(snapshot, operation).phase,
        AttachmentJobPhase.awaitingConfirmation,
      );
      expect(_state(snapshot, operation).messageIds, <int>[501, 502]);

      final narrowerWindow = reconcileAttachmentConfirmation(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        confirmations: <AttachmentMessageConfirmation>[
          confirmation(operation, 501),
        ],
      );
      snapshot = commit(snapshot, narrowerWindow);
      expect(narrowerWindow.outcome, AttachmentRuntimeOutcome.ambiguousMatch);
      expect(
        _state(snapshot, operation).phase,
        AttachmentJobPhase.awaitingConfirmation,
      );
      expect(_state(snapshot, operation).messageIds, <int>[501, 502]);
    });

    test('source mismatch fails without producing a byte request', () {
      final operation = draft();
      var snapshot = _driveProbe(operation);
      final result = _plan(
        snapshot,
        operation,
        40,
        observation: AttachmentSourceObservation(
          handle: operation.source.handle,
          byteLength: operation.source.byteLength,
          sha256: AttachmentSha256.parse(
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          ),
        ),
      );
      snapshot = commit(snapshot, result);
      expect(result.outcome, AttachmentRuntimeOutcome.sourceMismatch);
      expect(result.request, isNull);
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.failed);
      expect(_state(snapshot, operation).cleanupDraftFile, isFalse);
    });

    test(
      'quota exceeded (507) during upload fails the job instead of retrying',
      () {
        final operation = draft();
        var snapshot = _driveProbe(operation);
        final upload = _plan(
          snapshot,
          operation,
          41,
          observation: observation(operation.source),
        );
        snapshot = commit(snapshot, upload);
        final response = decodeAttachmentDavResponse(
          request: upload.request! as AttachmentDavRequest,
          statusCode: 507,
          body: Uint8List(0),
        );
        snapshot = _apply(snapshot, operation, response);
        final job = _state(snapshot, operation);
        expect(job.phase, AttachmentJobPhase.failed);
        expect(job.errorClass, 'dav-quota-exceeded');
        expect(job.resumePhase, isNull);
        expect(job.cleanupDraftFile, isTrue);

        // A failed job never plans another automatic byte request: the
        // runtime does not retry quota errors.
        final next = planNextAttachmentStep(
          snapshot,
          accountId: accountA,
          jobId: operation.jobId,
          authority: authority(room: operation.roomToken),
          requestId: requestId(42),
        );
        expect(next.canCommit, isFalse);
      },
    );

    test('missing write permission (403) during upload fails the job instead '
        'of retrying', () {
      final operation = draft();
      var snapshot = _driveProbe(operation);
      final upload = _plan(
        snapshot,
        operation,
        43,
        observation: observation(operation.source),
      );
      snapshot = commit(snapshot, upload);
      final response = decodeAttachmentDavResponse(
        request: upload.request! as AttachmentDavRequest,
        statusCode: 403,
        body: Uint8List(0),
      );
      snapshot = _apply(snapshot, operation, response);
      final job = _state(snapshot, operation);
      expect(job.phase, AttachmentJobPhase.failed);
      expect(job.errorClass, 'dav-permission-denied');
      expect(job.resumePhase, isNull);
      expect(job.cleanupDraftFile, isTrue);
    });

    _registerAttachmentRuntimeCollisionTests();

    test('chunk resume uploads only missing chunks then moves .file', () {
      final prepared = source(size: 2048000);
      final operation = draft(preparedSource: prepared);
      var snapshot = _driveProbe(operation);

      var result = _plan(
        snapshot,
        operation,
        50,
        observation: observation(prepared),
      );
      snapshot = commit(snapshot, result);
      expect(result.request!.step, AttachmentRequestStep.chunkMkcol);
      snapshot = _apply(
        snapshot,
        operation,
        decodeAttachmentDavResponse(
          request: result.request! as AttachmentDavRequest,
          statusCode: 405,
          body: Uint8List(0),
        ),
      );

      result = _plan(
        snapshot,
        operation,
        51,
        observation: observation(prepared),
      );
      snapshot = commit(snapshot, result);
      expect(result.request!.step, AttachmentRequestStep.chunkPropfind);
      final propfind = result.request! as AttachmentDavRequest;
      final xml = davManifestXml(
        sessionUri: propfind.uri,
        chunks: const <(String, int)>[
          ('0000000000000000-0000000001023999', 1024000),
        ],
      );
      snapshot = _apply(
        snapshot,
        operation,
        decodeAttachmentDavResponse(
          request: propfind,
          statusCode: 207,
          body: Uint8List.fromList(utf8.encode(xml)),
          fileSize: prepared.byteLength,
        ),
      );

      result = _plan(
        snapshot,
        operation,
        52,
        observation: observation(prepared),
      );
      snapshot = commit(snapshot, result);
      final missingPut = result.request! as AttachmentDavRequest;
      expect(missingPut.step, AttachmentRequestStep.chunkPut);
      expect(
        missingPut.chunkRange!.wireName,
        '0000000001024000-0000000002047999',
      );
      expect(missingPut.headers, isNot(contains('Range')));
      snapshot = _apply(
        snapshot,
        operation,
        decodeAttachmentDavResponse(
          request: missingPut,
          statusCode: 201,
          body: Uint8List(0),
        ),
      );

      result = _plan(
        snapshot,
        operation,
        53,
        observation: observation(prepared),
      );
      snapshot = commit(snapshot, result);
      final move = result.request! as AttachmentDavRequest;
      expect(move.step, AttachmentRequestStep.chunkMove);
      expect(move.headers['OC-Total-Length'], '2048000');
      snapshot = _apply(
        snapshot,
        operation,
        decodeAttachmentDavResponse(
          request: move,
          statusCode: 201,
          body: Uint8List(0),
        ),
      );
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.uploaded);
    });

    test(
      'maximum chunk plan finds a late gap without quadratic scanning',
      () {
        const chunkCount = attachmentMaximumChunkCount;
        const missingIndex = chunkCount - 2;
        final prepared = source(size: chunkCount);
        final operation = draft(
          preparedSource: prepared,
          uploadPolicy: policy(normalMaximum: 1, chunkSize: 1),
        );
        var snapshot = _admit(emptySnapshot(), operation);
        final folder = DavRelativePath.parse('Talk/Synthetic-room/Draft');
        final verified = <DavChunkRange>[
          for (var index = 0; index < chunkCount; index++)
            if (index != missingIndex)
              DavChunkRange(start: index, end: index, fileSize: chunkCount),
        ];
        final job = _state(snapshot, operation).copyWith(
          phase: AttachmentJobPhase.uploading,
          remoteDraftFolder: folder,
          remoteTemporaryPath: folder.append(operation.stableTemporaryName),
          chunkCollectionReady: true,
          chunkManifestLoaded: true,
          verifiedChunks: verified,
        );
        final account = snapshot.accounts[accountA]!;
        snapshot = snapshot.replaceAccount(
          account.copyWith(
            jobs: <AttachmentJobId, AttachmentJob>{operation.jobId: job},
          ),
        );

        final result = _plan(
          snapshot,
          operation,
          54,
          observation: observation(prepared),
        );
        final request = result.request! as AttachmentDavRequest;
        expect(request.step, AttachmentRequestStep.chunkPut);
        expect(request.chunkRange!.start, missingIndex);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });

  group('attachment retry and restart semantics', () {
    test('restart during finalize never creates a blind replay request', () {
      final operation = draft();
      var snapshot = _driveToFinalizing(operation);
      final recovered = recoverAttachmentAfterRestart(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
      );
      snapshot = commit(snapshot, recovered);
      expect(recovered.outcome, AttachmentRuntimeOutcome.awaitingConfirmation);
      expect(_state(snapshot, operation).finalizationDispatched, isTrue);
      final next = _plan(snapshot, operation, 61);
      expect(next.outcome, AttachmentRuntimeOutcome.rejected);
      expect(next.request, isNull);
    });

    test('not-sent finalize retries from uploaded without sending bytes', () {
      final operation = draft();
      var snapshot = _driveToFinalizing(operation);
      final request = _state(snapshot, operation).inFlightRequest!;
      final failed = recordAttachmentTransportFailure(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        request: request,
        bodyState: AttachmentTransportBodyState.notSent,
      );
      snapshot = commit(snapshot, failed);
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.retryable);
      expect(
        _state(snapshot, operation).resumePhase,
        AttachmentJobPhase.uploaded,
      );

      final retry = _plan(snapshot, operation, 62);
      expect(retry.request, isA<AttachmentFinalizeRequest>());
      expect(retry.request, isNot(isA<AttachmentDavRequest>()));
    });

    test('possibly-sent finalize always awaits confirmation', () {
      final operation = draft();
      var snapshot = _driveToFinalizing(operation);
      final request = _state(snapshot, operation).inFlightRequest!;
      final failed = recordAttachmentTransportFailure(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        request: request,
        bodyState: AttachmentTransportBodyState.possiblySent,
      );
      snapshot = commit(snapshot, failed);
      expect(
        _state(snapshot, operation).phase,
        AttachmentJobPhase.awaitingConfirmation,
      );
      expect(_state(snapshot, operation).finalizationDispatched, isTrue);
    });

    test('401 pauses only its account and resumes with fresh credentials', () {
      final operation = draft();
      var snapshot = _driveToFinalizing(operation, includeSecondAccount: true);
      final request =
          _state(snapshot, operation).inFlightRequest!
              as AttachmentFinalizeRequest;
      final response = decodeAttachmentFinalizeResponse(
        request: request,
        statusCode: 401,
        body: ocsBody(
          status: 'failure',
          statusCode: 401,
          data: <String, Object?>{'error': 'Authentication required'},
        ),
      );
      snapshot = _apply(snapshot, operation, response);
      expect(
        snapshot.accounts[accountA]!.lane,
        AttachmentAccountLane.reauthenticationRequired,
      );
      expect(snapshot.accounts[accountB]!.lane, AttachmentAccountLane.ready);

      final refreshed = completeAttachmentAccountReauthentication(
        snapshot,
        accountId: accountA,
        credentialGeneration: 4,
        capabilityGeneration: 7,
      );
      snapshot = commit(snapshot, refreshed);
      expect(snapshot.accounts[accountA]!.lane, AttachmentAccountLane.ready);
      expect(
        _plan(snapshot, operation, 70).request,
        isA<AttachmentFinalizeRequest>(),
      );
    });
  });

  _registerAttachmentOrderingAndCleanupTests();
}

AttachmentRuntimeSnapshot _admit(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentJobDraft operation,
) {
  final result = admitAttachmentJob(
    snapshot,
    accountId: accountA,
    authority: authority(room: operation.roomToken),
    davUserId: davUserA,
    draft: operation,
  );
  expect(result.outcome, AttachmentRuntimeOutcome.admitted);
  return commit(snapshot, result);
}

AttachmentRuntimeResult _plan(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentJobDraft operation,
  int requestNumber, {
  AttachmentSourceObservation? observation,
  Set<AttachmentJobId> finalizationBlockExemptions = const <AttachmentJobId>{},
}) => planNextAttachmentStep(
  snapshot,
  accountId: accountA,
  jobId: operation.jobId,
  authority: authority(room: operation.roomToken),
  requestId: requestId(requestNumber),
  sourceObservation: observation,
  finalizationBlockExemptions: finalizationBlockExemptions,
);

AttachmentRuntimeSnapshot _apply(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentJobDraft operation,
  AttachmentResponse response,
) {
  final result = applyAttachmentResponse(
    snapshot,
    accountId: accountA,
    jobId: operation.jobId,
    response: response,
  );
  expect(result.canCommit, isTrue, reason: result.toString());
  return commit(snapshot, result);
}

AttachmentJob _state(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentJobDraft operation,
) => snapshot.accounts[accountA]!.jobs[operation.jobId]!;

AttachmentRuntimeSnapshot _driveProbe(AttachmentJobDraft operation) {
  var snapshot = _admit(emptySnapshot(), operation);
  final probe = _plan(snapshot, operation, 200);
  snapshot = commit(snapshot, probe);
  return _apply(
    snapshot,
    operation,
    decodeAttachmentProbeResponse(
      request: probe.request! as AttachmentProbeRequest,
      statusCode: 200,
      body: probeSuccessBody(),
    ),
  );
}

AttachmentRuntimeSnapshot _driveToUploaded(AttachmentJobDraft operation) =>
    _driveFromAdmittedToUploaded(
      _admit(emptySnapshot(), operation),
      operation,
      requestBase: 210,
    );

AttachmentRuntimeSnapshot _driveFromAdmittedToUploaded(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentJobDraft operation, {
  required int requestBase,
}) {
  final probe = _plan(snapshot, operation, requestBase);
  snapshot = commit(snapshot, probe);
  snapshot = _apply(
    snapshot,
    operation,
    decodeAttachmentProbeResponse(
      request: probe.request! as AttachmentProbeRequest,
      statusCode: 200,
      body: probeSuccessBody(
        'Talk/Synthetic-${operation.roomToken.value}/Draft',
      ),
    ),
  );
  final upload = _plan(
    snapshot,
    operation,
    requestBase + 1,
    observation: observation(operation.source),
  );
  snapshot = commit(snapshot, upload);
  return _apply(
    snapshot,
    operation,
    decodeAttachmentDavResponse(
      request: upload.request! as AttachmentDavRequest,
      statusCode: 201,
      body: Uint8List(0),
    ),
  );
}

AttachmentRuntimeSnapshot _driveToFinalizing(
  AttachmentJobDraft operation, {
  bool includeSecondAccount = false,
}) {
  var snapshot = _admit(
    emptySnapshot(includeSecondAccount: includeSecondAccount),
    operation,
  );
  snapshot = _driveFromAdmittedToUploaded(
    snapshot,
    operation,
    requestBase: 220,
  );
  final finalize = _plan(snapshot, operation, 222);
  return commit(snapshot, finalize);
}

AttachmentRuntimeSnapshot _driveToAwaiting(AttachmentJobDraft operation) {
  final snapshot = _driveToFinalizing(operation);
  final request =
      _state(snapshot, operation).inFlightRequest! as AttachmentFinalizeRequest;
  return _apply(
    snapshot,
    operation,
    decodeAttachmentFinalizeResponse(
      request: request,
      statusCode: 200,
      body: finalizeSuccessBody(),
    ),
  );
}
