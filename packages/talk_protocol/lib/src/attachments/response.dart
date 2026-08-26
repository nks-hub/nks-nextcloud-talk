import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';

const int attachmentMaximumResponseBytes = 1024 * 1024;
const int attachmentMaximumDavXmlBytes = 8 * 1024 * 1024;
const int attachmentMaximumDavXmlDepth = 32;
const int attachmentMaximumDavXmlNodes = 20000;
const int attachmentMaximumDavResponses = 4096;

enum AttachmentProbeClassification {
  confirmed,
  deterministicFailure,
  reauthenticationRequired,
  transientFailure,
}

enum AttachmentFinalizeClassification {
  accepted,
  deterministicFailure,
  reauthenticationRequired,
  ambiguous,
}

enum AttachmentDavClassification {
  success,
  destinationCollision,
  deterministicFailure,
  quotaExceeded,
  permissionDenied,
  reauthenticationRequired,
  transientFailure,
}

sealed class AttachmentResponse {
  const AttachmentResponse();

  AttachmentRequest get request;
}

final class AttachmentRename {
  AttachmentRename({required this.requestedName, required this.actualName}) {
    if (!_validFileName(requestedName) || !_validFileName(actualName)) {
      _responseFailure(r'$.ocs.data.renames');
    }
  }

  final String requestedName;
  final String actualName;

  @override
  String toString() => 'AttachmentRename(<redacted>)';
}

final class AttachmentProbeResponse extends AttachmentResponse {
  AttachmentProbeResponse._({
    required this.request,
    required this.classification,
    required this.folder,
    required Iterable<AttachmentRename> renames,
  }) : renames = List.unmodifiable(renames);

  @override
  final AttachmentProbeRequest request;
  final AttachmentProbeClassification classification;
  final DavRelativePath? folder;
  final List<AttachmentRename> renames;

  @override
  String toString() =>
      'AttachmentProbeResponse(classification: ${classification.name}, '
      'renameCount: ${renames.length}, folder: <redacted>)';
}

final class AttachmentFinalizeResponse extends AttachmentResponse {
  AttachmentFinalizeResponse._({
    required this.request,
    required this.classification,
    required Iterable<AttachmentRename> renames,
  }) : renames = List.unmodifiable(renames);

  @override
  final AttachmentFinalizeRequest request;
  final AttachmentFinalizeClassification classification;
  final List<AttachmentRename> renames;

  @override
  String toString() =>
      'AttachmentFinalizeResponse(classification: ${classification.name}, '
      'renameCount: ${renames.length})';
}

final class DavChunkManifest {
  DavChunkManifest._(Iterable<DavChunkRange> source)
    : chunks = List.unmodifiable(source) {
    DavChunkRange? previous;
    for (final chunk in chunks) {
      if (previous != null &&
          (previous.compareTo(chunk) >= 0 || previous.overlaps(chunk))) {
        _davXmlFailure(r'$.dav.multistatus');
      }
      previous = chunk;
    }
  }

  static final empty = DavChunkManifest._(const <DavChunkRange>[]);

  final List<DavChunkRange> chunks;

  bool contains(DavChunkRange range) => chunks.contains(range);

  void validateAgainst({
    required AttachmentUploadPolicy policy,
    required int fileSize,
  }) {
    for (final chunk in chunks) {
      if (chunk.start % policy.chunkSizeBytes != 0 ||
          policy.chunkAt(chunk.start, fileSize: fileSize) != chunk) {
        _davXmlFailure(r'$.dav.multistatus');
      }
    }
  }

  List<DavChunkRange> missingRanges({
    required AttachmentUploadPolicy policy,
    required int fileSize,
  }) {
    validateAgainst(policy: policy, fileSize: fileSize);
    final result = <DavChunkRange>[];
    var verifiedIndex = 0;
    for (var start = 0; start < fileSize; start += policy.chunkSizeBytes) {
      final expected = policy.chunkAt(start, fileSize: fileSize);
      if (verifiedIndex < chunks.length && chunks[verifiedIndex] == expected) {
        verifiedIndex++;
      } else {
        result.add(expected);
      }
    }
    return List.unmodifiable(result);
  }

  @override
  String toString() => 'DavChunkManifest(chunkCount: ${chunks.length})';
}

final class AttachmentDavResponse extends AttachmentResponse {
  const AttachmentDavResponse._({
    required this.request,
    required this.classification,
    required this.manifest,
  });

  @override
  final AttachmentDavRequest request;
  final AttachmentDavClassification classification;
  final DavChunkManifest? manifest;

