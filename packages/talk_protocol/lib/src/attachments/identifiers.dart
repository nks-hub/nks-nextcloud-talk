import '../json_value.dart';
import '../protocol_exception.dart';

final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _chunkNamePattern = RegExp(r'^([0-9]{16})-([0-9]{16})$');

final class AttachmentJobId {
  AttachmentJobId._(this.value);

  factory AttachmentJobId.parse(Object? value) =>
      AttachmentJobId._(_uuidV4(value, path: r'$.jobId'));

  final String value;

  @override
  bool operator ==(Object other) =>
      other is AttachmentJobId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AttachmentJobId(<redacted>)';
}

final class AttachmentRequestId {
  AttachmentRequestId._(this.value);

  factory AttachmentRequestId.parse(Object? value) {
    final identifier = requireString(
      value,
      path: r'$.requestId',
      code: TalkProtocolErrorCode.invalidAttachmentIdentifier,
      minLength: 1,
      maxLength: 256,
    );
    if (identifier.trim() != identifier || _hasControlCharacter(identifier)) {
      _identifierFailure(r'$.requestId');
    }
    return AttachmentRequestId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is AttachmentRequestId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AttachmentRequestId(<redacted>)';
}

final class AttachmentSourceHandle {
  AttachmentSourceHandle._(this.value);

  factory AttachmentSourceHandle.parse(Object? value) {
    final handle = requireString(
      value,
      path: r'$.source.handle',
      code: TalkProtocolErrorCode.invalidAttachmentIdentifier,
      minLength: 1,
      maxLength: 4096,
    );
    if (handle.trim() != handle || _hasControlCharacter(handle)) {
      _identifierFailure(r'$.source.handle');
    }
    return AttachmentSourceHandle._(handle);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is AttachmentSourceHandle && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AttachmentSourceHandle(<redacted>)';
}

final class AttachmentSha256 {
  AttachmentSha256._(this.value);

  factory AttachmentSha256.parse(Object? value) {
    final checksum = requireString(
      value,
      path: r'$.source.sha256',
      code: TalkProtocolErrorCode.invalidAttachmentIdentifier,
      minLength: 64,
      maxLength: 64,
    );
    if (!_sha256Pattern.hasMatch(checksum)) {
      _identifierFailure(r'$.source.sha256');
    }
    return AttachmentSha256._(checksum);
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is AttachmentSha256 && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'AttachmentSha256(<redacted>)';
}

final class DavUploadSessionId {
  DavUploadSessionId._(this.value);

  factory DavUploadSessionId.parse(Object? value) =>
      DavUploadSessionId._(_uuidV4(value, path: r'$.uploadSessionId'));

  final String value;

  @override
  bool operator ==(Object other) =>
      other is DavUploadSessionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'DavUploadSessionId(<redacted>)';
}

final class DavUserId {
  DavUserId._(this.value);

  factory DavUserId.parse(Object? value) {
    final identifier = requireString(
      value,
      path: r'$.davUserId',
      code: TalkProtocolErrorCode.invalidAttachmentIdentifier,
      minLength: 1,
      maxLength: 256,
    );
    if (identifier.trim() != identifier ||
        identifier == '.' ||
        identifier == '..' ||
        identifier.contains('/') ||
        identifier.contains(r'\') ||
        _hasControlCharacter(identifier)) {
      _identifierFailure(r'$.davUserId');
    }
    return DavUserId._(identifier);
  }

  final String value;

  @override
  bool operator ==(Object other) => other is DavUserId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'DavUserId(<redacted>)';
}

final class DavRelativePath {
  DavRelativePath._(this.segments);

  factory DavRelativePath.parse(Object? value, {String path = r'$.davPath'}) {
    final raw = requireString(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidAttachmentDavPath,
      minLength: 1,
      maxLength: 4096,
    );
    if (raw.startsWith('/') ||
        raw.endsWith('/') ||
        raw.contains(r'\') ||
        raw.contains('%') ||
        raw.contains('?') ||
        raw.contains('#') ||
        _hasControlCharacter(raw)) {
      _davPathFailure(path);
    }
    final parts = raw.split('/');
    if (parts.length > 64 ||
        parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.length > 255 ||
              _hasControlCharacter(part),
        )) {
      _davPathFailure(path);
    }
    return DavRelativePath._(List<String>.unmodifiable(parts));
  }

  final List<String> segments;

  String get value => segments.join('/');

  DavRelativePath append(String segment) {
    final encoded = DavRelativePath.parse(segment, path: r'$.davPath.segment');
    if (encoded.segments.length != 1) {
      _davPathFailure(r'$.davPath.segment');
    }
    return DavRelativePath.parse(
      <String>[...segments, segment].join('/'),
      path: r'$.davPath',
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! DavRelativePath || other.segments.length != segments.length) {
      return false;
    }
    for (var index = 0; index < segments.length; index++) {
      if (other.segments[index] != segments[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(segments);

  @override
  String toString() => 'DavRelativePath(<redacted>)';
}

final class DavChunkRange implements Comparable<DavChunkRange> {
  DavChunkRange({
    required this.start,
    required this.end,
    required int fileSize,
  }) {
    if (start < 0 || end < start || end >= fileSize || end > 9999999999999999) {
      _identifierFailure(r'$.chunkRange');
    }
  }

  factory DavChunkRange.parse(
    Object? value, {
    required int fileSize,
    String path = r'$.chunkRange',
  }) {
    final name = requireString(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidAttachmentIdentifier,
      minLength: 33,
      maxLength: 33,
    );
    final match = _chunkNamePattern.firstMatch(name);
    if (match == null) {
      _identifierFailure(path);
    }
    return DavChunkRange(
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      fileSize: fileSize,
    );
  }

  final int start;
  final int end;

  int get length => end - start + 1;

  String get wireName =>
      '${start.toString().padLeft(16, '0')}-${end.toString().padLeft(16, '0')}';

  bool overlaps(DavChunkRange other) =>
      start <= other.end && other.start <= end;

  @override
  int compareTo(DavChunkRange other) => start.compareTo(other.start);

  @override
  bool operator ==(Object other) =>
      other is DavChunkRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'DavChunkRange(start: $start, length: $length)';
}

String _uuidV4(Object? value, {required String path}) {
  final identifier = requireString(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidAttachmentIdentifier,
    minLength: 36,
    maxLength: 36,
  );
  if (!_uuidV4Pattern.hasMatch(identifier)) {
    _identifierFailure(path);
  }
  return identifier;
}

bool _hasControlCharacter(String value) =>
    value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

Never _identifierFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentIdentifier, path);

Never _davPathFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentDavPath, path);
