import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

ParticipantsRequest _request() {
  return ParticipantsRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
  );
}

Uint8List _ocsBody({
  required String status,
  required int statusCode,
  Object? data,
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

Map<String, Object?> _participant({
  int attendeeId = 1,
  String actorType = 'users',
  String actorId = 'synthetic-user-a',
  String displayName = 'Synthetic User A',
  int participantType = 3,
  int lastPing = 1724300000,
  List<String> sessionIds = const <String>[],
  int permissions = 254,
  int attendeePermissions = 0,
  int inCall = 0,
  String? status,
  String? statusIcon,
  String? statusMessage,
}) {
  return {
    'attendeeId': attendeeId,
    'actorType': actorType,
    'actorId': actorId,
    'displayName': displayName,
    'participantType': participantType,
    'lastPing': lastPing,
    'sessionIds': sessionIds,
    'permissions': permissions,
    'attendeePermissions': attendeePermissions,
    'inCall': inCall,
    'status': ?status,
    'statusIcon': ?statusIcon,
    'statusMessage': ?statusMessage,
  };
}

void main() {
  group('participants response contract', () {
    test('decodes a validated participant list with roles and status', () {
      final body = _ocsBody(
        status: 'ok',
        statusCode: 200,
        data: [
          _participant(
            attendeeId: 1,
            participantType: 1,
            displayName: 'Synthetic Owner',
          ),
          _participant(
            attendeeId: 2,
            participantType: 2,
            displayName: 'Synthetic Moderator',
            sessionIds: const ['session-a'],
            status: 'online',
          ),
          _participant(
            attendeeId: 3,
            actorType: 'guests',
            actorId: 'synthetic-guest-a',
            participantType: 4,
            displayName: 'Synthetic Guest',
            status: 'away',
            statusIcon: '☕',
            statusMessage: 'Back soon',
          ),
        ],
      );

      final response = decodeParticipantsResponse(
        request: _request(),
        statusCode: 200,
        body: body,
      );

      expect(response, isA<ParticipantsSuccess>());
      final success = response as ParticipantsSuccess;
      expect(success.participants, hasLength(3));

      final owner = success.participants[0];
      expect(owner.role, ParticipantRole.owner);
      expect(owner.hasOpenSession, isFalse);
      expect(owner.status, isNull);

      final moderator = success.participants[1];
      expect(moderator.role, ParticipantRole.moderator);
      expect(moderator.hasOpenSession, isTrue);
      expect(moderator.status, 'online');

      final guest = success.participants[2];
      expect(guest.role, ParticipantRole.guest);
      expect(guest.status, 'away');
      expect(guest.statusIcon, '☕');
      expect(guest.statusMessage, 'Back soon');
    });

    test('keeps an unrecognised participantType without guessing a role', () {
      final body = _ocsBody(
        status: 'ok',
        statusCode: 200,
        data: [_participant(participantType: 42)],
      );

      final response =
          decodeParticipantsResponse(
                request: _request(),
                statusCode: 200,
                body: body,
              )
              as ParticipantsSuccess;

      expect(response.participants.single.participantType, 42);
      expect(response.participants.single.role, isNull);
    });

    test('rejects a duplicate attendeeId', () {
      final body = _ocsBody(
        status: 'ok',
        statusCode: 200,
        data: [_participant(attendeeId: 1), _participant(attendeeId: 1)],
      );

      expect(
        () => decodeParticipantsResponse(
          request: _request(),
          statusCode: 200,
          body: body,
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidParticipantsResponse,
          ),
        ),
      );
    });

    test('rejects a participant missing a required field', () {
      final malformed = _participant()..remove('permissions');
      final body = _ocsBody(status: 'ok', statusCode: 200, data: [malformed]);

      expect(
        () => decodeParticipantsResponse(
          request: _request(),
          statusCode: 200,
          body: body,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('classifies 401 as reauthentication required', () {
      final body = _ocsBody(status: 'failure', statusCode: 401, data: []);
      final response = decodeParticipantsResponse(
        request: _request(),
        statusCode: 401,
        body: body,
      );
      expect(response, isA<ParticipantsReauthenticationRequired>());
    });

    test('classifies 403 as forbidden', () {
      final body = _ocsBody(status: 'failure', statusCode: 403, data: []);
      final response = decodeParticipantsResponse(
        request: _request(),
        statusCode: 403,
        body: body,
      );
      expect(response, isA<ParticipantsForbidden>());
    });

    test('classifies 404 as room missing', () {
      final body = _ocsBody(status: 'failure', statusCode: 404, data: []);
      final response = decodeParticipantsResponse(
        request: _request(),
        statusCode: 404,
        body: body,
      );
      expect(response, isA<ParticipantsRoomMissing>());
    });

    test('classifies 429 and 503 as recoverable HTTP failures', () {
      final rateLimited =
          decodeParticipantsResponse(
                request: _request(),
                statusCode: 429,
                body: Uint8List(0),
              )
              as ParticipantsHttpFailure;
      expect(rateLimited.kind, ParticipantsHttpFailureKind.rateLimited);

      final unavailable =
          decodeParticipantsResponse(
                request: _request(),
                statusCode: 503,
                body: Uint8List(0),
              )
              as ParticipantsHttpFailure;
      expect(unavailable.kind, ParticipantsHttpFailureKind.serviceUnavailable);
    });

    test('rejects an unsupported HTTP status', () {
      expect(
        () => decodeParticipantsResponse(
          request: _request(),
          statusCode: 500,
          body: Uint8List(0),
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

    test('rejects malformed JSON', () {
      expect(
        () => decodeParticipantsResponse(
          request: _request(),
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode('not json')),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('participants request contract', () {
    test('builds the v4 participants URI with includeStatus', () {
      final request = _request();
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/participants?format=json&includeStatus=true',
      );
    });

    test('rejects a control-character user agent', () {
      expect(
        () => ParticipantsRequest(
          accountId: AccountId.parse('account-a'),
          server: ServerBase.parse('https://cloud.example.invalid'),
          roomToken: ConversationToken.parse(
            'rooma123',
            path: r'$.roomToken',
          ),
          userAgent: 'bad\nagent',
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}
