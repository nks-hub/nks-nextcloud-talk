import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';

final accountA = AccountId.parse('account-a');
final accountB = AccountId.parse('account-b');
final serverA = ServerBase.parse('https://cloud.example.invalid/nextcloud');
final serverB = ServerBase.parse('https://other.example.invalid/nextcloud');
final roomA = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidAttachmentModel,
);
final roomB = ConversationToken.parse(
  'roomb123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidAttachmentModel,
);
final davUserA = DavUserId.parse('user-a');

AttachmentJobId jobId([
  String value = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
]) => AttachmentJobId.parse(value);

ChatReferenceId referenceId([
  String value = '11111111-1111-4111-8111-111111111111',
]) => ChatReferenceId.parse(value);

AttachmentRequestId requestId(int value) =>
    AttachmentRequestId.parse('attachment-request-$value');

AttachmentRequestContext attachmentContext(
  int id, {
  AccountId? account,
  ServerBase? server,
  ConversationToken? room,
  AttachmentJobId? job,
  int generation = 7,
  String revision = attachmentReplayContractRevision,
}) => AttachmentRequestContext(
  accountId: account ?? accountA,
  requestId: requestId(id),
  jobId: job ?? jobId(),
  server: server ?? serverA,
  roomToken: room ?? roomA,
  capabilityGeneration: generation,
  contractRevision: revision,
);

PreparedAttachmentSource source({
  int size = 1024,
  String mime = 'image/jpeg',
  String name = 'photo.jpg',
  String handle = 'app-owned-source-a',
  String sha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) => PreparedAttachmentSource(
  handle: AttachmentSourceHandle.parse(handle),
  ownership: AttachmentSourceOwnership.appOwnedCopy,
  byteLength: size,
  sha256: AttachmentSha256.parse(sha),
  mimeType: mime,
  displayName: name,
);

AttachmentSourceObservation observation(PreparedAttachmentSource value) =>
    AttachmentSourceObservation(
      handle: value.handle,
      byteLength: value.byteLength,
      sha256: value.sha256,
    );

AttachmentMetadata metadata({
  AttachmentMessageKind kind = AttachmentMessageKind.file,
  String? caption,
  int? replyTo,
  int? threadId,
  String? threadTitle,
  bool silent = false,
}) => AttachmentMetadata(
  kind: kind,
  caption: caption,
  replyTo: replyTo,
  threadId: threadId,
  threadTitle: threadTitle,
  silent: silent,
);

AttachmentUploadPolicy policy({
  int normalMaximum = 1024 * 1024,
  int chunkSize = 1024000,
}) => AttachmentUploadPolicy(
  normalUploadMaximumBytes: normalMaximum,
  chunkSizeBytes: chunkSize,
);

AttachmentJobDraft draft({
  AttachmentJobId? id,
  ConversationToken? room,
  ChatReferenceId? reference,
  PreparedAttachmentSource? preparedSource,
  AttachmentMetadata? attachmentMetadata,
  int sequence = 1,
  AttachmentUploadPolicy? uploadPolicy,
  DavUploadSessionId? session,
}) {
  final selectedSource = preparedSource ?? source();
  final selectedPolicy = uploadPolicy ?? policy();
  final mode = selectedPolicy.modeFor(selectedSource.byteLength);
  return AttachmentJobDraft(
    jobId: id ?? jobId(),
    roomToken: room ?? roomA,
    referenceId: reference ?? referenceId(),
    source: selectedSource,
    metadata: attachmentMetadata ?? metadata(),
    enqueueSequence: sequence,
    policy: selectedPolicy,
    uploadSessionId: mode == AttachmentUploadMode.chunked
        ? session ??
              DavUploadSessionId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
        : null,
  );
}

CapabilitySnapshot capabilitySnapshot({
  Iterable<String> features = const <String>[
    'chat-reference-id',
    'media-caption',
    'voice-message-sharing',
    'chat-replies',
    'threads',
    'silent-send',
  ],
  bool allowed = true,
  bool conversationSubfolders = true,
  CapabilityContext context = CapabilityContext.authenticated,
}) => CapabilitySnapshot.fromJson(<String, Object?>{
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
          'features': features.toList(growable: false),
          'config': <String, Object?>{
            'attachments': <String, Object?>{
              'allowed': allowed,
              'conversation-subfolders': conversationSubfolders,
            },
          },
        },
      },
    },
  },
}, context: context);

