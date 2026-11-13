import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../bootstrap/capabilities.dart';
import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'models.dart';

const String ownTalkExtensionsContractUserAgent =
    'com.nkshub.nextcloudtalk owntalk-extensions-contract/0.1';

const String ownTalkExtensionsApiPath =
    '/ocs/v2.php/apps/owntalk_extensions/api/v1';

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidOwnTalkExtensionsRequest;

/// `If-Match` value for a document revision. `If-None-Match` takes the opaque
/// `ETag` the server sent instead, because that one also depends on the
/// caller's permissions.
String ownTalkRevisionEtag(int revision) => '"r$revision"';

/// Image types the upload endpoint accepts.
const Set<String> ownTalkImageContentTypes = {
  'image/jpeg',
  'image/png',
  'image/webp',
};

final RegExp _entityTagPattern = RegExp(r'^(?:W/)?"[!#-~]*"$');

/// Whether [value] is an entity tag that is safe to echo into a header.
bool isOwnTalkEntityTag(String value) =>
    value.length <= 128 && _entityTagPattern.hasMatch(value);

OwnTalkExtensionsCapability _requireCapability(
  CapabilitySnapshot capabilities,
) {
  final capability = capabilities.ownTalkExtensions;
  if (capabilities.context != CapabilityContext.authenticated ||
      capability == null) {
    protocolFailure(_requestCode, r'$.capabilities.owntalk_extensions');
  }
  return capability;
}

void _validateUserAgent(String userAgent) {
  if (userAgent.isEmpty ||
      userAgent.length > 256 ||
      userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, r'$.headers.userAgent');
  }
}

Uri _settingsUri(ServerBase server, ConversationToken roomToken) {
  return server.uri.replace(
    path:
        '${server.basePath}$ownTalkExtensionsApiPath/room/${roomToken.value}/settings',
    queryParameters: const {'format': 'json'},
  );
}

Uri _imageUri(ServerBase server, ConversationToken roomToken, String suffix) {
  return server.uri.replace(
    path:
        '${server.basePath}$ownTalkExtensionsApiPath/room/${roomToken.value}/settings/image$suffix',
  );
}

/// Reads the shared settings document. With [knownEtag], the `ETag` of the
/// copy the caller holds, the server answers `304` when nothing changed.
final class FetchOwnTalkRoomSettingsRequest {
  FetchOwnTalkRoomSettingsRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required CapabilitySnapshot capabilities,
    this.knownEtag,
    this.userAgent = ownTalkExtensionsContractUserAgent,
  }) {
    _requireCapability(capabilities);
    if (knownEtag != null && !isOwnTalkEntityTag(knownEtag!)) {
      protocolFailure(_requestCode, r'$.headers.ifNoneMatch');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String? knownEtag;
  final String userAgent;

  String get httpMethod => 'GET';

  Uri get uri => _settingsUri(server, roomToken);

  Map<String, String> get headers => UnmodifiableMapView({
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'If-None-Match': ?knownEtag,
  });

  @override
  String toString() => 'FetchOwnTalkRoomSettingsRequest()';
}

/// Merge-patches the shared settings. A `null` value clears a field.
final class UpdateOwnTalkRoomSettingsRequest {
  UpdateOwnTalkRoomSettingsRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required CapabilitySnapshot capabilities,
    required Map<OwnTalkSettingField, String?> changes,
    required this.baseRevision,
    this.userAgent = ownTalkExtensionsContractUserAgent,
  }) : changes = UnmodifiableMapView(_validatedChanges(capabilities, changes)) {
    if (baseRevision < 0) {
      protocolFailure(_requestCode, r'$.headers.ifMatch');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;

  /// Normalized values keyed by field; `null` clears the field.
  final Map<OwnTalkSettingField, String?> changes;
  final int baseRevision;
  final String userAgent;

  String get httpMethod => 'PATCH';

  Uri get uri => _settingsUri(server, roomToken);

  Map<String, String> get headers => UnmodifiableMapView({
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'Content-Type': 'application/json',
    'If-Match': ownTalkRevisionEtag(baseRevision),
  });

  Uint8List get bodyBytes => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'settings': {
          for (final entry in changes.entries) entry.key.wireKey: entry.value,
        },
      }),
    ),
  );

  @override
  String toString() =>
      'UpdateOwnTalkRoomSettingsRequest(fields: ${changes.length})';
}

