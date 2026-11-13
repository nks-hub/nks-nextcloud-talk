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

    test('a quick emoji with bidi or zero-width characters is refused, an '
        'emoji ZWJ sequence is kept', () {
      for (final hostile in [
        '\u202E\u{1F44D}',
        '\u{1F44D}\u200B',
        '\uFEFF\u{1F44D}',
        '\u2066\u{1F44D}\u2069',
      ]) {
        expect(
          normalizeOwnTalkSettingValue(
            OwnTalkSettingField.composerQuickEmoji,
            hostile,
          ),
          isNull,
          reason: hostile.runes.map((r) => r.toRadixString(16)).join(' '),
        );
      }
      const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
      expect(
        normalizeOwnTalkSettingValue(
          OwnTalkSettingField.composerQuickEmoji,
          family,
        ),
        family,
      );
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
        expect(
          (result as OwnTalkSettingsLoaded).etag,
          isNull,
          reason: '$headers',
        );
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

  group('capability 0.3.0', () {
    test('carries the presets in server order and the upload limits', () {
      final capability = _snapshot(
        capability: _v3Capability(),
      ).ownTalkExtensions!;
      expect(capability.presets, [
        'aurora',
        'sunset',
        'forest',
        'ocean',
        'dots',
        'grid',
      ]);
      expect(capability.imageLimits!.maxImageBytes, 10485760);
      expect(capability.imageLimits!.maxImageEdge, 2560);
      expect(capability.maxImageBytes, 10485760);
      expect(
        capability.supportsField(OwnTalkSettingField.chatBackgroundPreset),
        isTrue,
      );
      expect(
        capability.supportsField(OwnTalkSettingField.chatBackgroundImage),
        isTrue,
      );
    });

    test('tolerates a server without presets and limits', () {
      final capability = _snapshot().ownTalkExtensions!;
      expect(capability.presets, isEmpty);
      expect(capability.imageLimits, isNull);
      expect(capability.maxImageBytes, ownTalkDefaultMaxImageBytes);
      expect(capability.maxImageEdge, ownTalkDefaultMaxImageEdge);
      expect(
        capability.supportsField(OwnTalkSettingField.chatBackgroundPreset),
        isFalse,
      );
    });

    test('malformed presets and limits never switch the extension off', () {
      for (final broken in <Map<String, Object?>>[
        {'presets': 'aurora', 'limits': 'big'},
        {'presets': null, 'limits': <Object?>[]},
        {
          'presets': [1, 'Bad Id', '', 'aurora', 'aurora'],
          'limits': {'maxImageBytes': '10', 'maxImageEdge': 2560},
        },
        {
          'presets': ['aurora'],
          'limits': {'maxImageBytes': 0, 'maxImageEdge': 2560},
        },
        {
          'presets': ['aurora'],
          'limits': {'maxImageBytes': 1024},
        },
      ]) {
        final capability = _snapshot(
          capability: {..._v3Capability(), ...broken},
        ).ownTalkExtensions;
        expect(capability, isNotNull, reason: '$broken');
        expect(capability!.imageLimits, isNull, reason: '$broken');
        expect(
          capability.presets,
          anyOf(isEmpty, ['aurora']),
          reason: '$broken',
        );
      }
    });

    test('compares presets and limits', () {
      final first = _snapshot(capability: _v3Capability()).ownTalkExtensions;
      final same = _snapshot(capability: _v3Capability()).ownTalkExtensions;
      final other = _snapshot(
        capability: {
          ..._v3Capability(),
          'presets': ['aurora'],
        },
      ).ownTalkExtensions;
      expect(first, same);
      expect(first, isNot(other));
    });
  });

  group('background values', () {
    test('a preset is a short lower-case ID, an image a lower-case sha256', () {
      expect(
        normalizeOwnTalkSettingValue(
          OwnTalkSettingField.chatBackgroundPreset,
          'aurora',
        ),
        'aurora',
      );
      for (final bad in ['Aurora', '', 'a b', 'x' * 33, 'dots!']) {
        expect(
          normalizeOwnTalkSettingValue(
            OwnTalkSettingField.chatBackgroundPreset,
            bad,
          ),
          isNull,
          reason: bad,
        );
      }
      expect(
        normalizeOwnTalkSettingValue(
          OwnTalkSettingField.chatBackgroundImage,
          _sha,
        ),
        _sha,
      );
      for (final bad in [
        _sha.toUpperCase(),
        _sha.substring(1),
        '${_sha}0',
        'g' * 64,
        '',
      ]) {
        expect(
          normalizeOwnTalkSettingValue(
            OwnTalkSettingField.chatBackgroundImage,
            bad,
          ),
          isNull,
          reason: bad,
        );
      }
      expect(isOwnTalkImageHash(_sha), isTrue);
      expect(isOwnTalkImageHash('abc'), isFalse);
    });

    test('the document carries preset and image', () {
      final document = OwnTalkRoomSettings.fromJson(
        _documentJson(
          settings: {
            'chat.backgroundPreset': 'forest',
            'chat.backgroundImage': _sha,
          },
        ),
      );
      expect(document[OwnTalkSettingField.chatBackgroundPreset], 'forest');
      expect(document[OwnTalkSettingField.chatBackgroundImage], _sha);
      expect(
        OwnTalkRoomSettings.fromJson(
          jsonDecode(jsonEncode(document.toJson())),
        ).toJson(),
        document.toJson(),
      );
    });

    test('a malformed preset or image in a document is a protocol failure', () {
      for (final settings in <Map<String, Object?>>[
        {'chat.backgroundPreset': 'Not Valid'},
        {'chat.backgroundPreset': 4},
        {'chat.backgroundImage': 'abc'},
        {'chat.backgroundImage': _sha.toUpperCase()},
      ]) {
        expect(
          () => OwnTalkRoomSettings.fromJson(_documentJson(settings: settings)),
          throwsA(isA<TalkProtocolException>()),
          reason: '$settings',
        );
      }
    });

    test('PATCH may set an offered preset, clear the image, nothing else', () {
      final set = _update({
        OwnTalkSettingField.chatBackgroundPreset: 'ocean',
        OwnTalkSettingField.chatBackgroundImage: null,
      }, capability: _v3Capability());
      expect(jsonDecode(utf8.decode(set.bodyBytes)), {
        'settings': {
          'chat.backgroundPreset': 'ocean',
          'chat.backgroundImage': null,
        },
      });
      expect(
        () => _update({
          OwnTalkSettingField.chatBackgroundPreset: 'neon',
        }, capability: _v3Capability()),
        throwsA(isA<TalkProtocolException>()),
        reason: 'not in the server list',
      );
      expect(
        () => _update({
          OwnTalkSettingField.chatBackgroundImage: _sha,
        }, capability: _v3Capability()),
        throwsA(isA<TalkProtocolException>()),
        reason: 'only the upload sets an image',
      );
      expect(
        () => _update({OwnTalkSettingField.chatBackgroundPreset: 'ocean'}),
        throwsA(isA<TalkProtocolException>()),
        reason: 'feature not announced',
      );
    });
  });

  group('image upload request', () {
    test('is a PUT of the raw bytes with type, If-Match and OCS header', () {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      final request = _upload(bytes: bytes, base: 7);
      expect(request.httpMethod, 'PUT');
      expect(
        request.uri.toString(),
        '$_server/ocs/v2.php/apps/owntalk_extensions/api/v1/room/abc123xy/'
        'settings/image?format=json',
      );
      expect(request.headers['Content-Type'], 'image/jpeg');
      expect(request.headers['If-Match'], '"r7"');
      expect(request.headers['OCS-APIRequest'], 'true');
      expect(request.bodyBytes, bytes);
      bytes[0] = 0;
      expect(request.bodyBytes[0], 0xFF, reason: 'the body is a copy');
    });

    test('accepts jpeg, png and webp only', () {
      for (final type in ['image/jpeg', 'image/png', 'image/webp']) {
        expect(_upload(contentType: type).headers['Content-Type'], type);
      }
      for (final type in ['image/gif', 'image/heic', 'text/plain', '']) {
        expect(
          () => _upload(contentType: type),
          throwsA(isA<TalkProtocolException>()),
          reason: type,
        );
      }
    });

    test('refuses an empty or oversized body and a missing feature', () {
      expect(
        () => _upload(bytes: Uint8List(0)),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => _upload(
          bytes: Uint8List(2049),
          capability: {
            ..._v3Capability(),
            'limits': {'maxImageBytes': 2048, 'maxImageEdge': 1024},
          },
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => _upload(
          capability: {
            ..._v3Capability(),
            'features': ['appearance.colors'],
          },
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(() => _upload(base: -1), throwsA(isA<TalkProtocolException>()));
    });

    test('falls back to the server maximum when no limits are published', () {
      final capability = {..._v3Capability()}..remove('limits');
      expect(
        _upload(bytes: Uint8List(1024), capability: capability).bodyBytes,
        hasLength(1024),
      );
    });
  });

  group('image upload responses', () {
    final request = _upload();

    test('200 yields the saved document and ETag', () {
      final result = decodeUploadOwnTalkRoomImageResponse(
        request: request,
        statusCode: 200,
        body: _ocs(
          200,
          _documentJson(revision: 4, settings: {'chat.backgroundImage': _sha}),
        ),
        headers: {'etag': '"r4-e1"'},
      );
      final saved = result as OwnTalkSettingsSaved;
      expect(saved.document[OwnTalkSettingField.chatBackgroundImage], _sha);
      expect(saved.etag, '"r4-e1"');
    });

    test('412 carries the current document like PATCH does', () {
      final result = decodeUploadOwnTalkRoomImageResponse(
        request: request,
        statusCode: 412,
        body: _ocs(412, {
          'error': 'revision_conflict',
          'current': _documentJson(revision: 5),
          'fields': ['chat.backgroundImage'],
        }, status: 'failure'),
      );
      final conflict = result as OwnTalkSettingsConflict;
      expect(conflict.current.revision, 5);
      expect(conflict.conflictingFields, [
        OwnTalkSettingField.chatBackgroundImage,
      ]);
    });

    test('maps 400, 413, 415, 507 and the rest with the error code', () {
      const expected = {
        400: (OwnTalkExtensionsFailureKind.rejected, 'invalid_image'),
        403: (OwnTalkExtensionsFailureKind.forbidden, 'field_forbidden'),
        404: (OwnTalkExtensionsFailureKind.notFound, 'not_found'),
        413: (
          OwnTalkExtensionsFailureKind.payloadTooLarge,
          'payload_too_large',
        ),
        415: (
          OwnTalkExtensionsFailureKind.unsupportedMediaType,
          'unsupported_media_type',
        ),
        428: (
          OwnTalkExtensionsFailureKind.preconditionRequired,
          'precondition_required',
        ),
        429: (OwnTalkExtensionsFailureKind.rateLimited, 'rate_limited'),
        507: (OwnTalkExtensionsFailureKind.quotaExceeded, 'quota_exceeded'),
      };
      for (final entry in expected.entries) {
        final result = decodeUploadOwnTalkRoomImageResponse(
          request: request,
          statusCode: entry.key,
          body: _ocs(entry.key, {'error': entry.value.$2}, status: 'failure'),
        );
        final failure = result as OwnTalkSettingsUpdateFailure;
        expect(failure.kind, entry.value.$1, reason: '${entry.key}');
        expect(failure.errorCode, entry.value.$2, reason: '${entry.key}');
      }
    });

    test('a proxy page without OCS body still maps 413 by status', () {
      final result = decodeUploadOwnTalkRoomImageResponse(
        request: request,
        statusCode: 413,
        body: Uint8List.fromList(utf8.encode('<html>too big</html>')),
      );
      final failure = result as OwnTalkSettingsUpdateFailure;
      expect(failure.kind, OwnTalkExtensionsFailureKind.payloadTooLarge);
      expect(failure.errorCode, isNull);
    });
  });

  group('image download', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 74, 70]);

    test('GET names the hash in the path and asks for a JPEG', () {
      final request = _fetchImage();
      expect(request.httpMethod, 'GET');
      expect(
        request.uri.toString(),
        '$_server/ocs/v2.php/apps/owntalk_extensions/api/v1/room/abc123xy/'
        'settings/image/$_sha',
      );
      expect(request.headers['OCS-APIRequest'], 'true');
      expect(request.headers['Accept'], 'image/jpeg');
    });

    test('refuses a hash that is not 64 lower-case hex digits', () {
      for (final bad in ['', 'abc', '../settings', _sha.toUpperCase()]) {
        expect(
          () => _fetchImage(sha: bad),
          throwsA(isA<TalkProtocolException>()),
          reason: bad,
        );
      }
      expect(
        () => _fetchImage(capability: _capabilityJson()),
        throwsA(isA<TalkProtocolException>()),
        reason: 'feature not announced',
      );
    });

    test('200 yields the bytes only for a JPEG body', () {
      final request = _fetchImage();
      final loaded = decodeFetchOwnTalkRoomImageResponse(
        request: request,
        statusCode: 200,
        body: jpeg,
      );
      expect((loaded as OwnTalkImageLoaded).bytes, jpeg);
      for (final bad in [
        Uint8List(0),
        Uint8List.fromList(utf8.encode('<html>login</html>')),
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0]),
        Uint8List.fromList([0xFF, 0xD8]),
      ]) {
        expect(
          () => decodeFetchOwnTalkRoomImageResponse(
            request: request,
            statusCode: 200,
            body: bad,
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
    });

    test('404 is "no longer the current image", others map by status', () {
      final request = _fetchImage();
      expect(
        decodeFetchOwnTalkRoomImageResponse(
          request: request,
          statusCode: 404,
          body: Uint8List(0),
        ),
        isA<OwnTalkImageMissing>(),
      );
      final limited =
          decodeFetchOwnTalkRoomImageResponse(
                request: request,
                statusCode: 429,
                body: Uint8List(0),
                headers: {'Retry-After': '30'},
              )
              as OwnTalkImageFetchFailure;
      expect(limited.kind, OwnTalkExtensionsFailureKind.rateLimited);
      expect(limited.retryAfter, const Duration(seconds: 30));
      expect(
        (decodeFetchOwnTalkRoomImageResponse(
                  request: request,
                  statusCode: 403,
                  body: Uint8List(0),
                )
                as OwnTalkImageFetchFailure)
            .kind,
        OwnTalkExtensionsFailureKind.forbidden,
      );
      expect(
        () => decodeFetchOwnTalkRoomImageResponse(
          request: request,
          statusCode: 418,
          body: Uint8List(0),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}

const _sha = '9f2c0d5a1b7e4c3d8a6f5e2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d';

Map<String, Object?> _v3Capability() => {
  ..._capabilityJson(),
  'version': '0.3.0',
  'features': [
    'appearance.colors',
    'appearance.bubbles',
    'appearance.presets',
    'appearance.image',
    'composer.quickEmoji',
  ],
  'presets': ['aurora', 'sunset', 'forest', 'ocean', 'dots', 'grid'],
  'limits': {'maxImageBytes': 10485760, 'maxImageEdge': 2560},
};

UploadOwnTalkRoomImageRequest _upload({
  Uint8List? bytes,
  String contentType = 'image/jpeg',
  int base = 3,
  Object? capability,
}) => UploadOwnTalkRoomImageRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse(_server),
  roomToken: ConversationToken.parse('abc123xy', path: r'$.roomToken'),
  capabilities: _snapshot(capability: capability ?? _v3Capability()),
  bytes: bytes ?? Uint8List.fromList([0xFF, 0xD8, 0xFF, 1]),
  contentType: contentType,
  baseRevision: base,
);

FetchOwnTalkRoomImageRequest _fetchImage({String? sha, Object? capability}) =>
    FetchOwnTalkRoomImageRequest(
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse(_server),
      roomToken: ConversationToken.parse('abc123xy', path: r'$.roomToken'),
      capabilities: _snapshot(capability: capability ?? _v3Capability()),
      sha256: sha ?? _sha,
    );

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
