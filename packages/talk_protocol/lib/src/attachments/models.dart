import '../chat/identifiers.dart';
import '../identifiers.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';

const int attachmentMaximumSourceBytes = 1 << 50;
const int attachmentMaximumChunkCount = 100000;

/// MIME types a voice-message source may legitimately carry. `audio/mp4` is
/// the compressed AAC-LC/M4A format the Flutter client records by default
/// (see `voiceRecordingMimeType` in the mobile app's platform layer);
/// `audio/wav` and `audio/mpeg` remain accepted for sources produced by
/// older builds or other Talk clients.
const Set<String> attachmentSupportedVoiceMimeTypes = <String>{
  'audio/mp4',
  'audio/mpeg',
  'audio/wav',
};

enum AttachmentSourceOwnership { appOwnedCopy, persistableUri }

enum AttachmentMessageKind { file, voice }

enum AttachmentUploadMode { normal, chunked }

final class PreparedAttachmentSource {
  PreparedAttachmentSource({
    required this.handle,
    required this.ownership,
    required this.byteLength,
    required this.sha256,
    required this.mimeType,
    required this.displayName,
  }) {
    if (byteLength < 1 || byteLength > attachmentMaximumSourceBytes) {
      _modelFailure(r'$.source.byteLength');
    }
    if (!_validMimeType(mimeType)) {
      _modelFailure(r'$.source.mimeType');
    }
    if (!_validDisplayName(displayName)) {
      _modelFailure(r'$.source.displayName');
    }
  }

  final AttachmentSourceHandle handle;
  final AttachmentSourceOwnership ownership;
  final int byteLength;
  final AttachmentSha256 sha256;
  final String mimeType;
  final String displayName;

  @override
  String toString() =>
      'PreparedAttachmentSource(ownership: ${ownership.name}, '
      'byteLength: $byteLength, handle: <redacted>, sha256: <redacted>, '
      'mimeType: <redacted>, displayName: <redacted>)';
}

final class AttachmentSourceObservation {
  AttachmentSourceObservation({
    required this.handle,
    required this.byteLength,
    required this.sha256,
  }) {
    if (byteLength < 1 || byteLength > attachmentMaximumSourceBytes) {
      _modelFailure(r'$.sourceObservation.byteLength');
    }
  }

  final AttachmentSourceHandle handle;
  final int byteLength;
  final AttachmentSha256 sha256;

  bool matches(PreparedAttachmentSource source) =>
      handle == source.handle &&
      byteLength == source.byteLength &&
      sha256 == source.sha256;

  @override
  String toString() =>
      'AttachmentSourceObservation(byteLength: $byteLength, '
      'handle: <redacted>, sha256: <redacted>)';
}

final class AttachmentMetadata {
  AttachmentMetadata({
    required this.kind,
    String? caption,
    required this.replyTo,
    required this.threadId,
    String? threadTitle,
    required this.silent,
  }) : caption = _trimmedOptional(caption),
       threadTitle = _trimmedOptional(threadTitle) {
    if (this.caption != null && this.caption!.length > 4000) {
      _modelFailure(r'$.metadata.caption');
    }
    if (replyTo != null && replyTo! < 1) {
      _modelFailure(r'$.metadata.replyTo');
    }
    if (threadId != null && threadId! < 1) {
      _modelFailure(r'$.metadata.threadId');
    }
    if ((this.threadTitle != null && threadId == null) ||
        (this.threadTitle != null && this.threadTitle!.length > 200)) {
      _modelFailure(r'$.metadata.threadTitle');
    }
  }

  final AttachmentMessageKind kind;
  final String? caption;
  final int? replyTo;
  final int? threadId;
  final String? threadTitle;
  final bool silent;

  String get expectedMessageType => switch (kind) {
    AttachmentMessageKind.file => 'comment',
    AttachmentMessageKind.voice => 'voice-message',
  };

  bool supportsSource(PreparedAttachmentSource source) =>
      kind != AttachmentMessageKind.voice ||
      attachmentSupportedVoiceMimeTypes.contains(source.mimeType);

