import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('call capability profile', () {
    test('requires the authenticated modern call capability slice', () {
      final profile = CallCapabilityProfile.fromSnapshot(_capabilities());

      expect(profile.enabled, isTrue);
      expect(profile.silent, isTrue);
      expect(profile.recordingConsent, isTrue);
      expect(profile.recordingConsentMode, 2);
      expect(profile.revision, 'call-v4:1:1:1:2');
    });

    test('fails closed when a required feature or config gate is absent', () {
      const requiredFeatures = <String>{
        'conversation-v4',
        'conversation-permissions',
        'in-call-flags',
        'silent-call',
        'recording-consent',
      };
      for (final missing in requiredFeatures) {
        final profile = CallCapabilityProfile.fromSnapshot(
          _capabilities(features: requiredFeatures.difference({missing})),
        );
        expect(profile.enabled, isFalse, reason: missing);
      }
      expect(
        CallCapabilityProfile.fromSnapshot(
          _capabilities(callEnabled: false),
        ).enabled,
        isFalse,
      );
    });

    test('rejects anonymous and malformed recording consent snapshots', () {
      expect(
        () => CallCapabilityProfile.fromSnapshot(
          _capabilities(context: CapabilityContext.anonymous),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidCallProfile),
      );
      expect(
        () => CallCapabilityProfile.fromSnapshot(
          _capabilities(recordingConsentMode: 3),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidCallProfile),
      );
    });
  });

  group('call v4 requests', () {
    test('binds account authority and exact wire fields', () {
      final context = CallRequestContext(
        authority: _authority(),
        mutationSequence: 7,
      );
      final request = JoinCallRequest(
        context: context,
        flags: CallInCallFlags.audioVideo(),
        silent: true,
        recordingConsent: true,
        silentFor: <ConversationSessionId>[
          ConversationSessionId.parse('previous-session-a'),
          ConversationSessionId.parse('previous-session-b'),
        ],
      );

      expect(request.method, CallRestMethod.post);
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/nextcloud/ocs/v2.php/apps/spreed/'
        'api/v4/call/rooma123?format=json',
      );
      expect(request.headers['OCS-APIRequest'], 'true');
      expect(request.formFields, <String, List<String>>{
        'flags': <String>['7'],
        'silent': <String>['1'],
        'recordingConsent': <String>['1'],
        'silentFor[]': <String>['previous-session-a', 'previous-session-b'],
      });

      final update = UpdateCallFlagsRequest(
        context: context,
        flags: CallInCallFlags.parse(3, requireJoined: true),
      );
      expect(update.method, CallRestMethod.put);
      expect(update.formFields, <String, List<String>>{
        'flags': <String>['3'],
      });

      final leave = LeaveCallRequest(context: context, endForEveryone: true);
      expect(leave.method, CallRestMethod.delete);
      expect(leave.uri.queryParameters, <String, String>{
        'all': '1',
        'format': 'json',
      });
    });

    test('rejects disconnected flags and duplicate silent sessions', () {
      final context = CallRequestContext(
        authority: _authority(),
        mutationSequence: 1,
      );
      expect(
        () => JoinCallRequest(
          context: context,
          flags: CallInCallFlags.parse(0),
          silent: false,
          recordingConsent: false,
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidCallRequest),
      );
      expect(
        () => JoinCallRequest(
          context: context,
          flags: CallInCallFlags.audioVideo(),
          silent: false,
          recordingConsent: false,
          silentFor: <ConversationSessionId>[
            ConversationSessionId.parse('same-session'),
            ConversationSessionId.parse('same-session'),
          ],
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidCallRequest),
      );
    });
  });

  group('call responses', () {
    test('parses bounded peers and identifies the current session', () {
      final request = CallPeersRequest(
        context: CallRequestContext(
          authority: _authority(),
          mutationSequence: 0,
        ),
      );
      final response = decodeCallRestResponse(
        request: request,
        statusCode: 200,
        body: _ocsBody(<Object?>[
          _peer(sessionId: 'session-a'),
          _peer(sessionId: 'session-b', actorId: 'bob'),
        ]),
      );

      expect(response.classification, CallResponseClassification.confirmed);
      expect(response.peers, hasLength(2));
      expect(response.ownSessionPresent, isTrue);
      expect(response.toString(), isNot(contains('session-a')));
      expect(response.toString(), isNot(contains('bob')));
    });

    test('rejects cross-room and duplicate-session peer lists', () {
      final request = CallPeersRequest(
        context: CallRequestContext(
          authority: _authority(),
          mutationSequence: 0,
        ),
      );
      expect(
        () => decodeCallRestResponse(
          request: request,
          statusCode: 200,
          body: _ocsBody(<Object?>[_peer(token: 'other123')]),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidCallResponse),
      );
      expect(
        () => decodeCallRestResponse(
          request: request,
          statusCode: 200,
          body: _ocsBody(<Object?>[
            _peer(sessionId: 'duplicate'),
            _peer(sessionId: 'duplicate'),
          ]),
        ),
        _protocolFailure(TalkProtocolErrorCode.invalidCallResponse),
      );
    });

    test('classifies every deterministic and transient HTTP family', () {
      final request = JoinCallRequest(
        context: CallRequestContext(
          authority: _authority(),
          mutationSequence: 1,
        ),
        flags: CallInCallFlags.audioVideo(),
        silent: false,
        recordingConsent: false,
      );
      const expected = <int, CallResponseClassification>{
        400: CallResponseClassification.rejected,
        401: CallResponseClassification.reauthenticationRequired,
        403: CallResponseClassification.forbidden,
        404: CallResponseClassification.sessionMissing,
        409: CallResponseClassification.conflict,
        429: CallResponseClassification.rateLimited,
        500: CallResponseClassification.serverFailure,
        599: CallResponseClassification.serverFailure,
      };
      for (final entry in expected.entries) {
        final response = decodeCallRestResponse(
          request: request,
          statusCode: entry.key,
          body: Uint8List(0),
        );
        expect(response.classification, entry.value, reason: '${entry.key}');
      }
      expect(
        () => decodeCallRestResponse(
          request: request,
          statusCode: 418,
          body: Uint8List(0),
        ),
        _protocolFailure(TalkProtocolErrorCode.unsupportedHttpStatus),
      );
    });

    test('retains the bounded Talk error from a failure envelope', () {
      final request = JoinCallRequest(
        context: CallRequestContext(
          authority: _authority(),
          mutationSequence: 1,
        ),
        flags: CallInCallFlags.audioVideo(),
        silent: false,
        recordingConsent: false,
      );
      final response = decodeCallRestResponse(
        request: request,
        statusCode: 400,
        body: _ocsFailureBody('consent'),
      );

      expect(response.classification, CallResponseClassification.rejected);
      expect(response.errorCode, 'consent');
    });
  });
}

