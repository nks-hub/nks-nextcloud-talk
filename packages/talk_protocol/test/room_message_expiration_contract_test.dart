import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('SetMessageExpirationRequest', () {
    test('encodes the v4 moderator endpoint and seconds', () {
      final request = _request(604800);

      expect(request.httpMethod, 'POST');
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/message-expiration?format=json',
      );
      expect(request.formBody, {'seconds': '604800'});
      expect(request.headers['OCS-APIRequest'], 'true');
    });

    test('requires the authenticated message-expiration capability', () {
      for (final capabilities in <CapabilitySnapshot>[
        _capabilities(features: const <Object?>[]),
        _capabilities(context: CapabilityContext.anonymous),
      ]) {
        expect(
          () => _request(3600, capabilities: capabilities),
          throwsA(
            isA<TalkProtocolException>().having(
              (error) => error.code,
              'code',
              TalkProtocolErrorCode.invalidRoomSettingsRequest,
            ),
          ),
        );
      }
    });

    test('accepts off and rejects negative seconds', () {
      expect(_request(0).formBody, {'seconds': '0'});
      expect(
        () => _request(-1),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidRoomSettingsRequest,
          ),
        ),
      );
    });
  });

  group('decodeSetMessageExpirationResponse', () {
    test('returns the authoritative refreshed room', () {
      final room = _roomJson()..['messageExpiration'] = 28800;

      final response = decodeSetMessageExpirationResponse(
        request: _request(28800),
        statusCode: 200,
        body: _ocsBody(status: 'ok', statusCode: 200, data: room),
      );

      expect(response, isA<SetMessageExpirationSuccess>());
      expect(
        (response as SetMessageExpirationSuccess)
            .room
            .wire['messageExpiration'],
        28800,
      );
    });

    test('rejects a negative authoritative expiration', () {
      final room = _roomJson()..['messageExpiration'] = -1;
      expect(
        () => decodeSetMessageExpirationResponse(
          request: _request(28800),
          statusCode: 200,
          body: _ocsBody(status: 'ok', statusCode: 200, data: room),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('preserves every documented rejection reason and forced value', () {
      final cases = <String, MessageExpirationRejection>{
        'breakout-room': MessageExpirationRejection.breakoutRoom,
        'type': MessageExpirationRejection.conversationType,
        'value': MessageExpirationRejection.value,
        'forced': MessageExpirationRejection.forced,
      };
      for (final entry in cases.entries) {
        final response = decodeSetMessageExpirationResponse(
          request: _request(3600),
          statusCode: 400,
          body: _ocsBody(
            status: 'failure',
            statusCode: 400,
            data: {
              'error': entry.key,
              if (entry.key == 'forced') 'forced': 86400,
            },
          ),
        );
        expect(response, isA<SetMessageExpirationRejected>());
        final rejected = response as SetMessageExpirationRejected;
        expect(rejected.reason, entry.value);
        expect(rejected.forcedSeconds, entry.key == 'forced' ? 86400 : isNull);
      }
    });

    test('rejects unknown reasons and malformed forced values', () {
      for (final data in <Map<String, Object?>>[
        {'error': 'unknown'},
        {'error': 'forced'},
        {'error': 'forced', 'forced': -1},
        {'error': 'value', 'forced': 3600},
      ]) {
        expect(
          () => decodeSetMessageExpirationResponse(
            request: _request(3600),
            statusCode: 400,
            body: _ocsBody(status: 'failure', statusCode: 400, data: data),
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
    });

    test('classifies authorization, missing room and retryable failures', () {
      final request = _request(3600);
      final envelopes = <int, Matcher>{
        401: isA<SetMessageExpirationReauthenticationRequired>(),
        403: isA<SetMessageExpirationForbidden>(),
        404: isA<SetMessageExpirationRoomMissing>(),
      };
      for (final entry in envelopes.entries) {
        expect(
          decodeSetMessageExpirationResponse(
            request: request,
            statusCode: entry.key,
            body: _ocsBody(status: 'failure', statusCode: entry.key),
          ),
          entry.value,
        );
      }
      for (final statusCode in [429, 503]) {
        final response = decodeSetMessageExpirationResponse(
          request: request,
          statusCode: statusCode,
          body: Uint8List(0),
        );
        expect(response, isA<SetMessageExpirationHttpFailure>());
        expect(response.statusCode, statusCode);
      }
    });
  });
}

SetMessageExpirationRequest _request(
  int seconds, {
  CapabilitySnapshot? capabilities,
}) {
  return SetMessageExpirationRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    capabilities: capabilities ?? _capabilities(),
    seconds: seconds,
  );
}

CapabilitySnapshot _capabilities({
  CapabilityContext context = CapabilityContext.authenticated,
  Object? features = const <Object?>['message-expiration'],
}) {
  return CapabilitySnapshot.fromJson({
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
}

Uint8List _ocsBody({
  required String status,
  required int statusCode,
  Object? data = const <Object?>[],
}) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'ocs': {
          'meta': {
            'status': status,
            'statuscode': statusCode,
            'message': status,
          },
          'data': data,
        },
      }),
    ),
  );
}

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
