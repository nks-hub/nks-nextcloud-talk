import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String ownTalkTestToken = 'rooma123';

Map<String, Object?> ownTalkCapabilityJson({
  List<String> features = const [
    'appearance.colors',
    'appearance.bubbles',
    'composer.quickEmoji',
  ],
  String acl = 'roles',
}) => {
  'version': '0.1.0',
  'api': 1,
  'features': features,
  'acl': acl,
  'roomTypes': ['one2one', 'group', 'public'],
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
/// Implements the documented contract: ETag/304, `If-Match` merge patches with
/// per-field conflicts, and the capability document.
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
    'composer.quickEmoji': null,
  };
  final Map<String, int> fieldRevisions = {};

  /// Answers every settings request with this status while set.
  int? failSettingsWith;
  Object? failBody;

  /// Runs once before the next PATCH is evaluated, to simulate a second
  /// writer.
  void Function()? beforePatch;

  final List<http.Request> requests = [];

  List<http.Request> get settingsRequests =>
      requests.where((r) => r.url.path.endsWith('/settings')).toList();

  late final http.Client client = MockClient(handle);

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
        return ocsResponse(failure, failBody ?? {'error': 'x'});
      }
      return request.method == 'PATCH' ? _patch(request) : _get(request);
    }
    return http.Response('', 404);
  }

  http.Response _get(http.Request request) {
    final etag = '"r$revision"';
    if (request.headers['If-None-Match'] == etag) {
      return http.Response('', 304, headers: {'etag': etag});
    }
    return ocsResponse(200, document(), headers: {'etag': etag});
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
    return ocsResponse(200, document(), headers: {'etag': '"r$revision"'});
  }
}

final class _DefaultCapability {
  const _DefaultCapability();
}
