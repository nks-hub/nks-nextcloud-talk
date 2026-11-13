import 'dart:convert';
import 'dart:typed_data';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidOwnTalkExtensionsResponse;
const int ownTalkExtensionsMaximumWireBytes = 64 * 1024;

/// Largest background image body accepted from the server. Uploads are capped
/// at 10 MiB and the stored copy is scaled down, so this is generous.
const int ownTalkExtensionsMaximumImageBytes = 16 * 1024 * 1024;

/// Why an extension request did not produce a document.
enum OwnTalkExtensionsFailureKind {
  /// `401`: the app password is no longer valid.
  reauthenticationRequired,

  /// `400`: the server rejected the input (`invalid_value`, `unknown_field`).
  rejected,

  /// `403`: `field_forbidden`, or `source_mismatch` on a membership conflict.
  forbidden,

  /// `404`: no such conversation, or the caller is not a participant.
  notFound,

  /// `428`: the `If-Match` header was missing or malformed.
  preconditionRequired,

  /// `413`: the upload is over the server's size limit.
  payloadTooLarge,

  /// `415`: the upload is not JPEG, PNG or WebP.
  unsupportedMediaType,

  /// `429`
  rateLimited,

  /// `507`: the server's storage for background images is full.
  quotaExceeded,

  /// `503`: Talk is missing or broken on the server.
  unavailable,
}

sealed class OwnTalkSettingsFetchResult {
  const OwnTalkSettingsFetchResult();
}

final class OwnTalkSettingsLoaded extends OwnTalkSettingsFetchResult {
  const OwnTalkSettingsLoaded(this.document, {this.etag});

  final OwnTalkRoomSettings document;

  /// The `ETag` header exactly as received, or `null` when it was missing or
  /// malformed. Send it back as `If-None-Match`; do not derive it.
  final String? etag;
}

/// `304`: the cached revision is still current.
final class OwnTalkSettingsNotModified extends OwnTalkSettingsFetchResult {
  const OwnTalkSettingsNotModified();
}

/// `404`: no shared settings can be shown for this conversation.
final class OwnTalkSettingsMissing extends OwnTalkSettingsFetchResult {
  const OwnTalkSettingsMissing();
}

final class OwnTalkSettingsFetchFailure extends OwnTalkSettingsFetchResult {
  const OwnTalkSettingsFetchFailure(this.kind, {this.retryAfter});

  final OwnTalkExtensionsFailureKind kind;

  /// `Retry-After` of a `429`, in whole seconds, capped at ten minutes.
  final Duration? retryAfter;
}

sealed class OwnTalkSettingsUpdateResult {
  const OwnTalkSettingsUpdateResult();
}

final class OwnTalkSettingsSaved extends OwnTalkSettingsUpdateResult {
  const OwnTalkSettingsSaved(this.document, {this.etag});

  final OwnTalkRoomSettings document;

  /// See [OwnTalkSettingsLoaded.etag].
  final String? etag;
}

/// `412 revision_conflict`: someone changed one of the fields meanwhile.
final class OwnTalkSettingsConflict extends OwnTalkSettingsUpdateResult {
  const OwnTalkSettingsConflict({
    required this.current,
    required this.conflictingFields,
  });

  final OwnTalkRoomSettings current;
  final List<OwnTalkSettingField> conflictingFields;
}

final class OwnTalkSettingsUpdateFailure extends OwnTalkSettingsUpdateResult {
  const OwnTalkSettingsUpdateFailure(this.kind, {this.errorCode});

  final OwnTalkExtensionsFailureKind kind;

  /// Machine code from `data.error`, for example `field_forbidden`.
  final String? errorCode;
}

OwnTalkSettingsFetchResult decodeFetchOwnTalkRoomSettingsResponse({
  required FetchOwnTalkRoomSettingsRequest request,
  required int statusCode,
  required Uint8List body,
  Map<String, String> headers = const {},
}) {
  switch (statusCode) {
    case 200:
      final document = OwnTalkRoomSettings.fromJson(_decodeOcsData(body));
      if (document.roomToken != request.roomToken.value) {
        protocolFailure(_responseCode, r'$.ocs.data.roomToken');
      }
      return OwnTalkSettingsLoaded(document, etag: _etagHeader(headers));
    case 304:
      if (request.knownEtag == null) {
        protocolFailure(_responseCode, r'$.statusCode');
      }
      return const OwnTalkSettingsNotModified();
    case 404:
      return const OwnTalkSettingsMissing();
    default:
      return OwnTalkSettingsFetchFailure(
        _failureKind(statusCode),
        retryAfter: statusCode == 429 ? _retryAfterHeader(headers) : null,
      );
  }
}

OwnTalkSettingsUpdateResult decodeUpdateOwnTalkRoomSettingsResponse({
  required UpdateOwnTalkRoomSettingsRequest request,
  required int statusCode,
  required Uint8List body,
  Map<String, String> headers = const {},
}) => _decodeWriteResponse(
  roomToken: request.roomToken.value,
  statusCode: statusCode,
  body: body,
  headers: headers,
);

/// The image upload answers like a merge patch: the document, a `412` with the
/// current one, or one of the failures.
OwnTalkSettingsUpdateResult decodeUploadOwnTalkRoomImageResponse({
  required UploadOwnTalkRoomImageRequest request,
  required int statusCode,
  required Uint8List body,
  Map<String, String> headers = const {},
}) => _decodeWriteResponse(
  roomToken: request.roomToken.value,
  statusCode: statusCode,
  body: body,
  headers: headers,
);

sealed class OwnTalkImageFetchResult {
  const OwnTalkImageFetchResult();
}

final class OwnTalkImageLoaded extends OwnTalkImageFetchResult {
  const OwnTalkImageLoaded(this.bytes);

