import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final manifest = _readJsonObject(
    'contracts/conversation-list/fixtures/manifest.json',
  );
  final fixtures = (manifest['fixtures']! as List<Object?>)
      .map(_asObject)
      .toList(growable: false);
  final headerSets = _headerSets(manifest);

  group('conversation response fixtures', () {
    for (final fixture in fixtures) {
      final id = fixture['id']! as String;
      test(id, () {
        ConversationListResponse action() {
          final request = _request(requestId: 'fixture-$id');
          return decodeConversationListResponse(
            request: request,
            statusCode: int.parse(fixture['status']! as String),
            json: _readJson(
              'contracts/conversation-list/fixtures/${fixture['file']}',
            ),
            headers: _fixtureHeaders(fixture, headerSets),
          );
        }

        if (fixture['schemaValid'] == false) {
          expect(
            action,
            throwsA(
              isA<TalkProtocolException>().having(
                (error) => error.code,
                'code',
                TalkProtocolErrorCode.invalidConversationResponse,
              ),
            ),
          );
          return;
        }

        switch (fixture['expectedClassification']) {
          case 'success':
            final response = action();
            expect(response, isA<ConversationListSuccess>());
            final success = response as ConversationListSuccess;
            expect(success.rooms.length, fixture['expectedRoomCount']);
            if (fixture['expectLastMessageAbsent'] == true) {
              expect(
                success.rooms.every((room) => room.lastMessage == null),
                isTrue,
              );
            }
          case 'reauth':
            expect(action(), isA<ConversationReauthenticationRequired>());
          case 'ocs-error':
            expect(action(), isA<ConversationOcsFailure>());
          case 'semantic-error':
            final expectedCode = switch (id) {
              'duplicate-token' =>
                TalkProtocolErrorCode.duplicateConversationToken,
              'preview-token-mismatch' =>
                TalkProtocolErrorCode.previewConversationMismatch,
              _ => throw StateError('Unknown semantic fixture $id'),
            };
            expect(
              action,
              throwsA(
                isA<TalkProtocolException>().having(
                  (error) => error.code,
                  'code',
                  expectedCode,
                ),
              ),
            );
          default:
            fail('Unknown classification ${fixture['expectedClassification']}');
        }
      });
    }
  });

  group('conversation query fixtures', () {
    final root = _readJsonObject(
      'contracts/conversation-list/fixtures/query.cases.json',
    );
    final expectedHeaders = _stringMap(root['expectedHeaders']);
    final cases = (root['cases']! as List<Object?>).map(_asObject);

    for (final testCase in cases) {
      final id = testCase['id']! as String;
      test(id, () {
        ConversationListRequest action() {
          final rawCursor = testCase['cursor'];
          final cursor = rawCursor == null
              ? null
              : ConversationCursor.parse(
                  rawCursor,
                  path: r'$.query.modifiedSince',
                  code: TalkProtocolErrorCode.invalidConversationRequest,
                );
          return _request(
            requestId: 'query-$id',
            mode: switch (testCase['mode']) {
              'full' => ConversationFetchMode.full,
              'incremental' => ConversationFetchMode.incremental,
              _ => throw StateError('Unknown query mode'),
            },
            includeLastMessage: testCase['includeLastMessage']! as bool,
            cursor: cursor,
          );
        }

        if (testCase['expectedError'] == true) {
          expect(action, throwsA(isA<TalkProtocolException>()));
          return;
        }
        final request = action();
        expect(request.queryParameters, _stringMap(testCase['expected']));
        expect(request.headers, expectedHeaders);
      });
    }

    test('builds a subpath-aware v4 URI', () {
      final request = _request(
        requestId: 'subpath-uri',
        server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
        mode: ConversationFetchMode.full,
        includeLastMessage: false,
      );

      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/nextcloud'
        '/ocs/v2.php/apps/spreed/api/v4/room'
        '?format=json&noStatusUpdate=1&includeStatus=false&includeLastMessage=false',
      );
    });
  });

  group('conversation capability fixtures', () {
    final cases =
        (_readJsonObject(
                  'contracts/conversation-list/fixtures/capability.cases.json',
                )['cases']!
                as List<Object?>)
            .map(_asObject);

    for (final testCase in cases) {
      final id = testCase['id']! as String;
      test(id, () {
        ConversationProfile action() {
          final capabilities = CapabilitySnapshot.fromJson(
            _capabilityEnvelope(testCase['talkFeatures']! as List<Object?>),
            context: CapabilityContext.authenticated,
          );
          ConversationProfileProbe? probe;
          final fixtureName = testCase['probeFixture'];
          if (fixtureName != null) {
            final fixture = fixtures.singleWhere(
              (item) => item['file'] == fixtureName,
            );
            probe = ConversationProfileProbe(
              request: _request(
                requestId: 'profile-$id',
                mode: ConversationFetchMode.full,
                includeLastMessage: false,
              ),
              statusCode: int.parse(fixture['status']! as String),
              json: _readJson(
                'contracts/conversation-list/fixtures/$fixtureName',
              ),
              headers: _stringMap(testCase['probeHeaders']),
            );
          }
          return resolveConversationProfile(
            capabilities: capabilities,
            probe: probe,
          );
        }

        if (testCase['expectedError'] == true) {
          expect(action, throwsA(isA<TalkProtocolException>()));
          return;
        }
        final expected = _asObject(testCase['expected']);
        final profile = action();
        expect(profile.candidatePath, expected['candidatePath']);
        expect(profile.activePath, expected['activePath']);
        expect(profile.status, switch (expected['profile']) {
          'unsupported' => ConversationProfileStatus.unsupported,
          'candidate' => ConversationProfileStatus.candidate,
          'cursor-v4' => ConversationProfileStatus.cursorV4,
          'unsupported-wire-profile' =>
            ConversationProfileStatus.unsupportedWireProfile,
          'deferred' => ConversationProfileStatus.deferred,
          'reauthentication-required' =>
            ConversationProfileStatus.reauthenticationRequired,
          _ => throw StateError('Unknown expected profile'),
        });
        expect(profile.deferralReason, switch (expected['deferralReason']) {
          null => isNull,
          'ocs-failure' => ConversationProfileDeferralReason.ocsFailure,
          _ => throw StateError('Unknown expected deferral reason'),
        });
      });
    }

    test('anonymous capability discovery cannot activate a profile', () {
      final capabilities = CapabilitySnapshot.fromJson(
        _capabilityEnvelope(<Object?>['conversation-v4']),
        context: CapabilityContext.anonymous,
      );

      expect(
        resolveConversationProfile(capabilities: capabilities).status,
        ConversationProfileStatus.unsupported,
      );
    });

    test('an incremental response cannot confirm the wire profile', () {
      final capabilities = CapabilitySnapshot.fromJson(
        _capabilityEnvelope(<Object?>['conversation-v4']),
        context: CapabilityContext.authenticated,
      );
      final profile = resolveConversationProfile(
        capabilities: capabilities,
        probe: ConversationProfileProbe(
          request: _request(
            requestId: 'incremental-profile',
            mode: ConversationFetchMode.incremental,
            includeLastMessage: false,
            cursor: ConversationCursor.parse('0'),
          ),
          statusCode: 200,
          json: _readJson(
            'contracts/conversation-list/fixtures/'
            'conversations-full.response.json',
          ),
          headers: headerSets['full']!,
        ),
      );

      expect(profile.status, ConversationProfileStatus.deferred);
      expect(
        profile.deferralReason,
        ConversationProfileDeferralReason.fullProbeRequired,
      );
      expect(profile.activePath, isNull);
    });
  });

  group('classified HTTP failures', () {
    final expected = <int, ConversationHttpFailureKind>{
      426: ConversationHttpFailureKind.upgradeRequired,
      429: ConversationHttpFailureKind.rateLimited,
      503: ConversationHttpFailureKind.serviceUnavailable,
    };
    for (final entry in expected.entries) {
      test('${entry.key}', () {
        final response = decodeConversationListResponse(
          request: _request(requestId: 'http-${entry.key}'),
          statusCode: entry.key,
          json: null,
        );

        expect(response, isA<ConversationHttpFailure>());
        expect((response as ConversationHttpFailure).kind, entry.value);
      });
    }

    test('does not guess an unknown status', () {
      expect(
        () => decodeConversationListResponse(
          request: _request(requestId: 'http-500'),
          statusCode: 500,
          json: null,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.unsupportedHttpStatus,
          ),
        ),
      );
    });
  });

  group('conversation profile probe failures', () {
    final capabilities = CapabilitySnapshot.fromJson(
      _capabilityEnvelope(<Object?>['conversation-v4']),
      context: CapabilityContext.authenticated,
    );

    final deferredFailures = <int, ConversationProfileDeferralReason>{
      426: ConversationProfileDeferralReason.upgradeRequired,
      429: ConversationProfileDeferralReason.rateLimited,
      503: ConversationProfileDeferralReason.serviceUnavailable,
    };
    for (final entry in deferredFailures.entries) {
      test('${entry.key} defers profile confirmation', () {
        final profile = resolveConversationProfile(
          capabilities: capabilities,
          probe: ConversationProfileProbe(
            request: _request(
              requestId: 'deferred-profile-${entry.key}',
              mode: ConversationFetchMode.full,
              includeLastMessage: false,
            ),
            statusCode: entry.key,
            json: null,
            headers: const <String, String>{},
          ),
        );

        expect(profile.status, ConversationProfileStatus.deferred);
        expect(profile.deferralReason, entry.value);
        expect(profile.isActive, isFalse);
      });
    }

    test('401 requires reauthentication without disabling the profile', () {
      final profile = resolveConversationProfile(
        capabilities: capabilities,
        probe: ConversationProfileProbe(
          request: _request(requestId: 'reauthentication-profile'),
          statusCode: 401,
          json: _readJson(
            'contracts/conversation-list/fixtures/'
            'conversations-unauthorized.response.json',
          ),
          headers: const <String, String>{},
        ),
      );

      expect(
        profile.status,
        ConversationProfileStatus.reauthenticationRequired,
      );
      expect(profile.requiresReauthentication, isTrue);
      expect(profile.activePath, isNull);
    });

    test('401 takes precedence over an incremental probe mode', () {
      final profile = resolveConversationProfile(
        capabilities: capabilities,
        probe: ConversationProfileProbe(
          request: _request(
            requestId: 'incremental-reauthentication-profile',
            mode: ConversationFetchMode.incremental,
            cursor: ConversationCursor.parse('0'),
          ),
          statusCode: 401,
          json: _readJson(
            'contracts/conversation-list/fixtures/'
            'conversations-unauthorized.response.json',
          ),
          headers: const <String, String>{},
        ),
      );

      expect(
        profile.status,
        ConversationProfileStatus.reauthenticationRequired,
      );
      expect(profile.requiresReauthentication, isTrue);
    });

    test('an OCS failure is classified without success-only headers', () {
      final request = _request(requestId: 'ocs-failure-without-headers');
      final response = decodeConversationListResponse(
        request: request,
        statusCode: 200,
        json: _readJson(
          'contracts/conversation-list/fixtures/'
          'conversations-ocs-failure.response.json',
        ),
      );

      expect(response, isA<ConversationOcsFailure>());
      expect(identical(response.request, request), isTrue);
    });
  });
}