  @override
  String toString() =>
      'AttachmentDavResponse(classification: ${classification.name}, '
      'hasManifest: ${manifest != null})';
}

AttachmentProbeResponse decodeAttachmentProbeResponse({
  required AttachmentProbeRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  _validateHttpStatus(statusCode);
  final envelope = _decodeOcsEnvelope(body);
  if (statusCode == 200 && envelope.isSuccess(200)) {
    final data = requireObject(
      envelope.data,
      path: r'$.ocs.data',
      code: TalkProtocolErrorCode.invalidAttachmentResponse,
    );
    final folder = DavRelativePath.parse(
      data['folder'],
      path: r'$.ocs.data.folder',
    );
    final renames = _decodeRenames(data['renames'], maximum: 16);
    return AttachmentProbeResponse._(
      request: request,
      classification: AttachmentProbeClassification.confirmed,
      folder: folder,
      renames: renames,
    );
  }
  if (!_isMatchingOcsFailure(statusCode, envelope)) {
    _responseFailure(r'$.ocs.meta');
  }
  requireObject(
    envelope.data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidAttachmentResponse,
  );
  final classification = statusCode == 401
      ? AttachmentProbeClassification.reauthenticationRequired
      : _isDeterministicOcsFailure(statusCode)
      ? AttachmentProbeClassification.deterministicFailure
      : AttachmentProbeClassification.transientFailure;
  return AttachmentProbeResponse._(
    request: request,
    classification: classification,
    folder: null,
    renames: const <AttachmentRename>[],
  );
}

AttachmentFinalizeResponse decodeAttachmentFinalizeResponse({
  required AttachmentFinalizeRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  _validateHttpStatus(statusCode);
  final envelope = _decodeOcsEnvelope(body);
  if (statusCode == 200 && envelope.isSuccess(200)) {
    final data = requireObject(
      envelope.data,
      path: r'$.ocs.data',
      code: TalkProtocolErrorCode.invalidAttachmentResponse,
    );
    final renames = _decodeRenames(data['renames'], minimum: 1, maximum: 1);
    return AttachmentFinalizeResponse._(
      request: request,
      classification: AttachmentFinalizeClassification.accepted,
      renames: renames,
    );
  }
  if (!_isMatchingOcsFailure(statusCode, envelope)) {
    return AttachmentFinalizeResponse._(
      request: request,
      classification: AttachmentFinalizeClassification.ambiguous,
      renames: const <AttachmentRename>[],
    );
  }
  requireObject(
    envelope.data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidAttachmentResponse,
  );
  final classification = statusCode == 401
      ? AttachmentFinalizeClassification.reauthenticationRequired
      : _isDeterministicOcsFailure(statusCode)
      ? AttachmentFinalizeClassification.deterministicFailure
      : AttachmentFinalizeClassification.ambiguous;
  return AttachmentFinalizeResponse._(
    request: request,
    classification: classification,
    renames: const <AttachmentRename>[],
  );
}

AttachmentDavResponse decodeAttachmentDavResponse({
  required AttachmentDavRequest request,
  required int statusCode,
  required Uint8List body,
  int? fileSize,
}) {
  _validateHttpStatus(statusCode);
  if (body.length > attachmentMaximumDavXmlBytes) {
    _responseFailure(r'$.body');
  }
  if (_davStatusIsSuccess(request.step, statusCode)) {
    DavChunkManifest? manifest;
    if (request.step == AttachmentRequestStep.chunkPropfind) {
      if (fileSize == null || fileSize < 1) {
        _responseFailure(r'$.fileSize');
      }
      manifest = _decodeDavChunkManifest(
        request: request,
        body: body,
        fileSize: fileSize,
      );
    }
    return AttachmentDavResponse._(
      request: request,
      classification: AttachmentDavClassification.success,
      manifest: manifest,
    );
  }
  final classification =
      statusCode == 412 &&
          <AttachmentRequestStep>{
            AttachmentRequestStep.normalPut,
            AttachmentRequestStep.chunkMove,
          }.contains(request.step)
      ? AttachmentDavClassification.destinationCollision
      : statusCode == 401
      ? AttachmentDavClassification.reauthenticationRequired
      : statusCode == 507
      ? AttachmentDavClassification.quotaExceeded
      : statusCode == 403
      ? AttachmentDavClassification.permissionDenied
      : statusCode == 429 || statusCode >= 500
      ? AttachmentDavClassification.transientFailure
      : AttachmentDavClassification.deterministicFailure;
  return AttachmentDavResponse._(
    request: request,
    classification: classification,
    manifest: null,
  );
}

DavChunkManifest _decodeDavChunkManifest({
  required AttachmentDavRequest request,
  required Uint8List body,
  required int fileSize,
}) {
  if (body.length > attachmentMaximumDavXmlBytes) {
    _davXmlFailure(r'$.dav.body');
  }
  if (_hasForbiddenXmlEncodingPrefix(body) || body.contains(0)) {
    _davXmlFailure(r'$.dav.body');
  }
  String source;
  try {
    source = utf8.decode(body, allowMalformed: false);
  } on FormatException {
    _davXmlFailure(r'$.dav.body');
  }
  final upper = source.toUpperCase();
  if (upper.contains('<!DOCTYPE') || upper.contains('<!ENTITY')) {
    _davXmlFailure(r'$.dav.body');
  }
  _validateXmlDeclaration(source);
  _validateXmlEvents(source);

  XmlDocument document;
  try {
    document = XmlDocument.parse(source);
  } on XmlException {
    _davXmlFailure(r'$.dav.body');
  }
  _validateXmlBounds(document);

  final XmlElement root;
  try {
    root = document.rootElement;
  } on Object {
    _davXmlFailure(r'$.dav.multistatus');
  }
  if (root.name.local != 'multistatus' || root.namespaceUri != 'DAV:') {
    _davXmlFailure(r'$.dav.multistatus');
  }
  final responses = root
      .findElements('response', namespaceUri: 'DAV:')
      .toList(growable: false);
  if (responses.length > attachmentMaximumDavResponses) {
    _davXmlFailure(r'$.dav.multistatus');
  }

  final chunks = <DavChunkRange>[];
  final names = <String>{};
  for (final response in responses) {
    final hrefs = response
        .findElements('href', namespaceUri: 'DAV:')
        .toList(growable: false);
    if (hrefs.length != 1) {
      _davXmlFailure(r'$.dav.multistatus.response.href');
    }
    final resourceName = _expectedDavResourceName(
      request,
      hrefs.single.innerText.trim(),
    );
    if (resourceName == null || resourceName == '.file') {
      continue;
    }
    if (!names.add(resourceName)) {
      _davXmlFailure(r'$.dav.multistatus.response.href');
    }

    final lengths = <String>[];
    for (final propstat in response.findElements(
      'propstat',
      namespaceUri: 'DAV:',
    )) {
      final statuses = propstat
          .findElements('status', namespaceUri: 'DAV:')
          .toList(growable: false);
      if (statuses.length != 1 ||
          !_isDavSuccessStatus(statuses.single.innerText)) {
        continue;
      }
      final properties = propstat
          .findElements('prop', namespaceUri: 'DAV:')
          .toList(growable: false);
      if (properties.length != 1) {
        _davXmlFailure(r'$.dav.multistatus.response.propstat');
      }
      for (final length in properties.single.findElements(
        'getcontentlength',
        namespaceUri: 'DAV:',
      )) {
        lengths.add(length.innerText.trim());
      }
    }
    if (lengths.length != 1 ||
        !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(lengths.single)) {
      _davXmlFailure(r'$.dav.multistatus.response.getcontentlength');
    }
    final contentLength = int.tryParse(lengths.single);
    if (contentLength == null) {
      _davXmlFailure(r'$.dav.multistatus.response.getcontentlength');
    }
    final range = DavChunkRange.parse(
      resourceName,
      fileSize: fileSize,
      path: r'$.dav.multistatus.response.href',
    );
    if (range.length != contentLength) {
      _davXmlFailure(r'$.dav.multistatus.response.getcontentlength');
    }
    chunks.add(range);
  }
  chunks.sort();
  DavChunkRange? previous;
  for (final chunk in chunks) {
    if (previous != null && previous.overlaps(chunk)) {
      _davXmlFailure(r'$.dav.multistatus');
    }
    previous = chunk;
  }
  return DavChunkManifest._(chunks);
}

bool _hasForbiddenXmlEncodingPrefix(Uint8List body) {
  if (body.length >= 3 &&
      body[0] == 0xef &&
      body[1] == 0xbb &&
      body[2] == 0xbf) {
    return true;
  }
  return body.length >= 2 &&
      ((body[0] == 0xff && body[1] == 0xfe) ||
          (body[0] == 0xfe && body[1] == 0xff));
}

void _validateXmlDeclaration(String source) {
  final declaration = RegExp(
    r'^<\?xml\s+[^?]*(?:\?(?!>)[^?]*)*\?>',
    caseSensitive: false,
  ).firstMatch(source);
  final declarationIndex = source.toLowerCase().indexOf('<?xml');
  if (declarationIndex >= 0 && declaration == null) {
    _davXmlFailure(r'$.dav.body');
  }
  if (declaration == null) {
    return;
  }
  final encoding = RegExp(
    r'''\bencoding\s*=\s*(['"])([^'"]+)\1''',
    caseSensitive: false,
  ).firstMatch(declaration.group(0)!);
  if (encoding != null && encoding.group(2)!.toLowerCase() != 'utf-8') {
    _davXmlFailure(r'$.dav.body');
  }
}

void _validateXmlEvents(String source) {
  var depth = 0;
  var nodes = 0;
  var responses = 0;
  try {
    for (final event in parseEvents(
      source,
      validateNesting: true,
      validateNamespace: true,
      validateDocument: true,
      withNamespace: true,
    )) {
      nodes++;
      if (event is XmlDoctypeEvent) {
        _davXmlFailure(r'$.dav.body');
      }
      if (event is XmlStartElementEvent) {
        depth++;
        nodes += event.attributes.length;
        if (event.localName == 'response' && event.namespaceUri == 'DAV:') {
          responses++;
        }
        if (event.isSelfClosing) {
          depth--;
        }
      } else if (event is XmlEndElementEvent) {
        depth--;
      }
      if (depth < 0 ||
          depth > attachmentMaximumDavXmlDepth ||
          nodes > attachmentMaximumDavXmlNodes ||
          responses > attachmentMaximumDavResponses) {
        _davXmlFailure(r'$.dav.body');
      }
    }
  } on XmlException {
    _davXmlFailure(r'$.dav.body');
  }
  if (depth != 0) {
    _davXmlFailure(r'$.dav.body');
  }
}

String? _expectedDavResourceName(AttachmentDavRequest request, String rawHref) {
  if (rawHref.isEmpty || rawHref.length > 8192) {
    _davXmlFailure(r'$.dav.multistatus.response.href');
  }
  final parsed = Uri.tryParse(rawHref);
  if (parsed == null ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      (!parsed.hasScheme && !rawHref.startsWith('/'))) {
    _davXmlFailure(r'$.dav.multistatus.response.href');
  }
  final resolved = parsed.hasScheme
      ? parsed
      : request.server.uri.resolveUri(parsed);
  if (resolved.userInfo.isNotEmpty || !request.server.hasSameOrigin(resolved)) {
    _davXmlFailure(r'$.dav.multistatus.response.href');
  }
  final expected = request.uri.pathSegments;
  final actual = resolved.pathSegments.toList(growable: true);
  if (actual.isNotEmpty && actual.last.isEmpty) {
    actual.removeLast();
  }
  if (_sameSegments(expected, actual)) {
    return null;
  }
  if (actual.length != expected.length + 1 ||
      !_sameSegments(expected, actual.sublist(0, expected.length))) {
    _davXmlFailure(r'$.dav.multistatus.response.href');
  }
  final name = actual.last;
  if (name == '.file' || RegExp(r'^[0-9]{16}-[0-9]{16}$').hasMatch(name)) {
    return name;
  }
  _davXmlFailure(r'$.dav.multistatus.response.href');
}

void _validateXmlBounds(XmlNode root) {
  final pending = <_XmlVisit>[_XmlVisit(root, 0)];
  var nodes = 0;
  while (pending.isNotEmpty) {
    final visit = pending.removeLast();
    nodes++;
    if (visit.depth > attachmentMaximumDavXmlDepth ||
        nodes > attachmentMaximumDavXmlNodes) {
      _davXmlFailure(r'$.dav.body');
    }
    if (visit.node is XmlElement) {
      nodes += (visit.node as XmlElement).attributes.length;
      if (nodes > attachmentMaximumDavXmlNodes) {
        _davXmlFailure(r'$.dav.body');
      }
    }
    for (final child in visit.node.children) {
      pending.add(_XmlVisit(child, visit.depth + 1));
    }
  }
}

bool _isDavSuccessStatus(String value) => RegExp(
  r'^HTTP/[0-9]+(?:\.[0-9]+)? 200(?: |$)',
  caseSensitive: false,
).hasMatch(value.trim());

bool _davStatusIsSuccess(AttachmentRequestStep step, int statusCode) =>
    switch (step) {
      AttachmentRequestStep.normalPut ||
      AttachmentRequestStep.chunkPut => statusCode == 201 || statusCode == 204,
      AttachmentRequestStep.chunkMkcol =>
        statusCode == 201 || statusCode == 405,
      AttachmentRequestStep.chunkPropfind => statusCode == 207,
      AttachmentRequestStep.chunkMove => statusCode == 201 || statusCode == 204,
      AttachmentRequestStep.cleanupChunkSession ||
      AttachmentRequestStep.cleanupDraftFile =>
        statusCode == 204 || statusCode == 404,
      AttachmentRequestStep.probe || AttachmentRequestStep.finalize => false,
    };

List<AttachmentRename> _decodeRenames(
  Object? raw, {
  int minimum = 0,
  required int maximum,
}) {
  final values = requireList(
    raw,
    path: r'$.ocs.data.renames',
    code: TalkProtocolErrorCode.invalidAttachmentResponse,
  );
  if (values.length < minimum || values.length > maximum) {
    _responseFailure(r'$.ocs.data.renames');
  }
  final result = <AttachmentRename>[];
  for (var index = 0; index < values.length; index++) {
    final entry = requireObject(
      values[index],
      path: r'$.ocs.data.renames[]',
      code: TalkProtocolErrorCode.invalidAttachmentResponse,
    );
    if (entry.length != 1) {
      _responseFailure(r'$.ocs.data.renames[]');
    }
    final item = entry.entries.single;
    final actual = requireString(
      item.value,
      path: r'$.ocs.data.renames[].<value>',
      code: TalkProtocolErrorCode.invalidAttachmentResponse,
      minLength: 1,
      maxLength: 255,
    );
    result.add(AttachmentRename(requestedName: item.key, actualName: actual));
  }
  return List.unmodifiable(result);
}

_AttachmentOcsEnvelope _decodeOcsEnvelope(Uint8List body) {
  if (body.length > attachmentMaximumResponseBytes) {
    _responseFailure(r'$.body');
  }
  String source;
  try {
    source = utf8.decode(body, allowMalformed: false);
  } on FormatException {
    _responseFailure(r'$.body');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    _responseFailure(r'$.body');
  }
  final frozen = JsonFreezeSession(
    maximumDepth: 32,
    maximumNodes: 4096,
    errorCode: TalkProtocolErrorCode.invalidAttachmentResponse,
    errorPath: r'$.body',
  ).freeze(decoded);
  final root = requireObject(
    frozen,
    path: r'$',
    code: TalkProtocolErrorCode.invalidAttachmentResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidAttachmentResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidAttachmentResponse,
  );
  return _AttachmentOcsEnvelope(
    status: requireString(
      meta['status'],
      path: r'$.ocs.meta.status',
      code: TalkProtocolErrorCode.invalidAttachmentResponse,
      minLength: 1,
      maxLength: 128,
    ),
    statusCode: requireInt(
      meta['statuscode'],
      path: r'$.ocs.meta.statuscode',
      code: TalkProtocolErrorCode.invalidAttachmentResponse,
      minimum: 0,
      maximum: 999,
    ),
    data: ocs['data'],
  );
}

bool _isMatchingOcsFailure(int httpStatus, _AttachmentOcsEnvelope envelope) =>
    httpStatus == envelope.statusCode && envelope.status == 'failure';

bool _isDeterministicOcsFailure(int status) =>
    status == 400 ||
    status == 403 ||
    status == 404 ||
    status == 422 ||
    status == 501 ||
    status == 507;

void _validateHttpStatus(int statusCode) {
  if (statusCode < 100 ||
      statusCode > 599 ||
      (statusCode >= 300 && statusCode < 400)) {
    protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    );
  }
}

bool _sameSegments(List<String> left, List<String> right) {
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

bool _validFileName(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    value.trim() == value &&
    value != '.' &&
    value != '..' &&
    !value.contains('/') &&
    !value.contains(r'\') &&
    !value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentResponse, path);

Never _davXmlFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentDavXml, path);

final class _AttachmentOcsEnvelope {
  const _AttachmentOcsEnvelope({
    required this.status,
    required this.statusCode,
    required this.data,
  });

  final String status;
  final int statusCode;
  final Object? data;

  bool isSuccess(int expectedStatusCode) =>
      status == 'ok' && statusCode == expectedStatusCode;
}

final class _XmlVisit {
  const _XmlVisit(this.node, this.depth);

  final XmlNode node;
  final int depth;
}
