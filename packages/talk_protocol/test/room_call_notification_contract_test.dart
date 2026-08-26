import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('UpdateCallNotificationLevelRequest', () {
    test('encodes the participant call notification endpoint', () {
      final enabled = _request(RoomCallNotificationLevel.on);
      final disabled = _request(RoomCallNotificationLevel.off);

      expect(
        enabled.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'rooma123/notify-calls?format=json',
      );
      expect(enabled.formBody, {'level': '1'});
      expect(disabled.formBody, {'level': '0'});
      expect(enabled.headers['OCS-APIRequest'], 'true');
    });
  });

  group('decodeUpdateCallNotificationLevelResponse', () {
    test('returns the authoritative room after success', () {
      final room = _roomJson()..['notificationCalls'] = 0;

      final response = decodeUpdateCallNotificationLevelResponse(
        request: _request(RoomCallNotificationLevel.off),
        statusCode: 200,
        body: _ocsBody(status: 'ok', statusCode: 200, data: room),
      );

      expect(response, isA<UpdateCallNotificationLevelSuccess>());
      expect(
        (response as UpdateCallNotificationLevelSuccess).room.notificationCalls,
        0,
      );
    });

    test('classifies invalid level, authentication and missing room', () {
      final request = _request(RoomCallNotificationLevel.on);
      expect(
        decodeUpdateCallNotificationLevelResponse(
          request: request,
          statusCode: 400,
          body: _ocsBody(
            status: 'failure',
            statusCode: 400,
            data: {'error': 'level'},
          ),
        ),
        isA<UpdateCallNotificationLevelRejected>(),
      );
      expect(
        decodeUpdateCallNotificationLevelResponse(
          request: request,
          statusCode: 401,
          body: _ocsBody(status: 'failure', statusCode: 401),
        ),
        isA<UpdateCallNotificationLevelReauthenticationRequired>(),
      );
      expect(
        decodeUpdateCallNotificationLevelResponse(
          request: request,
          statusCode: 404,
          body: _ocsBody(status: 'failure', statusCode: 404),
        ),
        isA<UpdateCallNotificationLevelRoomMissing>(),
      );
    });

    test('keeps retryable failures typed', () {
      final request = _request(RoomCallNotificationLevel.on);
      for (final statusCode in [429, 503]) {
        final response = decodeUpdateCallNotificationLevelResponse(
          request: request,
          statusCode: statusCode,
          body: Uint8List(0),
        );
        expect(response, isA<UpdateCallNotificationLevelHttpFailure>());
        expect(response.statusCode, statusCode);
      }
    });
  });
}

UpdateCallNotificationLevelRequest _request(RoomCallNotificationLevel level) {
  return UpdateCallNotificationLevelRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    level: level,
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
