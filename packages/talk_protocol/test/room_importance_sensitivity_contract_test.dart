import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('conversation importance and sensitivity requests', () {
    test(
      'encode capability-bound POST and DELETE endpoints without a body',
      () {
        for (final enabled in <bool>[true, false]) {
          final important = _importantRequest(enabled);
          expect(important.httpMethod, enabled ? 'POST' : 'DELETE');
          expect(
            important.uri.toString(),
            'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/'
            'room/rooma123/important?format=json',
          );
          expect(important.headers['OCS-APIRequest'], 'true');

          final sensitive = _sensitiveRequest(enabled);
          expect(sensitive.httpMethod, enabled ? 'POST' : 'DELETE');
          expect(
            sensitive.uri.toString(),
            'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/'
            'room/rooma123/sensitive?format=json',
          );
          expect(sensitive.headers['OCS-APIRequest'], 'true');
        }
      },
    );

    test('require their exact authenticated capabilities', () {
      for (final capabilities in <CapabilitySnapshot>[
        _capabilities(features: const <Object?>[]),
        _capabilities(context: CapabilityContext.anonymous),
      ]) {
        expect(
          () => _importantRequest(true, capabilities: capabilities),
          _invalidRequest,
        );
        expect(
          () => _sensitiveRequest(true, capabilities: capabilities),
          _invalidRequest,
        );
      }

      expect(
        () => _importantRequest(
          true,
          capabilities: _capabilities(
            features: const <Object?>['sensitive-conversations'],
          ),
        ),
        _invalidRequest,
      );
      expect(
        () => _sensitiveRequest(
          true,
          capabilities: _capabilities(
            features: const <Object?>['important-conversations'],
          ),
        ),
        _invalidRequest,
      );
    });
  });

  group('decodeSetImportantResponse', () {
    test('returns the authoritative room only when it matches the request', () {
      final response = decodeSetImportantResponse(
        request: _importantRequest(true),
        statusCode: 200,
        body: _roomBody(isImportant: true),
      );
      expect(response, isA<SetImportantSuccess>());
      expect((response as SetImportantSuccess).room.isImportant, isTrue);

      expect(
        () => decodeSetImportantResponse(
          request: _importantRequest(true),
          statusCode: 200,
          body: _roomBody(isImportant: false),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('classifies auth, missing room and retryable failures', () {
      final request = _importantRequest(false);
      final envelopes = <int, Matcher>{
        401: isA<SetImportantReauthenticationRequired>(),
        404: isA<SetImportantRoomMissing>(),
      };
      for (final entry in envelopes.entries) {
        expect(
          decodeSetImportantResponse(
            request: request,
            statusCode: entry.key,
            body: _failureBody(entry.key),
          ),
          entry.value,
        );
      }
      for (final statusCode in <int>[429, 503]) {
        final response = decodeSetImportantResponse(
          request: request,
          statusCode: statusCode,
          body: Uint8List(0),
        );
        expect(response, isA<SetImportantHttpFailure>());
        expect(response.statusCode, statusCode);
      }
    });
  });

  group('decodeSetSensitiveResponse', () {
    test('returns the authoritative room only when it matches the request', () {
      final response = decodeSetSensitiveResponse(
        request: _sensitiveRequest(true),
        statusCode: 200,
        body: _roomBody(isSensitive: true),
      );
      expect(response, isA<SetSensitiveSuccess>());
      expect((response as SetSensitiveSuccess).room.isSensitive, isTrue);

      expect(
        () => decodeSetSensitiveResponse(
          request: _sensitiveRequest(false),
          statusCode: 200,
          body: _roomBody(isSensitive: true),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test(
      'preserves the classified-room refusal and rejects malformed 400s',
      () {
        final response = decodeSetSensitiveResponse(
          request: _sensitiveRequest(false),
          statusCode: 400,
          body: _failureBody(400, data: const {'error': 'classified'}),
        );
        expect(response, isA<SetSensitiveRejected>());
        expect(
          (response as SetSensitiveRejected).reason,
          SensitiveRejection.classified,
        );

        for (final data in <Object?>[
          const {'error': 'other'},
          const <Object?>[],
        ]) {
          expect(
            () => decodeSetSensitiveResponse(
              request: _sensitiveRequest(false),
              statusCode: 400,
              body: _failureBody(400, data: data),
            ),
            throwsA(isA<TalkProtocolException>()),
          );
        }
      },
    );

    test('classifies auth, missing room and retryable failures', () {
      final request = _sensitiveRequest(true);
      final envelopes = <int, Matcher>{
        401: isA<SetSensitiveReauthenticationRequired>(),
        404: isA<SetSensitiveRoomMissing>(),
      };
      for (final entry in envelopes.entries) {
        expect(
          decodeSetSensitiveResponse(
            request: request,
            statusCode: entry.key,
            body: _failureBody(entry.key),
          ),
          entry.value,
        );
      }
      for (final statusCode in <int>[429, 503]) {
        final response = decodeSetSensitiveResponse(
          request: request,
          statusCode: statusCode,
          body: Uint8List(0),
        );
        expect(response, isA<SetSensitiveHttpFailure>());
        expect(response.statusCode, statusCode);
      }
    });
  });
}

final Matcher _invalidRequest = throwsA(
  isA<TalkProtocolException>().having(
    (error) => error.code,
    'code',
    TalkProtocolErrorCode.invalidRoomSettingsRequest,
  ),
);

SetImportantRequest _importantRequest(
  bool important, {
  CapabilitySnapshot? capabilities,
}) => SetImportantRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
  capabilities: capabilities ?? _capabilities(),
  important: important,
);

SetSensitiveRequest _sensitiveRequest(
  bool sensitive, {
  CapabilitySnapshot? capabilities,
}) => SetSensitiveRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
  capabilities: capabilities ?? _capabilities(),
  sensitive: sensitive,
);

CapabilitySnapshot _capabilities({
  CapabilityContext context = CapabilityContext.authenticated,
  Object? features = const <Object?>[
    'important-conversations',
    'sensitive-conversations',
  ],
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
        'spreed': {'features': features},
      },
    },
  },
}, context: context);

Uint8List _roomBody({bool? isImportant, bool? isSensitive}) {
  final room = _roomJson();
  if (isImportant != null) room['isImportant'] = isImportant;
  if (isSensitive != null) room['isSensitive'] = isSensitive;
  return _ocsBody(statusCode: 200, data: room);
}

Uint8List _failureBody(int statusCode, {Object? data = const <Object?>[]}) =>
    _ocsBody(statusCode: statusCode, data: data, status: 'failure');

Uint8List _ocsBody({
  required int statusCode,
  required Object? data,
  String status = 'ok',
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'ocs': {
        'meta': {'status': status, 'statuscode': statusCode, 'message': status},
        'data': data,
      },
    }),
  ),
);

Map<String, Object?> _roomJson() {
  final response =
      jsonDecode(
            File(
              '${_repoRoot().path}/contracts/conversation-list/fixtures/'
              'conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
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
