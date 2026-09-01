import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidRemoteFilesResponse;

/// Hard cap on the entries one directory contributes.
///
/// A directory with more children than this is listed truncated rather than
/// held in memory in full: the picker exists to find one file, not to mirror
/// an account.
const int remoteFilesMaximumEntries = 500;

const int remoteFilesMaximumListingBytes = 4 * 1024 * 1024;
const int remoteFilesMaximumShareBytes = 256 * 1024;
const int remoteFilesMaximumNameCharacters = 255;

const String _davNamespace = 'DAV:';
const String _nextcloudNamespace = 'http://nextcloud.org/ns';

enum RemoteDirectoryOutcome {
  listed,

  /// HTTP 401: the account has to sign in again before browsing.
  reauthenticationRequired,

  /// HTTP 403 or 404: the directory is gone or not readable by this account.
  unavailable,

  /// HTTP 429 or 503: retry later.
  transientError,
}

final class RemoteDirectoryResponse {
  const RemoteDirectoryResponse._({
    required this.request,
    required this.outcome,
    required this.listing,
    required this.truncated,
  });

  final RemoteDirectoryRequest request;
  final RemoteDirectoryOutcome outcome;
  final RemoteDirectoryListing? listing;

  /// True when the server returned more children than
  /// [remoteFilesMaximumEntries] and the rest was dropped.
  final bool truncated;

  @override
  String toString() =>
      'RemoteDirectoryResponse(outcome: ${outcome.name}, '
      'entries: ${listing?.entries.length ?? 0}, truncated: $truncated)';
}

