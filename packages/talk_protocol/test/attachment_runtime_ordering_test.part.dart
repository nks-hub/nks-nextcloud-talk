part of 'attachment_runtime_test.dart';

void _registerAttachmentOrderingAndCleanupTests() {
  group('attachment ordering and cleanup', () {
    test('finalization is FIFO and single-flight per room', () {
      final first = draft();
      final second = draft(
        id: jobId('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
        reference: referenceId('22222222-2222-4222-8222-222222222222'),
        sequence: 2,
      );
      var snapshot = _driveToUploaded(first);
      snapshot = _admit(snapshot, second);
      snapshot = _driveFromAdmittedToUploaded(
        snapshot,
        second,
        requestBase: 90,
      );

      expect(
        _plan(snapshot, second, 95).outcome,
        AttachmentRuntimeOutcome.rejected,
      );
      final firstFinalize = _plan(snapshot, first, 96);
      expect(firstFinalize.outcome, AttachmentRuntimeOutcome.finalizing);
      snapshot = commit(snapshot, firstFinalize);
      expect(
        _plan(snapshot, second, 97).outcome,
        AttachmentRuntimeOutcome.rejected,
      );
    });

    test('caller-proven manual wait does not block later finalization', () {
      final first = draft();
      final second = draft(
        id: jobId('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
        reference: referenceId('22222222-2222-4222-8222-222222222222'),
        sequence: 2,
      );
      var snapshot = _driveToUploaded(first);
      snapshot = _admit(snapshot, second);
      snapshot = _driveFromAdmittedToUploaded(
        snapshot,
        second,
        requestBase: 98,
      );
      final account = snapshot.accounts[accountA]!;
      final jobs = Map<AttachmentJobId, AttachmentJob>.of(account.jobs);
      jobs[first.jobId] = jobs[first.jobId]!.copyWith(
        phase: AttachmentJobPhase.retryable,
        resumePhase: AttachmentJobPhase.uploaded,
      );
      snapshot = snapshot.replaceAccount(account.copyWith(jobs: jobs));

      expect(
        _plan(snapshot, second, 103).outcome,
        AttachmentRuntimeOutcome.rejected,
      );
      expect(
        _plan(
          snapshot,
          second,
          104,
          finalizationBlockExemptions: <AttachmentJobId>{first.jobId},
        ).outcome,
        AttachmentRuntimeOutcome.finalizing,
      );
    });

    test('different rooms can finalize concurrently', () {
      final first = draft();
      final second = draft(
        id: jobId('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
        room: roomB,
        reference: referenceId('22222222-2222-4222-8222-222222222222'),
        sequence: 1,
      );
      var snapshot = _driveToUploaded(first);
      snapshot = _admit(snapshot, second);
      snapshot = _driveFromAdmittedToUploaded(
        snapshot,
        second,
        requestBase: 100,
      );

      final firstFinalize = _plan(snapshot, first, 105);
      snapshot = commit(snapshot, firstFinalize);
      final secondFinalize = _plan(snapshot, second, 106);
      expect(secondFinalize.outcome, AttachmentRuntimeOutcome.finalizing);
    });

    test('cancel deletes a confirmed-owned remote Draft file', () {
      final operation = draft();
      var snapshot = _driveToUploaded(operation);
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.uploaded);
      final cancel = requestAttachmentCancel(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
      );
      snapshot = commit(snapshot, cancel);
      expect(cancel.outcome, AttachmentRuntimeOutcome.cancelling);

      final cleanup = _plan(snapshot, operation, 110);
      snapshot = commit(snapshot, cleanup);
      expect(cleanup.request!.step, AttachmentRequestStep.cleanupDraftFile);
      snapshot = _apply(
        snapshot,
        operation,
        decodeAttachmentDavResponse(
          request: cleanup.request! as AttachmentDavRequest,
          statusCode: 404,
          body: Uint8List(0),
        ),
      );
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.cancelled);
    });

    test('cleanup failure remains durable and retryable', () {
      final operation = draft();
      var snapshot = _driveToUploaded(operation);
      snapshot = commit(
        snapshot,
        requestAttachmentCancel(
          snapshot,
          accountId: accountA,
          jobId: operation.jobId,
        ),
      );
      final cleanup = _plan(snapshot, operation, 120);
      snapshot = commit(snapshot, cleanup);
      final failure = recordAttachmentTransportFailure(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
        request: cleanup.request!,
        bodyState: AttachmentTransportBodyState.possiblySent,
      );
      snapshot = commit(snapshot, failure);
      expect(
        _state(snapshot, operation).phase,
        AttachmentJobPhase.cleanupFailed,
      );

      final retry = _plan(snapshot, operation, 121);
      expect(retry.request!.step, AttachmentRequestStep.cleanupDraftFile);
    });

    test('cleanup 401 resumes without deleting an unowned destination', () {
      final operation = draft(
        preparedSource: source(size: 2),
        uploadPolicy: policy(normalMaximum: 1, chunkSize: 1),
      );
      var snapshot = _driveProbe(operation);
      snapshot = commit(
        snapshot,
        requestAttachmentCancel(
          snapshot,
          accountId: accountA,
          jobId: operation.jobId,
        ),
      );

      var cleanup = _plan(snapshot, operation, 130);
      snapshot = commit(snapshot, cleanup);
      expect(cleanup.request!.step, AttachmentRequestStep.cleanupChunkSession);
      snapshot = _apply(
        snapshot,
        operation,
        decodeAttachmentDavResponse(
          request: cleanup.request! as AttachmentDavRequest,
          statusCode: 401,
          body: Uint8List(0),
        ),
      );
      expect(
        snapshot.accounts[accountA]!.lane,
        AttachmentAccountLane.reauthenticationRequired,
      );
      expect(_state(snapshot, operation).phase, AttachmentJobPhase.retryable);
      expect(
        _state(snapshot, operation).resumePhase,
        AttachmentJobPhase.cancelling,
      );

      snapshot = commit(
        snapshot,
        completeAttachmentAccountReauthentication(
          snapshot,
          accountId: accountA,
          credentialGeneration: 4,
          capabilityGeneration: 7,
        ),
      );
      cleanup = _plan(snapshot, operation, 131);
      snapshot = commit(snapshot, cleanup);
      expect(cleanup.request!.step, AttachmentRequestStep.cleanupChunkSession);
      snapshot = _apply(
        snapshot,
        operation,
        decodeAttachmentDavResponse(
          request: cleanup.request! as AttachmentDavRequest,
          statusCode: 204,
          body: Uint8List(0),
        ),
      );

      expect(_state(snapshot, operation).phase, AttachmentJobPhase.cancelled);
      expect(_state(snapshot, operation).cleanupDraftFile, isFalse);
      cleanup = _plan(snapshot, operation, 132);
      expect(cleanup.request, isNull);
      expect(cleanup.outcome, AttachmentRuntimeOutcome.unchanged);
    });

    test('cancel is rejected once finalization may have been dispatched', () {
      final operation = draft();
      final snapshot = _driveToAwaiting(operation);
      final cancel = requestAttachmentCancel(
        snapshot,
        accountId: accountA,
        jobId: operation.jobId,
      );
      expect(cancel.outcome, AttachmentRuntimeOutcome.rejected);
      expect(cancel.canCommit, isFalse);
    });
  });
}
