import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const String remoteFilesContractUserAgent =
    'com.nkshub.nextcloudtalk remote-files-contract/0.1';

/// Talk's share type for "into this conversation".
///
/// Chosen over a public link on purpose: the server posts the file into the
/// room for its participants and no address exists that works without being
/// one of them.
const int remoteFilesRoomShareType = 10;

const int remoteFilesMaximumPathCharacters = 1024;
const int remoteFilesMaximumPathDepth = 32;

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidRemoteFilesRequest;

/// Lists one directory of the account's own Files storage.
///
/// `PROPFIND /remote.php/dav/files/{loginName}/{path}` with `Depth: 1`, which
/// is the directory plus its immediate children and nothing below them. Depth
/// is fixed rather than a parameter: an infinite listing is what makes a large
/// account unusable, and the picker walks one level at a time anyway.
final class RemoteDirectoryRequest {
  RemoteDirectoryRequest({
    required this.accountId,
    required this.server,
    required this.loginName,
    String path = '',
    this.userAgent = remoteFilesContractUserAgent,
  }) : path = validateRemoteFilePath(path, allowRoot: true) {
    if (loginName.isEmpty || loginName.length > 256) {
      protocolFailure(_requestCode, r'$.loginName');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final String loginName;
  final String path;
  final String userAgent;

  String get httpMethod => 'PROPFIND';

  Uri get uri {
    final segments = <String>[
      ...server.uri.pathSegments.where((segment) => segment.isNotEmpty),
      'remote.php',
      'dav',
      'files',
      loginName,
      if (path.isNotEmpty) ...path.split('/'),
    ];
    return server.uri.replace(pathSegments: segments, query: null);
  }

  Map<String, String> get headers => UnmodifiableMapView({
    'Depth': '1',
    'User-Agent': userAgent,
    'Content-Type': 'application/xml; charset=utf-8',
  });

  /// Asks for exactly the properties a row shows. A shorter list means less
  /// of the user's file metadata travels than a default PROPFIND would send.
  Uint8List get bodyBytes => Uint8List.fromList(
    utf8.encode(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">'
      '<d:prop>'
      '<d:resourcetype/>'
      '<d:getcontentlength/>'
      '<d:getcontenttype/>'
      '<d:getlastmodified/>'
      '<nc:has-preview/>'
      '</d:prop>'
      '</d:propfind>',
    ),
  );

  @override
  String toString() => 'RemoteDirectoryRequest(path: <redacted>)';
}

/// Shares one existing server-side file into a conversation.
///
/// `POST /ocs/v2.php/apps/files_sharing/api/v1/shares`. Nothing is uploaded:
/// the file stays where it is and the server posts it into the room.
final class RemoteFileShareRequest {
  RemoteFileShareRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required String path,
    this.userAgent = remoteFilesContractUserAgent,
  }) : path = validateRemoteFilePath(path, allowRoot: false) {
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String path;
  final String userAgent;

  String get httpMethod => 'POST';

  Uri get uri => server.uri.replace(
    path: '${server.basePath}/ocs/v2.php/apps/files_sharing/api/v1/shares',
    queryParameters: const {'format': 'json'},
  );

  Map<String, String> get headers => UnmodifiableMapView({
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
  });

  Map<String, String> get formFields => UnmodifiableMapView({
    'shareType': '$remoteFilesRoomShareType',
    'shareWith': roomToken.value,
    'path': '/$path',
  });

  Uint8List get bodyBytes => Uint8List.fromList(
    utf8.encode(
      formFields.entries
          .map(
            (entry) =>
                '${Uri.encodeQueryComponent(entry.key)}='
                '${Uri.encodeQueryComponent(entry.value)}',
          )
          .join('&'),
    ),
  );

  @override
  String toString() => 'RemoteFileShareRequest(path: <redacted>)';
}

/// Normalises a path inside the account's own files root and refuses anything
/// that could leave it.
///
/// Returned without a leading or trailing slash, so a path is always relative
/// to that root and never absolute on the server.
String validateRemoteFilePath(String raw, {required bool allowRoot}) {
  final trimmed = raw.trim();
  if (trimmed.length > remoteFilesMaximumPathCharacters) {
    protocolFailure(_requestCode, r'$.path');
  }
  final segments = trimmed
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) {
    if (!allowRoot) {
      protocolFailure(_requestCode, r'$.path');
    }
    return '';
  }
  if (segments.length > remoteFilesMaximumPathDepth) {
    protocolFailure(_requestCode, r'$.path');
  }
  for (final segment in segments) {
    // `..` is the whole reason this function exists: without it a picked path
    // could address the server outside the account's own storage.
    if (segment == '.' ||
        segment == '..' ||
        segment != segment.trim() ||
        segment.contains(r'\') ||
        segment.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
      protocolFailure(_requestCode, r'$.path');
    }
  }
  return segments.join('/');
}

void _validateUserAgent(String value) {
  if (value.isEmpty ||
      value.length > 256 ||
      value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, r'$.headers.userAgent');
  }
}