AttachmentCapabilityProfile profile({
  Iterable<String> features = const <String>[
    'chat-reference-id',
    'media-caption',
    'voice-message-sharing',
    'chat-replies',
    'threads',
    'silent-send',
  ],
  bool allowed = true,
  bool conversationSubfolders = true,
  bool federated = false,
}) => AttachmentCapabilityProfile.fromSnapshot(
  capabilitySnapshot(
    features: features,
    allowed: allowed,
    conversationSubfolders: conversationSubfolders,
  ),
  federated: federated,
);

AttachmentAuthority authority({
  AccountId? account,
  ServerBase? server,
  int generation = 7,
  AttachmentCapabilityProfile? capabilityProfile,
  bool canWrite = true,
  ConversationToken? room,
  String revision = attachmentReplayContractRevision,
}) => AttachmentAuthority(
  accountId: account ?? accountA,
  server: server ?? serverA,
  capabilityGeneration: generation,
  profile: capabilityProfile ?? profile(),
  replayContractRevision: revision,
  roomCanWrite: canWrite,
  roomToken: room ?? roomA,
);

AttachmentRuntimeSnapshot emptySnapshot({bool includeSecondAccount = false}) {
  final accounts = <AccountId, AttachmentAccountState>{
    accountA: AttachmentAccountState(
      accountId: accountA,
      server: serverA,
      lane: AttachmentAccountLane.ready,
      credentialGeneration: 3,
      capabilityGeneration: 7,
      jobs: const <AttachmentJobId, AttachmentJob>{},
    ),
  };
  if (includeSecondAccount) {
    accounts[accountB] = AttachmentAccountState(
      accountId: accountB,
      server: serverB,
      lane: AttachmentAccountLane.ready,
      credentialGeneration: 2,
      capabilityGeneration: 7,
      jobs: const <AttachmentJobId, AttachmentJob>{},
    );
  }
  return AttachmentRuntimeSnapshot(accounts: accounts);
}

AttachmentRuntimeSnapshot commit(
  AttachmentRuntimeSnapshot snapshot,
  AttachmentRuntimeResult result,
) => result.plan!.commit(snapshot);

Uint8List jsonBody(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Uint8List ocsBody({
  required String status,
  required int statusCode,
  required Object? data,
}) => jsonBody(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': status,
      'statuscode': statusCode,
      'message': status == 'ok' ? 'OK' : 'Synthetic failure',
    },
    'data': data,
  },
});

Uint8List probeSuccessBody([
  String folder = 'Talk/Synthetic room-rooma123/Draft',
]) => ocsBody(
  status: 'ok',
  statusCode: 200,
  data: <String, Object?>{
    'folder': folder,
    'renames': <Object?>[
      <String, Object?>{'photo.jpg': 'photo (1).jpg'},
    ],
  },
);

Uint8List finalizeSuccessBody() => ocsBody(
  status: 'ok',
  statusCode: 200,
  data: <String, Object?>{
    'renames': <Object?>[
      <String, Object?>{'photo.jpg': 'photo (1).jpg'},
    ],
  },
);

String davManifestXml({
  required Uri sessionUri,
  Iterable<(String, int)> chunks = const <(String, int)>[],
  bool includeFile = true,
}) {
  final buffer = StringBuffer(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">'
    '<d:response><d:href>${sessionUri.path}/</d:href>'
    '<d:propstat><d:prop><d:resourcetype><d:collection/>'
    '</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
    '</d:propstat></d:response>',
  );
  for (final chunk in chunks) {
    buffer.write(
      '<d:response><d:href>${sessionUri.path}/${chunk.$1}</d:href>'
      '<d:propstat><d:prop><d:getcontentlength>${chunk.$2}'
      '</d:getcontentlength></d:prop>'
      '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
    );
  }
  if (includeFile) {
    buffer.write(
      '<d:response><d:href>${sessionUri.path}/.file</d:href>'
      '<d:propstat><d:prop><d:resourcetype/></d:prop>'
      '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
    );
  }
  buffer.write('</d:multistatus>');
  return buffer.toString();
}