/// Uploads a background image. The server re-encodes it and answers with the
/// document whose `chat.backgroundImage` names the stored file.
final class UploadOwnTalkRoomImageRequest {
  UploadOwnTalkRoomImageRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required CapabilitySnapshot capabilities,
    required Uint8List bytes,
    required this.contentType,
    required this.baseRevision,
    this.userAgent = ownTalkExtensionsContractUserAgent,
  }) : bodyBytes = Uint8List.fromList(bytes) {
    final capability = _requireCapability(capabilities);
    if (!capability.supportsField(OwnTalkSettingField.chatBackgroundImage)) {
      protocolFailure(_requestCode, r'$.body.settings.chat.backgroundImage');
    }
    if (!ownTalkImageContentTypes.contains(contentType)) {
      protocolFailure(_requestCode, r'$.headers.contentType');
    }
    if (bodyBytes.isEmpty || bodyBytes.length > capability.maxImageBytes) {
      protocolFailure(_requestCode, r'$.body');
    }
    if (baseRevision < 0) {
      protocolFailure(_requestCode, r'$.headers.ifMatch');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final Uint8List bodyBytes;
  final String contentType;
  final int baseRevision;
  final String userAgent;

  String get httpMethod => 'PUT';

  Uri get uri => _imageUri(
    server,
    roomToken,
    '',
  ).replace(queryParameters: const {'format': 'json'});

  Map<String, String> get headers => UnmodifiableMapView({
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'Content-Type': contentType,
    'If-Match': ownTalkRevisionEtag(baseRevision),
  });

  @override
  String toString() =>
      'UploadOwnTalkRoomImageRequest(bytes: ${bodyBytes.length})';
}

/// Downloads the current background image, named by its SHA-256.
final class FetchOwnTalkRoomImageRequest {
  FetchOwnTalkRoomImageRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required CapabilitySnapshot capabilities,
    required this.sha256,
    this.userAgent = ownTalkExtensionsContractUserAgent,
  }) {
    final capability = _requireCapability(capabilities);
    if (!capability.supportsField(OwnTalkSettingField.chatBackgroundImage)) {
      protocolFailure(_requestCode, r'$.path.sha256');
    }
    if (!isOwnTalkImageHash(sha256)) {
      protocolFailure(_requestCode, r'$.path.sha256');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String sha256;
  final String userAgent;

  String get httpMethod => 'GET';

  Uri get uri => _imageUri(server, roomToken, '/$sha256');

  Map<String, String> get headers => UnmodifiableMapView({
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'Accept': 'image/jpeg',
  });

  @override
  String toString() => 'FetchOwnTalkRoomImageRequest()';
}

Map<OwnTalkSettingField, String?> _validatedChanges(
  CapabilitySnapshot capabilities,
  Map<OwnTalkSettingField, String?> changes,
) {
  final capability = _requireCapability(capabilities);
  if (changes.isEmpty) {
    protocolFailure(_requestCode, r'$.body.settings');
  }
  final result = <OwnTalkSettingField, String?>{};
  for (final entry in changes.entries) {
    final field = entry.key;
    final path = '\$.body.settings.${field.wireKey}';
    if (!capability.supportsField(field)) {
      protocolFailure(_requestCode, path);
    }
    final value = entry.value;
    if (value == null) {
      result[field] = null;
      continue;
    }
    // A merge patch can only clear an image; it is set by the upload.
    if (field == OwnTalkSettingField.chatBackgroundImage) {
      protocolFailure(_requestCode, path);
    }
    final normalized =
        normalizeOwnTalkSettingValue(field, value) ??
        protocolFailure(_requestCode, path);
    if (field == OwnTalkSettingField.chatBackgroundPreset &&
        !capability.presets.contains(normalized)) {
      protocolFailure(_requestCode, path);
    }
    result[field] = normalized;
  }
  return result;
}
