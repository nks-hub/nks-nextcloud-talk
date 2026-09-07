import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'permission_test_support.dart';

void main() {
  test(
    'room default and mention updates return a room bound to the request',
    () {
      for (final request in [
        defaultPermissionRequest(),
        mentionPermissionRequest(),
      ]) {
        final result =
            decodePermissionUpdateResponse(
                  request: request,
                  statusCode: 200,
                  body: permissionResponseBody(200, permissionRoom()),
                )
                as RoomPermissionsUpdated;
        expect(result.room.token, request.roomToken);
        expect(identical(result.request, request), isTrue);
        expect(result.statusCode, 200);
      }
    },
  );

  test(
    'attendee update returns exactly the requested participant without exposing identity in diagnostics',
    () {
      final request = attendeePermissionRequest();
      final result =
          decodePermissionUpdateResponse(
                request: request,
                statusCode: 200,
                body: permissionResponseBody(200, [permissionAttendee()]),
              )
              as AttendeePermissionsUpdated;
      expect(result.participant.attendeeId, 17);
      expect(result.participant.attendeePermissions, 129);
      expect(result.participant.permissions, 129);
      expect(result.toString(), isNot(contains('Person A')));
    },
  );

  test(
    'rejects wrong-room, wrong-attendee and multi-attendee success payloads',
    () {
      expect(
        () => decodePermissionUpdateResponse(
          request: defaultPermissionRequest(),
          statusCode: 200,
          body: permissionResponseBody(200, permissionRoom(token: 'otherroom')),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      for (final data in <Object?>[
        [],
        [permissionAttendee(id: 18)],
        [permissionAttendee(), permissionAttendee()],
        permissionRoom(),
      ]) {
        expect(
          () => decodePermissionUpdateResponse(
            request: attendeePermissionRequest(),
            statusCode: 200,
            body: permissionResponseBody(200, data),
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
    },
  );

  test(
    'preserves the server refusal and forced value without inventing success',
    () {
      final result =
          decodePermissionUpdateResponse(
                request: defaultPermissionRequest(),
                statusCode: 400,
                body: permissionResponseBody(400, {
                  'error': 'forced',
                  'forced': 128,
                }),
              )
              as PermissionUpdateFailure;
      expect(result.kind, PermissionUpdateFailureKind.rejected);
      expect(result.reason, 'forced');
      expect(result.forcedValue, 128);
      for (final value in <Object?>[null, -1, 512, '128']) {
        expect(
          () => decodePermissionUpdateResponse(
            request: defaultPermissionRequest(),
            statusCode: 400,
            body: permissionResponseBody(400, {
              'error': 'forced',
              'forced': value,
            }),
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
      expect(
        () => decodePermissionUpdateResponse(
          request: mentionPermissionRequest(),
          statusCode: 400,
          body: permissionResponseBody(400, {'error': 'forced', 'forced': 2}),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  for (final entry in {
    401: PermissionUpdateFailureKind.reauthenticationRequired,
    403: PermissionUpdateFailureKind.forbidden,
    404: PermissionUpdateFailureKind.notFound,
  }.entries) {
    test('classifies HTTP ${entry.key} with null or empty refusal data', () {
      for (final data in <Object?>[null, [], {}]) {
        final result =
            decodePermissionUpdateResponse(
                  request: attendeePermissionRequest(),
                  statusCode: entry.key,
                  body: permissionResponseBody(entry.key, data),
                )
                as PermissionUpdateFailure;
        expect(result.kind, entry.value);
      }
    });
  }

  test(
    'accepts the core OCS not-logged-in code only with an HTTP authentication refusal',
    () {
      final body = permissionResponseBody(997, []);
      final result =
          decodePermissionUpdateResponse(
                request: defaultPermissionRequest(),
                statusCode: 401,
                body: body,
              )
              as PermissionUpdateFailure;
      expect(result.kind, PermissionUpdateFailureKind.reauthenticationRequired);
      expect(
        () => decodePermissionUpdateResponse(
          request: defaultPermissionRequest(),
          statusCode: 200,
          body: body,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test(
    'does not decode rate-limit and service errors as successful room data',
    () {
      for (final status in [429, 503]) {
        final result =
            decodePermissionUpdateResponse(
                  request: defaultPermissionRequest(),
                  statusCode: status,
                  body: Uint8List.fromList(
                    utf8.encode('<html>Unavailable</html>'),
                  ),
                )
                as PermissionUpdateFailure;
        expect(result.statusCode, status);
        expect(
          result.kind,
          status == 429
              ? PermissionUpdateFailureKind.rateLimited
              : PermissionUpdateFailureKind.serviceUnavailable,
        );
      }
    },
  );

  test(
    'rejects inconsistent metadata, duplicate members and malformed UTF-8',
    () {
      final request = defaultPermissionRequest();
      for (final body in <Uint8List>[
        permissionResponseBody(403, permissionRoom()),
        permissionResponseBody(200, permissionRoom(), status: 'failure'),
        Uint8List.fromList([0xc3, 0x28]),
        Uint8List.fromList(
          utf8.encode(
            '{"ocs":{"meta":{"status":"ok","status":"failure","statuscode":200},"data":{}}}',
          ),
        ),
      ]) {
        expect(
          () => decodePermissionUpdateResponse(
            request: request,
            statusCode: 200,
            body: body,
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
      expect(
        () => decodePermissionUpdateResponse(
          request: request,
          statusCode: 403,
          body: permissionResponseBody(200, null),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test('bounds wire size and recursive JSON before parsing a success', () {
    expect(
      () => decodePermissionUpdateResponse(
        request: defaultPermissionRequest(),
        statusCode: 200,
        body: Uint8List(permissionUpdateMaximumBytes + 1),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    Object? deep = 0;
    for (var depth = 0; depth < 30; depth++) {
      deep = [deep];
    }
    expect(
      () => decodePermissionUpdateResponse(
        request: defaultPermissionRequest(),
        statusCode: 200,
        body: permissionResponseBody(200, {'nested': deep}),
      ),
      throwsA(
        isA<TalkProtocolException>().having(
          (e) => e.code,
          'code',
          TalkProtocolErrorCode.invalidPermissionResponse,
        ),
      ),
    );
  });
}
