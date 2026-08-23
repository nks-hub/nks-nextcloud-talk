import 'dart:collection';
import 'dart:convert';

import '../chat/identifiers.dart';
import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';

const String attachmentContractUserAgent =
    'com.nkshub.nextcloudtalk attachment-contract/0.1';
const String attachmentV1Path = '/ocs/v2.php/apps/spreed/api/v1/chat';

enum AttachmentHttpMethod { post, put, mkcol, propfind, move, delete }

enum AttachmentRequestStep {
  probe,
  normalPut,
  chunkMkcol,
  chunkPropfind,
  chunkPut,
  chunkMove,
  finalize,
  cleanupChunkSession,
  cleanupDraftFile,
}

final class AttachmentRequestContext {
  AttachmentRequestContext({
    required this.accountId,
    required this.requestId,
    required this.jobId,
    required this.server,
    required this.roomToken,
    required this.capabilityGeneration,
    required this.contractRevision,
  }) {
    if (capabilityGeneration < 1 ||
        contractRevision.isEmpty ||
        contractRevision.length > 128) {
      _requestFailure(r'$.context');
    }
  }

  final AccountId accountId;
  final AttachmentRequestId requestId;
  final AttachmentJobId jobId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int capabilityGeneration;
  final String contractRevision;

  @override
  String toString() =>
      'AttachmentRequestContext(capabilityGeneration: '
      '$capabilityGeneration, account: <redacted>, server: <redacted>, '
      'room: <redacted>, job: <redacted>, request: <redacted>)';
}

sealed class AttachmentRequestBody {
  const AttachmentRequestBody();
}

final class AttachmentJsonBody extends AttachmentRequestBody {
  AttachmentJsonBody(Map<String, Object?> source)
    : fields = _freezeFields(source);

  final Map<String, Object?> fields;

  @override
  String toString() => 'AttachmentJsonBody(<redacted>)';
}

final class AttachmentSourceBody extends AttachmentRequestBody {
  AttachmentSourceBody({
    required this.handle,
    required this.offset,
    required this.length,
    required this.expectedSha256,
  }) {
    if (offset < 0 || length < 1) {
      _requestFailure(r'$.body.sourceRange');
    }
  }

  final AttachmentSourceHandle handle;
  final int offset;
  final int length;
  final AttachmentSha256 expectedSha256;

  @override
  String toString() =>
      'AttachmentSourceBody(offset: $offset, length: $length, '
      'handle: <redacted>, sha256: <redacted>)';
}

final class AttachmentXmlBody extends AttachmentRequestBody {
  const AttachmentXmlBody._(this.value);

  static const propfindContentLength = AttachmentXmlBody._(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/>'
    '<d:resourcetype/></d:prop></d:propfind>',
  );

  final String value;

  @override
  String toString() => 'AttachmentXmlBody(<redacted>)';
}

sealed class AttachmentRequest {
  AttachmentRequest({required this.context, required this.userAgent}) {
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      _requestFailure(r'$.headers.userAgent');
    }
  }

  final AttachmentRequestContext context;
  final String userAgent;

  AccountId get accountId => context.accountId;

  AttachmentRequestId get requestId => context.requestId;

  AttachmentJobId get jobId => context.jobId;

  ServerBase get server => context.server;

  ConversationToken get roomToken => context.roomToken;

  AttachmentHttpMethod get method;

  AttachmentRequestStep get step;

  Uri get uri;

  Map<String, String> get headers;

  AttachmentRequestBody? get body;
}

final class AttachmentProbeRequest extends AttachmentRequest {
  AttachmentProbeRequest({
    required super.context,
    required Iterable<String> fileNames,
    super.userAgent = attachmentContractUserAgent,
  }) : body = AttachmentJsonBody(<String, Object?>{
         'fileNames': _validatedFileNames(fileNames),
         'allowUpdate': false,
       });

  @override
  final AttachmentJsonBody body;

  @override
  Map<String, String> get headers => _ocsHeaders(userAgent);

  @override
  AttachmentHttpMethod get method => AttachmentHttpMethod.post;

  @override
  AttachmentRequestStep get step => AttachmentRequestStep.probe;

  @override
  Uri get uri => _ocsUri(context, 'attachment/folder');

  @override
  String toString() => 'AttachmentProbeRequest()';
}

final class AttachmentFinalizeRequest extends AttachmentRequest {
  AttachmentFinalizeRequest({
    required super.context,
    required this.remoteTemporaryPath,
    required PreparedAttachmentSource source,
    required this.referenceId,
    required AttachmentMetadata metadata,
    super.userAgent = attachmentContractUserAgent,
  }) : expectedMessageType = metadata.expectedMessageType,
       body = AttachmentJsonBody(<String, Object?>{
         'filePath': remoteTemporaryPath.value,
         'fileName': source.displayName,
         'referenceId': referenceId.value,
         'allowUpdate': false,
         'talkMetaData': jsonEncode(_talkMetadata(metadata, source)),
       });