ConversationListRequest _request({
  required String requestId,
  AccountId? accountId,
  ServerBase? server,
  ConversationFetchMode mode = ConversationFetchMode.full,
  bool includeLastMessage = false,
  ConversationCursor? cursor,
}) {
  return ConversationListRequest(
    accountId: accountId ?? AccountId.parse('fixture-account'),
    requestId: ConversationRequestId.parse(requestId),
    server: server ?? ServerBase.parse('https://cloud.example.invalid'),
    mode: mode,
    includeLastMessage: includeLastMessage,
    cursor: cursor,
  );
}

Map<String, Object?> _capabilityEnvelope(List<Object?> features) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'version': <String, Object?>{
          'major': 99,
          'minor': 0,
          'micro': 0,
          'string': '99.0.0',
          'edition': '',
        },
        'capabilities': <String, Object?>{
          'spreed': <String, Object?>{'features': features},
        },
      },
    },
  };
}

Map<String, Map<String, String>> _headerSets(Map<String, Object?> manifest) {
  return _asObject(
    manifest['headerSets'],
  ).map((key, value) => MapEntry(key, _stringMap(value)));
}

Map<String, String> _fixtureHeaders(
  Map<String, Object?> fixture,
  Map<String, Map<String, String>> headerSets,
) {
  final headerSet = fixture['headerSet'];
  return headerSet == null ? const <String, String>{} : headerSets[headerSet]!;
}

Object? _readJson(String relativePath) {
  final file = File('${_repoRoot().path}/$relativePath');
  return jsonDecode(file.readAsStringSync());
}

Map<String, Object?> _readJsonObject(String relativePath) {
  return _asObject(_readJson(relativePath));
}

Map<String, Object?> _asObject(Object? value) {
  return (value! as Map<Object?, Object?>).cast<String, Object?>();
}

Map<String, String> _stringMap(Object? value) {
  return (value! as Map<Object?, Object?>).cast<String, String>();
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/conversation-list/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
