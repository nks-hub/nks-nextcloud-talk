import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';

void main() {
  try {
    final account = AccountId.parse('release-account');
    final server = ServerBase.parse('https://cloud.example.invalid');
    final room = ConversationToken.parse(
      'rooma123',
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidAttachmentModel,
    );
    final jobId = AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final source = PreparedAttachmentSource(
      handle: AttachmentSourceHandle.parse('release-source'),
      ownership: AttachmentSourceOwnership.appOwnedCopy,
      byteLength: 1024,
      sha256: AttachmentSha256.parse(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      mimeType: 'image/jpeg',
      displayName: 'photo.jpg',
    );
    final profile = AttachmentCapabilityProfile.fromSnapshot(
      _capabilities(),
      federated: false,
    );
    final authority = AttachmentAuthority(
      accountId: account,
      server: server,
      capabilityGeneration: 1,
      profile: profile,
      replayContractRevision: attachmentReplayContractRevision,
      roomCanWrite: true,
      roomToken: room,
    );
    final draft = AttachmentJobDraft(
      jobId: jobId,
      roomToken: room,
      referenceId: ChatReferenceId.parse(
        '11111111-1111-4111-8111-111111111111',
      ),
      source: source,
      metadata: AttachmentMetadata(
        kind: AttachmentMessageKind.file,
        caption: null,
        replyTo: null,
        threadId: null,
        threadTitle: null,
        silent: false,
      ),
      enqueueSequence: 1,
      policy: AttachmentUploadPolicy(
        normalUploadMaximumBytes: 1024 * 1024,
        chunkSizeBytes: 1024000,
      ),
      uploadSessionId: null,
    );
    var snapshot = AttachmentRuntimeSnapshot(
      accounts: <AccountId, AttachmentAccountState>{
        account: AttachmentAccountState(
          accountId: account,
          server: server,
          lane: AttachmentAccountLane.ready,
          credentialGeneration: 1,
          capabilityGeneration: 1,
          jobs: const <AttachmentJobId, AttachmentJob>{},
        ),
      },
    );

    snapshot = _commit(
      snapshot,
      admitAttachmentJob(
        snapshot,
        accountId: account,
        authority: authority,
        davUserId: DavUserId.parse('release-user'),
        draft: draft,
      ),
      AttachmentRuntimeOutcome.admitted,
    );
    var step = planNextAttachmentStep(
      snapshot,
      accountId: account,
      jobId: jobId,
      authority: authority,
      requestId: AttachmentRequestId.parse('release-probe'),
    );
    snapshot = _commit(snapshot, step, AttachmentRuntimeOutcome.probing);
    AttachmentResponse response = decodeAttachmentProbeResponse(
      request: step.request! as AttachmentProbeRequest,
      statusCode: 200,
      body: _ocs(<String, Object?>{
        'folder': 'Talk/Release room/Draft',
        'renames': <Object?>[],
      }),
    );
    snapshot = _commit(
      snapshot,
      applyAttachmentResponse(
        snapshot,
        accountId: account,
        jobId: jobId,
        response: response,
      ),
      AttachmentRuntimeOutcome.draftResolved,
    );

    step = planNextAttachmentStep(
      snapshot,
      accountId: account,
      jobId: jobId,
      authority: authority,
      requestId: AttachmentRequestId.parse('release-put'),
      sourceObservation: AttachmentSourceObservation(
        handle: source.handle,
        byteLength: source.byteLength,
        sha256: source.sha256,
      ),
    );
    snapshot = _commit(snapshot, step, AttachmentRuntimeOutcome.uploading);
    final put = step.request! as AttachmentDavRequest;
    if (put.step != AttachmentRequestStep.normalPut ||
        put.body is! AttachmentSourceBody) {
      throw StateError('Release attachment PUT plan failed.');
    }
    snapshot = _commit(
      snapshot,
      applyAttachmentResponse(
        snapshot,
        accountId: account,
        jobId: jobId,
        response: decodeAttachmentDavResponse(
          request: put,
          statusCode: 201,
          body: Uint8List(0),
        ),
      ),
      AttachmentRuntimeOutcome.uploaded,
    );

    step = planNextAttachmentStep(
      snapshot,
      accountId: account,
      jobId: jobId,
      authority: authority,
      requestId: AttachmentRequestId.parse('release-finalize'),
    );
    snapshot = _commit(snapshot, step, AttachmentRuntimeOutcome.finalizing);
    response = decodeAttachmentFinalizeResponse(
      request: step.request! as AttachmentFinalizeRequest,
      statusCode: 200,
      body: _ocs(<String, Object?>{
        'renames': <Object?>[
          <String, Object?>{'photo.jpg': 'photo.jpg'},
        ],
      }),
    );
    snapshot = _commit(
      snapshot,
      applyAttachmentResponse(
        snapshot,
        accountId: account,
        jobId: jobId,
        response: response,
      ),
      AttachmentRuntimeOutcome.awaitingConfirmation,
    );
    snapshot = _commit(
      snapshot,
      reconcileAttachmentConfirmation(
        snapshot,
        accountId: account,
        jobId: jobId,
        confirmations: <AttachmentMessageConfirmation>[
          AttachmentMessageConfirmation(
            accountId: account,
            server: server,
            messageId: 501,
            roomToken: room,
            referenceId: draft.referenceId.value,
            systemMessage: 'file_shared',
            messageType: 'comment',
            hasFileRichObject: true,
          ),
        ],
      ),
      AttachmentRuntimeOutcome.completed,
    );
    if (snapshot.accounts[account]!.jobs[jobId]!.phase !=
        AttachmentJobPhase.completed) {
      throw StateError('Release attachment completion failed.');
    }
  } on Object catch (error) {
    stderr.writeln('Release attachment probe failed: ${error.runtimeType}');
    exitCode = 1;
  }
}

AttachmentRuntimeSnapshot _commit(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentRuntimeResult result,
  AttachmentRuntimeOutcome expected,
) {
  if (result.outcome != expected || result.plan == null) {
    throw StateError('Unexpected attachment outcome: ${result.outcome.name}');
  }
  return result.plan!.commit(snapshot);
}

Uint8List _ocs(Object? data) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': data,
      },
    }),
  ),
);

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
              'features': <Object?>['chat-reference-id'],
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