  final DavRelativePath remoteTemporaryPath;
  final ChatReferenceId referenceId;
  final String expectedMessageType;

  @override
  final AttachmentJsonBody body;

  @override
  Map<String, String> get headers => _ocsHeaders(userAgent);

  @override
  AttachmentHttpMethod get method => AttachmentHttpMethod.post;

  @override
  AttachmentRequestStep get step => AttachmentRequestStep.finalize;

  @override
  Uri get uri => _ocsUri(context, 'attachment');

  @override
  String toString() => 'AttachmentFinalizeRequest(<redacted>)';
}

final class AttachmentDavRequest extends AttachmentRequest {
  AttachmentDavRequest._({
    required super.context,
    required this.davUserId,
    required this.method,
    required this.step,
    required this.uri,
    required Map<String, String> headers,
    required this.body,
    required this.remotePath,
    required this.chunkRange,
    super.userAgent = attachmentContractUserAgent,
  }) : headers = UnmodifiableMapView(<String, String>{
         'User-Agent': userAgent,
         ...headers,
       });

  factory AttachmentDavRequest.normalPut({
    required AttachmentRequestContext context,
    required DavUserId davUserId,
    required DavRelativePath remotePath,
    required PreparedAttachmentSource source,
  }) => AttachmentDavRequest._(
    context: context,
    davUserId: davUserId,
    method: AttachmentHttpMethod.put,
    step: AttachmentRequestStep.normalPut,
    uri: _filesUri(context.server, davUserId, remotePath),
    headers: <String, String>{
      'Content-Length': source.byteLength.toString(),
      'Content-Type': source.mimeType,
    },
    body: AttachmentSourceBody(
      handle: source.handle,
      offset: 0,
      length: source.byteLength,
      expectedSha256: source.sha256,
    ),
    remotePath: remotePath,
    chunkRange: null,
  );

  factory AttachmentDavRequest.chunkMkcol({
    required AttachmentRequestContext context,
    required DavUserId davUserId,
    required DavUploadSessionId uploadSessionId,
  }) => AttachmentDavRequest._(
    context: context,
    davUserId: davUserId,
    method: AttachmentHttpMethod.mkcol,
    step: AttachmentRequestStep.chunkMkcol,
    uri: _uploadSessionUri(context.server, davUserId, uploadSessionId),
    headers: const <String, String>{},
    body: null,
    remotePath: null,
    chunkRange: null,
  );

  factory AttachmentDavRequest.chunkPropfind({
    required AttachmentRequestContext context,
    required DavUserId davUserId,
    required DavUploadSessionId uploadSessionId,
  }) => AttachmentDavRequest._(
    context: context,
    davUserId: davUserId,
    method: AttachmentHttpMethod.propfind,
    step: AttachmentRequestStep.chunkPropfind,
    uri: _uploadSessionUri(context.server, davUserId, uploadSessionId),
    headers: const <String, String>{
      'Content-Type': 'application/xml; charset=utf-8',
      'Depth': '1',
    },
    body: AttachmentXmlBody.propfindContentLength,
    remotePath: null,
    chunkRange: null,
  );

  factory AttachmentDavRequest.chunkPut({
    required AttachmentRequestContext context,
    required DavUserId davUserId,
    required DavUploadSessionId uploadSessionId,
    required PreparedAttachmentSource source,
    required DavChunkRange range,
  }) => AttachmentDavRequest._(
    context: context,
    davUserId: davUserId,
    method: AttachmentHttpMethod.put,
    step: AttachmentRequestStep.chunkPut,
    uri: _uploadSessionUri(
      context.server,
      davUserId,
      uploadSessionId,
      tail: range.wireName,
    ),
    headers: <String, String>{
      'Content-Length': range.length.toString(),
      'Content-Type': source.mimeType,
    },
    body: AttachmentSourceBody(
      handle: source.handle,
      offset: range.start,
      length: range.length,
      expectedSha256: source.sha256,
    ),
    remotePath: null,
    chunkRange: range,
  );

  factory AttachmentDavRequest.chunkMove({
    required AttachmentRequestContext context,
    required DavUserId davUserId,
    required DavUploadSessionId uploadSessionId,
    required DavRelativePath remotePath,
    required int totalLength,
  }) {
    final sourceUri = _uploadSessionUri(
      context.server,
      davUserId,
      uploadSessionId,
      tail: '.file',
    );
    final destination = _filesUri(context.server, davUserId, remotePath);
    if (!context.server.hasSameOrigin(destination)) {
      _requestFailure(r'$.headers.Destination');
    }
    return AttachmentDavRequest._(
      context: context,
      davUserId: davUserId,
      method: AttachmentHttpMethod.move,
      step: AttachmentRequestStep.chunkMove,
      uri: sourceUri,
      headers: <String, String>{
        'Destination': destination.toString(),
        'OC-Total-Length': totalLength.toString(),
        'Overwrite': 'T',
      },
      body: null,
      remotePath: remotePath,
      chunkRange: null,
    );
  }