  final Uint8List bytes;
}

/// `404`: that hash is not the conversation's current image any more.
final class OwnTalkImageMissing extends OwnTalkImageFetchResult {
  const OwnTalkImageMissing();
}

final class OwnTalkImageFetchFailure extends OwnTalkImageFetchResult {
  const OwnTalkImageFetchFailure(this.kind, {this.retryAfter});

  final OwnTalkExtensionsFailureKind kind;
  final Duration? retryAfter;
}

/// The server stores every background as JPEG, so anything else is refused
/// before it reaches the image decoder.
OwnTalkImageFetchResult decodeFetchOwnTalkRoomImageResponse({
  required FetchOwnTalkRoomImageRequest request,
  required int statusCode,
  required Uint8List body,
  Map<String, String> headers = const {},
}) {
  switch (statusCode) {
    case 200:
      if (body.length < 4 ||
          body.length > ownTalkExtensionsMaximumImageBytes ||
          body[0] != 0xFF ||
          body[1] != 0xD8 ||
          body[2] != 0xFF) {
        protocolFailure(_responseCode, r'$.body');
      }
      return OwnTalkImageLoaded(body);
    case 404:
      return const OwnTalkImageMissing();
    default:
      return OwnTalkImageFetchFailure(
        _failureKind(statusCode),
        retryAfter: statusCode == 429 ? _retryAfterHeader(headers) : null,
      );
  }
}

OwnTalkSettingsUpdateResult _decodeWriteResponse({
  required String roomToken,
  required int statusCode,
  required Uint8List body,
  required Map<String, String> headers,
}) {
  switch (statusCode) {
    case 200:
      final document = OwnTalkRoomSettings.fromJson(_decodeOcsData(body));
      if (document.roomToken != roomToken) {
        protocolFailure(_responseCode, r'$.ocs.data.roomToken');
      }
      return OwnTalkSettingsSaved(document, etag: _etagHeader(headers));
    case 412:
      final data = requireObject(
        _decodeOcsData(body),
        path: r'$.ocs.data',
        code: _responseCode,
      );
      if (data['error'] != 'revision_conflict') {
        protocolFailure(_responseCode, r'$.ocs.data.error');
      }
      final current = OwnTalkRoomSettings.fromJson(
        data['current'],
        path: r'$.ocs.data.current',
      );
      if (current.roomToken != roomToken) {
        protocolFailure(_responseCode, r'$.ocs.data.current.roomToken');
      }
      final fields = requireList(
        data['fields'],
        path: r'$.ocs.data.fields',
        code: _responseCode,
      );
      return OwnTalkSettingsConflict(
        current: current,
        conflictingFields: [
          for (var index = 0; index < fields.length; index++)
            ?OwnTalkSettingField.fromWireKey(
              requireString(
                fields[index],
                path: '\$.ocs.data.fields[$index]',
                code: _responseCode,
                minLength: 1,
                maxLength: 64,
              ),
            ),
        ],
      );
    default:
      return OwnTalkSettingsUpdateFailure(
        _failureKind(statusCode),
        errorCode: _optionalErrorCode(body),
      );
  }
}

String? _header(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name) {
      return entry.value;
    }
  }
  return null;
}

String? _etagHeader(Map<String, String> headers) {
  final value = _header(headers, 'etag')?.trim();
  return value != null && isOwnTalkEntityTag(value) ? value : null;
}

/// Delta-seconds form only, like the transport layer reads it.
Duration? _retryAfterHeader(Map<String, String> headers) {
  final seconds = int.tryParse(_header(headers, 'retry-after')?.trim() ?? '');
  if (seconds == null || seconds <= 0) {
    return null;
  }
  return Duration(seconds: seconds > 600 ? 600 : seconds);
}

OwnTalkExtensionsFailureKind _failureKind(int statusCode) =>
    switch (statusCode) {
      400 => OwnTalkExtensionsFailureKind.rejected,
      401 => OwnTalkExtensionsFailureKind.reauthenticationRequired,
      403 => OwnTalkExtensionsFailureKind.forbidden,
      404 => OwnTalkExtensionsFailureKind.notFound,
      413 => OwnTalkExtensionsFailureKind.payloadTooLarge,
      415 => OwnTalkExtensionsFailureKind.unsupportedMediaType,
      428 => OwnTalkExtensionsFailureKind.preconditionRequired,
      429 => OwnTalkExtensionsFailureKind.rateLimited,
      503 => OwnTalkExtensionsFailureKind.unavailable,
      507 => OwnTalkExtensionsFailureKind.quotaExceeded,
      _ => protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      ),
    };

/// Best-effort read of `data.error`; a malformed error body never throws.
String? _optionalErrorCode(Uint8List body) {
  try {
    final data = _decodeOcsData(body);
    if (data is Map<String, Object?> && data['error'] is String) {
      final code = data['error']! as String;
      return code.length <= 64 ? code : null;
    }
  } on TalkProtocolException {
    return null;
  }
  return null;
}

Object? _decodeOcsData(Uint8List body) {
  if (body.isEmpty || body.length > ownTalkExtensionsMaximumWireBytes) {
    protocolFailure(_responseCode, r'$');
  }
  final Object? decoded;
  try {
    decoded = decodeJsonRejectingDuplicateMembers(
      utf8.decode(body, allowMalformed: false),
      code: _responseCode,
      path: r'$',
    );
  } on FormatException {
    protocolFailure(_responseCode, r'$');
  }
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  requireObject(ocs['meta'], path: r'$.ocs.meta', code: _responseCode);
  if (!ocs.containsKey('data')) {
    protocolFailure(_responseCode, r'$.ocs.data');
  }
  return ocs['data'];
}