RemoteDirectoryResponse decodeRemoteDirectoryResponse({
  required RemoteDirectoryRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  RemoteDirectoryResponse plain(RemoteDirectoryOutcome outcome) =>
      RemoteDirectoryResponse._(
        request: request,
        outcome: outcome,
        listing: null,
        truncated: false,
      );

  switch (statusCode) {
    case 207:
      break;
    case 401:
      return plain(RemoteDirectoryOutcome.reauthenticationRequired);
    case 403:
    case 404:
      return plain(RemoteDirectoryOutcome.unavailable);
    case 429:
    case 503:
      return plain(RemoteDirectoryOutcome.transientError);
    default:
      protocolFailure(_responseCode, r'$.statusCode');
  }
  if (body.length > remoteFilesMaximumListingBytes) {
    protocolFailure(_responseCode, r'$.body.length');
  }

  final XmlDocument document;
  try {
    document = XmlDocument.parse(utf8.decode(body));
  } on Object {
    protocolFailure(_responseCode, r'$.body');
  }

  final prefix = _listingPathPrefix(request);
  final entries = <RemoteFileEntry>[];
  var truncated = false;
  for (final response in document.findAllElements(
    'response',
    namespaceUri: _davNamespace,
  )) {
    if (entries.length >= remoteFilesMaximumEntries) {
      truncated = true;
      break;
    }
    final entry = _decodeEntry(response, prefix: prefix);
    // The directory itself is the first entry of a Depth 1 listing; only its
    // children belong in the list.
    if (entry != null && entry.path != request.path) {
      entries.add(entry);
    }
  }
  entries.sort((first, second) {
    if (first.isDirectory != second.isDirectory) {
      return first.isDirectory ? -1 : 1;
    }
    return first.name.toLowerCase().compareTo(second.name.toLowerCase());
  });

  return RemoteDirectoryResponse._(
    request: request,
    outcome: RemoteDirectoryOutcome.listed,
    listing: RemoteDirectoryListing(path: request.path, entries: entries),
    truncated: truncated,
  );
}

String _listingPathPrefix(RemoteDirectoryRequest request) {
  final base = request.server.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .join('/');
  final root = <String>[
    if (base.isNotEmpty) base,
    'remote.php',
    'dav',
    'files',
    request.loginName,
  ].join('/');
  return '/$root/';
}

RemoteFileEntry? _decodeEntry(XmlElement response, {required String prefix}) {
  final href = response
      .getElement('href', namespaceUri: _davNamespace)
      ?.innerText;
  if (href == null || href.isEmpty) {
    return null;
  }
  final String decoded;
  try {
    decoded = Uri.decodeFull(href.split('?').first);
  } on Object {
    protocolFailure(_responseCode, r'$.href');
  }
  // A href outside the account's own files root cannot be addressed by this
  // listing, so it is dropped rather than guessed at.
  if (!decoded.startsWith(prefix)) {
    return null;
  }
  final relative = decoded
      .substring(prefix.length)
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .join('/');
  // An empty relative path is the storage root, which is never a child of the
  // directory being listed.
  if (relative.isEmpty) {
    return null;
  }
  final name = relative.split('/').last;
  if (name.length > remoteFilesMaximumNameCharacters) {
    protocolFailure(_responseCode, r'$.href.name');
  }

  final properties = <XmlElement>[
    for (final propstat in response.findElements(
      'propstat',
      namespaceUri: _davNamespace,
    ))
      if (_propstatSucceeded(propstat))
        ...?propstat
            .getElement('prop', namespaceUri: _davNamespace)
            ?.childElements,
  ];
  XmlElement? property(String local, String uri) {
    for (final element in properties) {
      if (element.name.local == local && element.name.namespaceUri == uri) {
        return element;
      }
    }
    return null;
  }

  final isDirectory =
      property(
        'resourcetype',
        _davNamespace,
      )?.getElement('collection', namespaceUri: _davNamespace) !=
      null;
  final rawLength = property('getcontentlength', _davNamespace)?.innerText;
  final size = rawLength == null ? null : int.tryParse(rawLength.trim());
  if (size != null && size < 0) {
    protocolFailure(_responseCode, r'$.prop.getcontentlength');
  }
  final rawType = property('getcontenttype', _davNamespace)?.innerText.trim();
  final rawPreview = property(
    'has-preview',
    _nextcloudNamespace,
  )?.innerText.trim().toLowerCase();

  return RemoteFileEntry(
    path: relative,
    name: name,
    isDirectory: isDirectory,
    sizeBytes: isDirectory ? null : size,
    mimeType: rawType == null || rawType.isEmpty ? null : rawType,
    hasPreview: rawPreview == 'true',
    lastModified: _parseHttpDate(
      property('getlastmodified', _davNamespace)?.innerText,
    ),
  );
}

bool _propstatSucceeded(XmlElement propstat) {
  final status = propstat.getElement('status', namespaceUri: _davNamespace);
  return status == null || status.innerText.contains(' 200 ');
}

enum RemoteFileShareOutcome {
  shared,

  /// HTTP 401: the account has to sign in again.
  reauthenticationRequired,

  /// The account may not share this file, or not into this conversation.
  forbidden,

  /// The file is gone.
  notFound,

  /// HTTP 429 or 503: retry later.
  transientError,
}

final class RemoteFileShareResponse {
  const RemoteFileShareResponse._({
    required this.request,
    required this.outcome,
  });

  final RemoteFileShareRequest request;
  final RemoteFileShareOutcome outcome;

  @override
  String toString() => 'RemoteFileShareResponse(outcome: ${outcome.name})';
}

RemoteFileShareResponse decodeRemoteFileShareResponse({
  required RemoteFileShareRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  if (body.length > remoteFilesMaximumShareBytes) {
    protocolFailure(_responseCode, r'$.body.length');
  }
  RemoteFileShareResponse plain(RemoteFileShareOutcome outcome) =>
      RemoteFileShareResponse._(request: request, outcome: outcome);

  switch (statusCode) {
    case 200:
    case 201:
      // The share only counts once OCS itself says so; an HTTP 200 carrying an
      // OCS failure would otherwise be reported to the user as a sent file.
      final ocsStatus = _ocsStatusCode(body);
      return plain(
        ocsStatus == 100 || ocsStatus == 200
            ? RemoteFileShareOutcome.shared
            : RemoteFileShareOutcome.forbidden,
      );
    case 400:
    case 403:
      return plain(RemoteFileShareOutcome.forbidden);
    case 401:
      return plain(RemoteFileShareOutcome.reauthenticationRequired);
    case 404:
      return plain(RemoteFileShareOutcome.notFound);
    case 429:
    case 503:
      return plain(RemoteFileShareOutcome.transientError);
    default:
      protocolFailure(_responseCode, r'$.statusCode');
  }
}

int? _ocsStatusCode(Uint8List body) {
  final String source;
  try {
    source = utf8.decode(body);
  } on FormatException {
    protocolFailure(_responseCode, r'$.body');
  }
  final decoded = decodeJsonRejectingDuplicateMembers(
    source,
    code: _responseCode,
    path: r'$.body',
  );
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: _responseCode,
  );
  final status = meta['statuscode'];
  return status is int ? status : null;
}

/// Parses the RFC 1123 date WebDAV sends, without guessing: anything else
/// becomes `null` rather than a wrong timestamp.
DateTime? _parseHttpDate(String? raw) {
  if (raw == null) {
    return null;
  }
  final match = _httpDate.firstMatch(raw.trim());
  if (match == null) {
    return null;
  }
  final month = _months.indexOf(match.group(2)!) + 1;
  if (month == 0) {
    return null;
  }
  return DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

final RegExp _httpDate = RegExp(
  r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) '
  r'(\d{2}):(\d{2}):(\d{2}) GMT$',
);

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