  factory AttachmentDavRequest.cleanupChunkSession({
    required AttachmentRequestContext context,
    required DavUserId davUserId,
    required DavUploadSessionId uploadSessionId,
  }) => AttachmentDavRequest._(
    context: context,
    davUserId: davUserId,
    method: AttachmentHttpMethod.delete,
    step: AttachmentRequestStep.cleanupChunkSession,
    uri: _uploadSessionUri(context.server, davUserId, uploadSessionId),
    headers: const <String, String>{},
    body: null,
    remotePath: null,
    chunkRange: null,
  );

  factory AttachmentDavRequest.cleanupDraftFile({
    required AttachmentRequestContext context,
    required DavUserId davUserId,
    required DavRelativePath remotePath,
  }) => AttachmentDavRequest._(
    context: context,
    davUserId: davUserId,
    method: AttachmentHttpMethod.delete,
    step: AttachmentRequestStep.cleanupDraftFile,
    uri: _filesUri(context.server, davUserId, remotePath),
    headers: const <String, String>{},
    body: null,
    remotePath: remotePath,
    chunkRange: null,
  );

  final DavUserId davUserId;

  @override
  final AttachmentHttpMethod method;

  @override
  final AttachmentRequestStep step;

  @override
  final Uri uri;

  @override
  final Map<String, String> headers;

  @override
  final AttachmentRequestBody? body;

  final DavRelativePath? remotePath;
  final DavChunkRange? chunkRange;

  @override
  String toString() =>
      'AttachmentDavRequest(step: ${step.name}, user: <redacted>, '
      'uri: <redacted>, path: <redacted>)';
}

Map<String, String> _ocsHeaders(String userAgent) => UnmodifiableMapView({
  'Accept': 'application/json',
  'Content-Type': 'application/json',
  'OCS-APIRequest': 'true',
  'User-Agent': userAgent,
});

Uri _ocsUri(AttachmentRequestContext context, String suffix) =>
    context.server.uri.replace(
      path:
          '${context.server.basePath}$attachmentV1Path/'
          '${context.roomToken.value}/$suffix',
      queryParameters: const <String, String>{'format': 'json'},
    );

Uri _filesUri(
  ServerBase server,
  DavUserId userId,
  DavRelativePath relativePath,
) => _uriFromSegments(server, <String>[
  'remote.php',
  'dav',
  'files',
  userId.value,
  ...relativePath.segments,
]);

Uri _uploadSessionUri(
  ServerBase server,
  DavUserId userId,
  DavUploadSessionId sessionId, {
  String? tail,
}) => _uriFromSegments(server, <String>[
  'remote.php',
  'dav',
  'uploads',
  userId.value,
  sessionId.value,
  ?tail,
]);

Uri _uriFromSegments(ServerBase server, List<String> suffix) {
  final baseSegments = server.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  return Uri(
    scheme: server.uri.scheme,
    host: server.uri.host,
    port: server.uri.hasPort ? server.uri.port : null,
    pathSegments: <String>[...baseSegments, ...suffix],
  );
}

Map<String, Object?> _talkMetadata(
  AttachmentMetadata metadata,
  PreparedAttachmentSource source,
) {
  if (!metadata.supportsSource(source)) {
    _requestFailure(r'$.body.talkMetaData.messageType');
  }
  return <String, Object?>{
    if (metadata.expectedMessageType == 'voice-message')
      'messageType': metadata.expectedMessageType,
    if (metadata.caption != null) 'caption': metadata.caption,
    if (metadata.silent) 'silent': true,
    if (metadata.replyTo != null) 'replyTo': metadata.replyTo,
    if (metadata.threadId != null) 'threadId': metadata.threadId,
    if (metadata.threadTitle != null) 'threadTitle': metadata.threadTitle,
  };
}

List<Object?> _validatedFileNames(Iterable<String> source) {
  final values = source.toList(growable: false);
  if (values.isEmpty ||
      values.length > 16 ||
      values.any((value) => !_validAttachmentFileName(value))) {
    _requestFailure(r'$.body.fileNames');
  }
  return List<Object?>.unmodifiable(values);
}

bool _validAttachmentFileName(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    value.trim() == value &&
    value != '.' &&
    value != '..' &&
    !value.contains('/') &&
    !value.contains(r'\') &&
    !value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

Map<String, Object?> _freezeFields(Map<String, Object?> source) {
  final frozen = JsonFreezeSession(
    maximumDepth: 16,
    maximumNodes: 256,
    errorCode: TalkProtocolErrorCode.invalidAttachmentRequest,
    errorPath: r'$.body',
  ).freeze(source);
  return requireObject(
    frozen,
    path: r'$.body',
    code: TalkProtocolErrorCode.invalidAttachmentRequest,
  );
}

Never _requestFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentRequest, path);
