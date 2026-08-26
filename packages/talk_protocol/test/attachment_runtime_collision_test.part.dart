part of 'attachment_runtime_test.dart';

void _registerAttachmentRuntimeCollisionTests() {
  test('normal upload rotates a colliding durable destination', () {
    final operation = draft();
    var snapshot = _driveProbe(operation);
    var upload = _plan(
      snapshot,
      operation,
      44,
      observation: observation(operation.source),
    );
    snapshot = commit(snapshot, upload);
    final firstRequest = upload.request! as AttachmentDavRequest;
    expect(
      firstRequest.remotePath!.value,
      endsWith('${operation.jobId.value}.upload'),
    );

    snapshot = _apply(
      snapshot,
      operation,
      decodeAttachmentDavResponse(
        request: firstRequest,
        statusCode: 412,
        body: Uint8List(0),
      ),
    );
    final rotated = _state(snapshot, operation);
    expect(rotated.phase, AttachmentJobPhase.draftResolved);
    expect(
      rotated.remoteTemporaryPath!.value,
      endsWith('${operation.jobId.value}-1.upload'),
    );
    expect(rotated.cleanupDraftFile, isFalse);
    expect(rotated.cleanupChunkSession, isFalse);

    upload = _plan(
      snapshot,
      operation,
      45,
      observation: observation(operation.source),
    );
    expect(
      (upload.request! as AttachmentDavRequest).remotePath,
      rotated.remoteTemporaryPath,
    );
    snapshot = commit(snapshot, upload);
    snapshot = _apply(
      snapshot,
      operation,
      decodeAttachmentDavResponse(
        request: upload.request! as AttachmentDavRequest,
        statusCode: 201,
        body: Uint8List(0),
      ),
    );
    final finalize = _plan(snapshot, operation, 48);
    final finalizeRequest = finalize.request! as AttachmentFinalizeRequest;
    expect(finalizeRequest.remoteTemporaryPath, rotated.remoteTemporaryPath);
    final finalizeResponse = decodeAttachmentFinalizeResponse(
      request: finalizeRequest,
      statusCode: 200,
      body: finalizeSuccessBody(),
    );
    expect(finalizeResponse.renames.single.actualName, 'photo (1).jpg');
  });

  test('chunk MOVE collision preserves the uploaded manifest and rotates', () {
    final prepared = source(size: 8);
    final operation = draft(
      preparedSource: prepared,
      uploadPolicy: policy(normalMaximum: 1, chunkSize: 4),
    );
    var snapshot = _driveProbe(operation);
    final current = _state(snapshot, operation);
    final completeManifest = <DavChunkRange>[
      operation.policy.chunkAt(0, fileSize: prepared.byteLength),
      operation.policy.chunkAt(4, fileSize: prepared.byteLength),
    ];
    final readyToMove = current.copyWith(
      phase: AttachmentJobPhase.uploading,
      chunkCollectionReady: true,
      chunkManifestLoaded: true,
      verifiedChunks: completeManifest,
    );
    final account = snapshot.accounts[accountA]!;
    snapshot = snapshot.replaceAccount(
      account.copyWith(
        jobs: <AttachmentJobId, AttachmentJob>{operation.jobId: readyToMove},
      ),
    );

    final move = _plan(
      snapshot,
      operation,
      46,
      observation: observation(prepared),
    );
    snapshot = commit(snapshot, move);
    final moveRequest = move.request! as AttachmentDavRequest;
    expect(moveRequest.step, AttachmentRequestStep.chunkMove);
    snapshot = _apply(
      snapshot,
      operation,
      decodeAttachmentDavResponse(
        request: moveRequest,
        statusCode: 412,
        body: Uint8List(0),
      ),
    );

    final rotated = _state(snapshot, operation);
    expect(rotated.chunkCollectionReady, isTrue);
    expect(rotated.chunkManifestLoaded, isTrue);
    expect(rotated.verifiedChunks, completeManifest);
    expect(rotated.cleanupDraftFile, isFalse);
    expect(
      rotated.remoteTemporaryPath!.value,
      endsWith('${operation.jobId.value}-1.upload'),
    );
    final next = _plan(
      snapshot,
      operation,
      47,
      observation: observation(prepared),
    );
    expect(next.request!.step, AttachmentRequestStep.chunkMove);
  });

  test('destination rotation is bounded and never cleans a collision', () {
    final operation = draft();
    var snapshot = _driveProbe(operation);

    for (var attempt = 0; attempt < 16; attempt++) {
      final upload = _plan(
        snapshot,
        operation,
        100 + attempt,
        observation: observation(operation.source),
      );
      snapshot = commit(snapshot, upload);
      snapshot = _apply(
        snapshot,
        operation,
        decodeAttachmentDavResponse(
          request: upload.request! as AttachmentDavRequest,
          statusCode: 412,
          body: Uint8List(0),
        ),
      );
    }

    final exhausted = _state(snapshot, operation);
    expect(exhausted.phase, AttachmentJobPhase.failed);
    expect(exhausted.errorClass, 'dav-destination-collision-exhausted');
    expect(exhausted.cleanupDraftFile, isFalse);
    expect(exhausted.cleanupChunkSession, isFalse);

    final cancel = requestAttachmentCancel(
      snapshot,
      accountId: accountA,
      jobId: operation.jobId,
    );
    expect(cancel.request, isNull);
    final cancelled = commit(snapshot, cancel);
    expect(_state(cancelled, operation).phase, AttachmentJobPhase.cancelled);
  });
}