  @override
  String toString() =>
      'AttachmentMetadata(kind: ${kind.name}, hasCaption: ${caption != null}, '
      'hasReply: ${replyTo != null}, threadScoped: ${threadId != null}, '
      'silent: $silent)';
}

final class AttachmentUploadPolicy {
  AttachmentUploadPolicy({
    required this.normalUploadMaximumBytes,
    required this.chunkSizeBytes,
  }) {
    if (normalUploadMaximumBytes < 1 ||
        normalUploadMaximumBytes > attachmentMaximumSourceBytes ||
        chunkSizeBytes < 1 ||
        chunkSizeBytes > attachmentMaximumSourceBytes) {
      _modelFailure(r'$.uploadPolicy');
    }
  }

  final int normalUploadMaximumBytes;
  final int chunkSizeBytes;

  AttachmentUploadMode modeFor(int byteLength) =>
      byteLength <= normalUploadMaximumBytes
      ? AttachmentUploadMode.normal
      : AttachmentUploadMode.chunked;

  int chunkCountFor(int byteLength) =>
      (byteLength + chunkSizeBytes - 1) ~/ chunkSizeBytes;

  DavChunkRange chunkAt(int start, {required int fileSize}) {
    if (start < 0 || start >= fileSize || start % chunkSizeBytes != 0) {
      _modelFailure(r'$.chunk.start');
    }
    final requestedEnd = start + chunkSizeBytes - 1;
    final end = requestedEnd < fileSize ? requestedEnd : fileSize - 1;
    return DavChunkRange(start: start, end: end, fileSize: fileSize);
  }

  @override
  String toString() =>
      'AttachmentUploadPolicy(normalLimit: $normalUploadMaximumBytes, '
      'chunkSize: $chunkSizeBytes)';
}

final class AttachmentJobDraft {
  AttachmentJobDraft({
    required this.jobId,
    required this.roomToken,
    required this.referenceId,
    required this.source,
    required this.metadata,
    required this.enqueueSequence,
    required this.policy,
    required this.uploadSessionId,
  }) : uploadMode = policy.modeFor(source.byteLength) {
    if (enqueueSequence < 1) {
      _modelFailure(r'$.draft.enqueueSequence');
    }
    if (uploadMode == AttachmentUploadMode.chunked) {
      if (uploadSessionId == null ||
          policy.chunkCountFor(source.byteLength) >
              attachmentMaximumChunkCount) {
        _modelFailure(r'$.draft.uploadSessionId');
      }
    } else if (uploadSessionId != null) {
      _modelFailure(r'$.draft.uploadSessionId');
    }
    if (!metadata.supportsSource(source)) {
      _modelFailure(r'$.draft.source.mimeType');
    }
  }

  final AttachmentJobId jobId;
  final ConversationToken roomToken;
  final ChatReferenceId referenceId;
  final PreparedAttachmentSource source;
  final AttachmentMetadata metadata;
  final int enqueueSequence;
  final AttachmentUploadPolicy policy;
  final DavUploadSessionId? uploadSessionId;
  final AttachmentUploadMode uploadMode;

  String get expectedMessageType => metadata.expectedMessageType;

  String get stableTemporaryName => '${jobId.value}.upload';

  @override
  String toString() =>
      'AttachmentJobDraft(mode: ${uploadMode.name}, sequence: '
      '$enqueueSequence, source: <redacted>, referenceId: <redacted>)';
}

bool _validMimeType(String value) {
  if (value.isEmpty ||
      value.length > 255 ||
      value.trim() != value ||
      value.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
    return false;
  }
  return RegExp(
    r"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$",
  ).hasMatch(value);
}

bool _validDisplayName(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    value.trim() == value &&
    value != '.' &&
    value != '..' &&
    !value.contains('/') &&
    !value.contains(r'\') &&
    !value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

String? _trimmedOptional(String? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Never _modelFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidAttachmentModel, path);