CapabilitySnapshot _capabilities({
  CapabilityContext context = CapabilityContext.authenticated,
  Set<String> features = const <String>{
    'conversation-v4',
    'conversation-permissions',
    'in-call-flags',
    'silent-call',
    'recording-consent',
  },
  bool callEnabled = true,
  int recordingConsentMode = 2,
}) => CapabilitySnapshot.fromJson(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'version': <String, Object?>{
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': <String, Object?>{
        'spreed': <String, Object?>{
          'features': features.toList(),
          'config': <String, Object?>{
            'call': <String, Object?>{
              'enabled': callEnabled,
              'recording-consent': recordingConsentMode,
            },
          },
        },
      },
    },
  },
}, context: context);

CallLifecycleAuthority _authority() => CallLifecycleAuthority(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
  nextcloudSessionId: ConversationSessionId.parse('session-a'),
  credentialGeneration: 2,
  capabilityGeneration: 3,
  capabilityRevision: 'call-v4:1:1:1:2',
);

Map<String, Object?> _peer({
  String sessionId = 'session-a',
  String token = 'rooma123',
  String actorId = 'alice',
}) => <String, Object?>{
  'actorType': 'users',
  'actorId': actorId,
  'displayName': actorId,
  'token': token,
  'lastPing': 1770000000,
  'sessionId': sessionId,
};

Uint8List _ocsBody(Object? data) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': data,
      },
    }),
  ),
);

Uint8List _ocsFailureBody(String error) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'failure',
          'statuscode': 400,
          'message': 'Rejected',
        },
        'data': <String, Object?>{'error': error},
      },
    }),
  ),
);

Matcher _protocolFailure(TalkProtocolErrorCode code) => throwsA(
  isA<TalkProtocolException>().having((error) => error.code, 'code', code),
);
