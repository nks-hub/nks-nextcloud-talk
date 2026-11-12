import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

const _server = 'https://cloud.example.invalid';

void main() {
  group('capability', () {
    test('is parsed from the documented shape', () {
      final capability = _snapshot().ownTalkExtensions!;
      expect(capability.version, '0.1.0');
      expect(capability.acl, OwnTalkAclMode.roles);
      expect(capability.features, {
        'appearance.colors',
        'appearance.bubbles',
        'composer.quickEmoji',
      });
      expect(capability.supportsRoomType(1), isTrue);
      expect(capability.supportsRoomType(2), isTrue);
      expect(capability.supportsRoomType(3), isTrue);
      expect(capability.supportsRoomType(4), isFalse);
      expect(capability.supportsRoomType(6), isFalse);
    });

    test('is off, never an error, when missing or unusable', () {
      expect(_snapshot(capability: null).ownTalkExtensions, isNull);
      for (final broken in <Object?>[
        {..._capabilityJson(), 'api': 2},
        {..._capabilityJson(), 'api': '1'},
        {..._capabilityJson(), 'acl': 'everyone'},
        {..._capabilityJson(), 'features': 'appearance.colors'},
        {..._capabilityJson(), 'roomTypes': null},
        {..._capabilityJson(), 'version': ''},
        'owntalk',
        <Object?>[],
      ]) {
        expect(
          _snapshot(capability: broken).ownTalkExtensions,
          isNull,
          reason: '$broken',
        );
      }
    });

    test('keeps feature gaps, such as a server without emoji support', () {
      final capability = _snapshot(
        capability: {
          ..._capabilityJson(),
          'features': ['appearance.colors'],
          'acl': 'membership',
        },
      ).ownTalkExtensions!;
      expect(capability.acl, OwnTalkAclMode.membership);
      expect(
        capability.supportsField(OwnTalkSettingField.composerQuickEmoji),
        isFalse,
      );
      expect(
        capability.supportsField(OwnTalkSettingField.chatBackgroundColor),
        isTrue,
      );
    });
  });

  group('settings document', () {
    test('parses the documented example', () {
      final document = OwnTalkRoomSettings.fromJson(_documentJson());
      expect(document.roomToken, 'abc123xy');
      expect(document.revision, 3);
      expect(document.canEdit, isTrue);
      expect(document.aclSource, 'talk-ocs');
      expect(document.updatedBy, 'alice');
      expect(document.updatedAt, 1794500000);
      expect(document[OwnTalkSettingField.chatBackgroundColor], '#1E3A5F');
      expect(document[OwnTalkSettingField.chatAccentColor], isNull);
      expect(document[OwnTalkSettingField.composerQuickEmoji], '\u{1F44D}');
      expect(document.fieldRevisions, {
        OwnTalkSettingField.chatBackgroundColor: 3,
        OwnTalkSettingField.bubbleOwnColor: 2,
      });
    });

    test('accepts the empty document of an unconfigured conversation', () {
      final document = OwnTalkRoomSettings.fromJson(
        _documentJson(
          revision: 0,
          settings: {
            for (final field in OwnTalkSettingField.values) field.wireKey: null,
          },
          fieldRevisions: <String, Object?>{},
          updatedBy: null,
          updatedAt: null,
        ),
      );
      expect(document.revision, 0);
      expect(document.isEmpty, isTrue);
      expect(document.updatedBy, isNull);
    });

    test('ignores unknown settings and members, normalizes colours', () {
      final json = _documentJson(
        settings: {
          'chat.backgroundColor': '#1e3a5f',
          'future.thing': 'x',
          'composer.quickEmoji': null,
        },
      )..['extra'] = 1;
      final document = OwnTalkRoomSettings.fromJson(json);
      expect(document[OwnTalkSettingField.chatBackgroundColor], '#1E3A5F');
      expect(document[OwnTalkSettingField.bubbleOwnColor], isNull);
    });

    test('round-trips through toJson', () {
      final document = OwnTalkRoomSettings.fromJson(_documentJson());
      final copy = OwnTalkRoomSettings.fromJson(
        jsonDecode(jsonEncode(document.toJson())),
      );
      expect(copy.toJson(), document.toJson());
    });

    test('rejects malformed documents', () {
      final cases = <String, Map<String, Object?>>{
        'schema': _documentJson()..['schemaVersion'] = 2,
        'revision': _documentJson()..['revision'] = -1,
        'colour': _documentJson(settings: {'chat.backgroundColor': 'red'}),
        'colour type': _documentJson(settings: {'bubble.ownColor': 7}),
        'emoji': _documentJson(settings: {'composer.quickEmoji': 'ab'}),
        'canEdit': _documentJson()..['permissions'] = {'canEdit': 'yes'},
        'settings': _documentJson()..['settings'] = <Object?>[],
        'token': _documentJson()..['roomToken'] = 3,
      };
      for (final entry in cases.entries) {
        expect(
          () => OwnTalkRoomSettings.fromJson(entry.value),
          throwsA(isA<TalkProtocolException>()),
          reason: entry.key,
        );
      }
    });
  });

  group('requests', () {
    test('GET carries If-None-Match only with a known ETag', () {
      final first = _fetch();
      expect(first.httpMethod, 'GET');
      expect(
        first.uri.toString(),
        '$_server/ocs/v2.php/apps/owntalk_extensions/api/v1/room/abc123xy/'
        'settings?format=json',
      );
      expect(first.headers['OCS-APIRequest'], 'true');
      expect(first.headers.containsKey('If-None-Match'), isFalse);
      expect(
        _fetch(knownEtag: '"r3-e1"').headers['If-None-Match'],
        '"r3-e1"',
        reason: 'the opaque value is sent exactly as received',
      );
      expect(
        _fetch(knownEtag: 'W/"r3-e0"').headers['If-None-Match'],
        'W/"r3-e0"',
      );
    });

    test('GET refuses a known ETag that is not a header-safe entity tag', () {
      for (final bad in ['', 'r3', '"r3\r\nX: y"', '"${'a' * 200}"', '"r3']) {
        expect(
          () => _fetch(knownEtag: bad),
          throwsA(isA<TalkProtocolException>()),
          reason: bad,
        );
      }
    });

    test('PATCH sends a merge patch with a required If-Match', () {
      final request = _update({
        OwnTalkSettingField.bubbleOwnColor: '#2f6feb',
        OwnTalkSettingField.composerQuickEmoji: null,
      }, base: 0);
      expect(request.httpMethod, 'PATCH');
      expect(request.headers['If-Match'], '"r0"');
      expect(request.headers['Content-Type'], 'application/json');
      expect(jsonDecode(utf8.decode(request.bodyBytes)), {
        'settings': {'bubble.ownColor': '#2F6FEB', 'composer.quickEmoji': null},
      });
    });

    test('are refused without the capability, an unsupported feature or a '
        'valid value', () {
      expect(
        () => FetchOwnTalkRoomSettingsRequest(
          accountId: AccountId.parse('account-a'),
          server: ServerBase.parse(_server),
          roomToken: ConversationToken.parse('abc123xy', path: r'$.t'),
          capabilities: _snapshot(capability: null),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => FetchOwnTalkRoomSettingsRequest(
          accountId: AccountId.parse('account-a'),
          server: ServerBase.parse(_server),
          roomToken: ConversationToken.parse('abc123xy', path: r'$.t'),
          capabilities: _snapshot(context: CapabilityContext.anonymous),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => _update(
          {OwnTalkSettingField.composerQuickEmoji: '\u{1F44D}'},
          capability: {
            ..._capabilityJson(),
            'features': ['appearance.colors'],
          },
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => _update({OwnTalkSettingField.chatAccentColor: 'blue'}),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(() => _update(const {}), throwsA(isA<TalkProtocolException>()));
      expect(
        () =>
            _update({OwnTalkSettingField.chatAccentColor: '#FFFFFF'}, base: -1),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('GET responses', () {
    test('200 yields the document', () {
      final result = decodeFetchOwnTalkRoomSettingsResponse(
        request: _fetch(),
        statusCode: 200,
        body: _ocs(200, _documentJson()),
      );
      expect((result as OwnTalkSettingsLoaded).document.revision, 3);
    });

    test('200 keeps the ETag header verbatim, any header case', () {
      for (final name in ['etag', 'ETag']) {
        final result = decodeFetchOwnTalkRoomSettingsResponse(
          request: _fetch(),
          statusCode: 200,
          body: _ocs(200, _documentJson()),
          headers: {name: '"r3-e1"'},
        );
        expect((result as OwnTalkSettingsLoaded).etag, '"r3-e1"');
      }
    });

    test('200 with a missing or garbled ETag header has no ETag', () {
      for (final headers in <Map<String, String>>[
        const {},
        {'etag': 'r3'},
        {'etag': '"r3\u0000"'},
        {'etag': '"${'a' * 200}"'},
      ]) {
        final result = decodeFetchOwnTalkRoomSettingsResponse(
          request: _fetch(),
          statusCode: 200,
          body: _ocs(200, _documentJson()),
          headers: headers,
        );
        expect((result as OwnTalkSettingsLoaded).etag, isNull, reason: '$headers');
      }
    });

    test('429 reads Retry-After in seconds, ignores anything else', () {
      Duration? retryAfter(Map<String, String> headers) =>
          (decodeFetchOwnTalkRoomSettingsResponse(
                    request: _fetch(),
                    statusCode: 429,
                    body: _ocs(429, {'error': 'x'}, status: 'failure'),
                    headers: headers,
                  )
                  as OwnTalkSettingsFetchFailure)
              .retryAfter;
      expect(retryAfter({'retry-after': '30'}), const Duration(seconds: 30));
      expect(retryAfter({'retry-after': '99999'}), const Duration(minutes: 10));
      expect(retryAfter({'retry-after': 'soon'}), isNull);
      expect(retryAfter(const {}), isNull);
    });

    test('200 for another conversation is a protocol failure', () {
      expect(
        () => decodeFetchOwnTalkRoomSettingsResponse(
          request: _fetch(),
          statusCode: 200,
          body: _ocs(200, _documentJson()..['roomToken'] = 'other999'),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('304 needs a known ETag, 404 is "no settings"', () {
      expect(
        decodeFetchOwnTalkRoomSettingsResponse(
          request: _fetch(knownEtag: '"r3-e1"'),
          statusCode: 304,
          body: Uint8List(0),
        ),
        isA<OwnTalkSettingsNotModified>(),
      );
      expect(
        () => decodeFetchOwnTalkRoomSettingsResponse(
          request: _fetch(),
          statusCode: 304,
          body: Uint8List(0),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        decodeFetchOwnTalkRoomSettingsResponse(
          request: _fetch(),
          statusCode: 404,
          body: _ocs(404, {'error': 'not_found'}, status: 'failure'),
        ),
        isA<OwnTalkSettingsMissing>(),
      );
    });

    test('maps the remaining statuses', () {
      const expected = {
        400: OwnTalkExtensionsFailureKind.rejected,
        401: OwnTalkExtensionsFailureKind.reauthenticationRequired,
        403: OwnTalkExtensionsFailureKind.forbidden,
        429: OwnTalkExtensionsFailureKind.rateLimited,
        503: OwnTalkExtensionsFailureKind.unavailable,
      };
      for (final entry in expected.entries) {
        final result = decodeFetchOwnTalkRoomSettingsResponse(
          request: _fetch(),
          statusCode: entry.key,
          body: _ocs(entry.key, {'error': 'x'}, status: 'failure'),
        );
        expect((result as OwnTalkSettingsFetchFailure).kind, entry.value);
      }
      expect(
        () => decodeFetchOwnTalkRoomSettingsResponse(
          request: _fetch(),
          statusCode: 418,
          body: Uint8List(0),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('PATCH responses', () {
    final request = _update({OwnTalkSettingField.bubbleOwnColor: '#2F6FEB'});

    test('200 yields the saved document', () {
      final result = decodeUpdateOwnTalkRoomSettingsResponse(
        request: request,
        statusCode: 200,
        body: _ocs(200, _documentJson(revision: 4)),
      );
      expect((result as OwnTalkSettingsSaved).document.revision, 4);
      expect(result.etag, isNull);
    });

    test('200 keeps the ETag header of the saved document', () {
      final result = decodeUpdateOwnTalkRoomSettingsResponse(
        request: request,
        statusCode: 200,
        body: _ocs(200, _documentJson(revision: 4)),
        headers: {'etag': '"r4-e1"'},
      );
      expect((result as OwnTalkSettingsSaved).etag, '"r4-e1"');
    });

    test('412 carries the current document and the conflicting fields', () {
      final result = decodeUpdateOwnTalkRoomSettingsResponse(
        request: request,
        statusCode: 412,
        body: _ocs(412, {
          'error': 'revision_conflict',
          'current': _documentJson(revision: 5),
          'fields': ['bubble.ownColor', 'future.field'],
        }, status: 'failure'),
      );
      final conflict = result as OwnTalkSettingsConflict;
      expect(conflict.current.revision, 5);
      expect(conflict.conflictingFields, [OwnTalkSettingField.bubbleOwnColor]);
    });

    test('412 without the conflict shape is a protocol failure', () {
      expect(
        () => decodeUpdateOwnTalkRoomSettingsResponse(
          request: request,
          statusCode: 412,
          body: _ocs(412, {'error': 'other'}, status: 'failure'),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('maps 400, 403, 404, 428 and 503 with the error code', () {
      const expected = {
        400: (OwnTalkExtensionsFailureKind.rejected, 'invalid_value'),
        403: (OwnTalkExtensionsFailureKind.forbidden, 'field_forbidden'),
        404: (OwnTalkExtensionsFailureKind.notFound, 'not_found'),
        428: (
          OwnTalkExtensionsFailureKind.preconditionRequired,
          'precondition_required',
        ),
        503: (OwnTalkExtensionsFailureKind.unavailable, 'talk_unavailable'),
      };
      for (final entry in expected.entries) {
        final result = decodeUpdateOwnTalkRoomSettingsResponse(
          request: request,
          statusCode: entry.key,
          body: _ocs(entry.key, {'error': entry.value.$2}, status: 'failure'),
        );
        final failure = result as OwnTalkSettingsUpdateFailure;
        expect(failure.kind, entry.value.$1);
        expect(failure.errorCode, entry.value.$2);
      }
    });

    test('a garbage error body still maps by status', () {
      final result = decodeUpdateOwnTalkRoomSettingsResponse(
        request: request,
        statusCode: 503,
        body: Uint8List.fromList(utf8.encode('<html>')),
      );
      final failure = result as OwnTalkSettingsUpdateFailure;
      expect(failure.kind, OwnTalkExtensionsFailureKind.unavailable);
      expect(failure.errorCode, isNull);
    });
  });
}

Map<String, Object?> _capabilityJson() => {
  'version': '0.1.0',
  'api': 1,
  'features': [
    'appearance.colors',
    'appearance.bubbles',
    'composer.quickEmoji',
  ],
  'acl': 'roles',
  'roomTypes': ['one2one', 'group', 'public'],
};

Map<String, Object?> _documentJson({
  int revision = 3,
  Map<String, Object?>? settings,
  Map<String, Object?>? fieldRevisions,
  Object? updatedBy = 'alice',
  Object? updatedAt = 1794500000,
}) => {
  'schemaVersion': 1,
  'roomToken': 'abc123xy',
  'revision': revision,
  'settings':
      settings ??
      {
        'chat.backgroundColor': '#1E3A5F',
        'chat.accentColor': null,
        'bubble.ownColor': '#2F6FEB',
        'bubble.ownTextColor': '#FFFFFF',
        'bubble.otherColor': null,
        'bubble.otherTextColor': null,
        'composer.quickEmoji': '\u{1F44D}',
      },
  'fieldRevisions':
      fieldRevisions ?? {'chat.backgroundColor': 3, 'bubble.ownColor': 2},
  'permissions': {'canEdit': true, 'aclSource': 'talk-ocs'},
  'updatedBy': updatedBy,
  'updatedAt': updatedAt,
};

CapabilitySnapshot _snapshot({
  Object? capability = const _Default(),
  CapabilityContext context = CapabilityContext.authenticated,
}) => CapabilitySnapshot.fromJson({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': {
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
          'owntalk_extensions': capability is _Default
              ? _capabilityJson()
              : capability,
      },
    },
  },
}, context: context);

final class _Default {
  const _Default();
}

FetchOwnTalkRoomSettingsRequest _fetch({String? knownEtag}) =>
    FetchOwnTalkRoomSettingsRequest(
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse(_server),
      roomToken: ConversationToken.parse('abc123xy', path: r'$.roomToken'),
      capabilities: _snapshot(),
      knownEtag: knownEtag,
    );

UpdateOwnTalkRoomSettingsRequest _update(
  Map<OwnTalkSettingField, String?> changes, {
  int base = 3,
  Object? capability = const _Default(),
}) => UpdateOwnTalkRoomSettingsRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse(_server),
  roomToken: ConversationToken.parse('abc123xy', path: r'$.roomToken'),
  capabilities: _snapshot(capability: capability),
  changes: changes,
  baseRevision: base,
);

Uint8List _ocs(int statusCode, Object? data, {String status = 'ok'}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ocs': {
            'meta': {
              'status': status,
              'statuscode': statusCode,
              'message': 'x',
            },
            'data': data,
          },
        }),
      ),
    );
