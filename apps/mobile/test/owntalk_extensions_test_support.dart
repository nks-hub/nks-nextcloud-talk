import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String ownTalkTestToken = 'rooma123';

/// A JPEG-looking body: the client checks the magic bytes of a download.
Uint8List ownTalkTestJpeg([int seed = 1]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, seed, 2, 3, 4, 5, 6, 7, 8]);

String ownTalkTestSha(Uint8List bytes) => sha256.convert(bytes).toString();

Map<String, Object?> ownTalkCapabilityJson({
  List<String> features = const [
    'appearance.colors',
    'appearance.bubbles',
    'appearance.presets',
    'appearance.image',
    'composer.quickEmoji',
  ],
  String acl = 'roles',
  List<String>? presets = const [
    'aurora',
    'sunset',
    'forest',
    'ocean',
    'dots',
    'grid',
  ],
  Map<String, Object?>? limits = const {
    'maxImageBytes': 10485760,
    'maxImageEdge': 2560,
  },
}) => {
  'version': '0.3.0',
  'api': 1,
  'features': features,
  'acl': acl,
  'roomTypes': ['one2one', 'group', 'public'],
  'presets': ?presets,
  'limits': ?limits,
};

http.Response ocsResponse(
  int statusCode,
  Object? data, {
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {
        'status': statusCode < 300 ? 'ok' : 'failure',
        'statuscode': statusCode,
        'message': 'x',
      },
      'data': data,
    },
  }),
  statusCode,
  headers: {'content-type': 'application/json', ...headers},
);

/// A stand-in for a Nextcloud server with (or without) OwnTalk Extensions.
///
/// Implements the documented contract: ETag/304 (the ETag includes whether the
/// caller may edit), `If-Match` merge patches with per-field conflicts, and the
/// capability document.
final class FakeOwnTalkServer {
  FakeOwnTalkServer({
    this.capability = const _DefaultCapability(),
    this.canEdit = true,
  });

  /// `null` hides the capability, otherwise the published JSON.
  Object? capability;
  bool canEdit;
  int revision = 0;
  final Map<String, String?> settings = {
    'chat.backgroundColor': null,
    'chat.accentColor': null,
    'bubble.ownColor': null,
    'bubble.ownTextColor': null,
    'bubble.otherColor': null,
    'bubble.otherTextColor': null,
    'chat.backgroundPreset': null,
    'chat.backgroundImage': null,
    'composer.quickEmoji': null,
  };
  final Map<String, int> fieldRevisions = {};

  /// Stored background photos by SHA-256.
  final Map<String, Uint8List> images = {};

  /// Answers every image upload with this status while set.
  int? failUploadWith;

  /// The `data.error` code of that answer.
  String failUploadError = 'x';

  /// Answers every image download with this status while set.
  int? failDownloadWith;

  /// Answers every settings request with this status while set.
  int? failSettingsWith;
  Object? failBody;
  Map<String, String> failHeaders = const {};

  /// Answers the capability request with this status while set.
  int? failCapabilitiesWith;

  /// Leaves the `ETag` header out of every answer.
  bool omitEtag = false;

  /// Runs once before the next PATCH is evaluated, to simulate a second
  /// writer.
  void Function()? beforePatch;

  final List<http.Request> requests = [];

  List<http.Request> get settingsRequests =>
      requests.where((r) => r.url.path.endsWith('/settings')).toList();

  List<http.Request> get uploads =>
      requests.where((r) => r.url.path.endsWith('/settings/image')).toList();

  List<http.Request> get downloads =>
      requests.where((r) => r.url.path.contains('/settings/image/')).toList();

  late final http.Client client = MockClient(handle);

  /// What the server currently sends as `ETag`.
  String get etag => '"r$revision-e${canEdit ? 1 : 0}"';

  Map<String, Object?> document() => {
    'schemaVersion': 1,
    'roomToken': ownTalkTestToken,
    'revision': revision,
    'settings': Map<String, Object?>.of(settings),
    'fieldRevisions': Map<String, Object?>.of(fieldRevisions),
    'permissions': {'canEdit': canEdit, 'aclSource': 'talk-ocs'},
    'updatedBy': revision == 0 ? null : 'alice',
    'updatedAt': revision == 0 ? null : 1794500000,
  };

  /// Applies a change as another user would.
  void setExternally(Map<String, String?> changes) {
    revision++;
    for (final entry in changes.entries) {
      settings[entry.key] = entry.value;
      fieldRevisions[entry.key] = revision;
    }
  }

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/cloud/capabilities')) {
      final capabilityFailure = failCapabilitiesWith;
      if (capabilityFailure != null) {
        return ocsResponse(capabilityFailure, {'error': 'x'});
      }
      return ocsResponse(200, {
        'version': {
          'major': 34,
          'minor': 0,
          'micro': 1,
          'string': '34.0.1',
          'edition': '',
          'extendedSupport': false,
        },
        'capabilities': {
          'spreed': {'features': <Object?>[]},
          if (capability != null)
            'owntalk_extensions': capability is _DefaultCapability
                ? ownTalkCapabilityJson()
                : capability,
        },
      });
    }
    if (path.endsWith('/room/$ownTalkTestToken/settings')) {
      final failure = failSettingsWith;
      if (failure != null) {
        return ocsResponse(
          failure,
          failBody ?? {'error': 'x'},
          headers: failHeaders,
        );
      }
      return request.method == 'PATCH' ? _patch(request) : _get(request);
    }
    if (path.endsWith('/room/$ownTalkTestToken/settings/image') &&
        request.method == 'PUT') {
      return _put(request);
    }
    if (path.contains('/room/$ownTalkTestToken/settings/image/')) {
      return _download(request);
    }
    return http.Response('', 404);
  }

  http.Response _download(http.Request request) {
    final failure = failDownloadWith;
    if (failure != null) {
      return http.Response('', failure);
    }
    final sha = request.url.pathSegments.last;
    final bytes = images[sha];
    if (bytes == null || settings['chat.backgroundImage'] != sha) {
      return ocsResponse(404, {'error': 'not_found'});
    }
    return http.Response.bytes(
      bytes,
      200,
      headers: {'content-type': 'image/jpeg', 'etag': '"$sha"'},
    );
  }

  http.Response _put(http.Request request) {
    beforePatch?.call();
    beforePatch = null;
    final failure = failUploadWith;
    if (failure != null) {
      return ocsResponse(failure, {'error': failUploadError});
    }
    if (!canEdit) {
      return ocsResponse(403, {'error': 'field_forbidden'});
    }
    final match = RegExp(
      r'^"r(\d+)"$',
    ).firstMatch(request.headers['If-Match'] ?? '');
    if (match == null) {
      return ocsResponse(428, {'error': 'precondition_required'});
    }
    if (!{
      'image/jpeg',
      'image/png',
      'image/webp',
    }.contains(request.headers['Content-Type'])) {
      return ocsResponse(415, {'error': 'unsupported_media_type'});
    }
    if ((fieldRevisions['chat.backgroundImage'] ?? 0) >
        int.parse(match.group(1)!)) {
      return ocsResponse(412, {
        'error': 'revision_conflict',
        'current': document(),
        'fields': ['chat.backgroundImage'],
      });
    }
    final sha = ownTalkTestSha(request.bodyBytes);
    images[sha] = request.bodyBytes;
    revision++;
    settings['chat.backgroundImage'] = sha;
    fieldRevisions['chat.backgroundImage'] = revision;
    return ocsResponse(
      200,
      document(),
      headers: omitEtag ? const {} : {'etag': etag},
    );
  }

  http.Response _get(http.Request request) {
    final headers = omitEtag ? <String, String>{} : {'etag': etag};
    if (request.headers['If-None-Match'] == etag) {
      return http.Response('', 304, headers: headers);
    }
    return ocsResponse(200, document(), headers: headers);
  }

  http.Response _patch(http.Request request) {
    beforePatch?.call();
    beforePatch = null;
    if (!canEdit) {
      return ocsResponse(403, {'error': 'field_forbidden'});
    }
    final match = RegExp(
      r'^"r(\d+)"$',
    ).firstMatch(request.headers['If-Match'] ?? '');
    if (match == null) {
      return ocsResponse(428, {'error': 'precondition_required'});
    }
    final base = int.parse(match.group(1)!);
    final patch =
        (jsonDecode(request.body) as Map<String, Object?>)['settings']!
            as Map<String, Object?>;
    final conflicts = [
      for (final field in patch.keys)
        if ((fieldRevisions[field] ?? 0) > base) field,
    ];
    if (conflicts.isNotEmpty) {
      return ocsResponse(412, {
        'error': 'revision_conflict',
        'current': document(),
        'fields': conflicts,
      });
    }
    revision++;
    for (final entry in patch.entries) {
      settings[entry.key] = entry.value as String?;
      fieldRevisions[entry.key] = revision;
    }
    return ocsResponse(
      200,
      document(),
      headers: omitEtag ? const {} : {'etag': etag},
    );
  }
}

final class _DefaultCapability {
  const _DefaultCapability();
}
