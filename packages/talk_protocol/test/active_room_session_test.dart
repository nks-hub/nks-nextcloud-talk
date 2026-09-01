import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('active room request and response bind the refreshed session', () {
    final request = ActiveRoomSessionRequest(
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
      roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    );
    expect(request.uri.path, endsWith('/room/rooma123/participants/active'));
    expect(request.uri.queryParameters, {'format': 'json'});

    final fixture =
        jsonDecode(
              File(
                '../../contracts/conversation-list/fixtures/'
                'conversations-full.response.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final ocs = fixture['ocs']! as Map<String, Object?>;
    final room = Map<String, Object?>.from(
      (ocs['data']! as List<Object?>).first! as Map<String, Object?>,
    )..['sessionId'] = 'active-session-a';
    final response = decodeActiveRoomSessionResponse(
      statusCode: 200,
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': room,
            },
          }),
        ),
      ),
    );

    expect(response, isA<ActiveRoomSessionSuccess>());
    expect(
      (response as ActiveRoomSessionSuccess).room.sessionId.value,
      'active-session-a',
    );
  });

  test('active room status mapping stays fail closed', () {
    final empty = Uint8List(0);
    expect(
      decodeActiveRoomSessionResponse(statusCode: 401, body: empty),
      isA<ActiveRoomSessionReauthenticationRequired>(),
    );
    expect(
      decodeActiveRoomSessionResponse(statusCode: 403, body: empty),
      isA<ActiveRoomSessionForbidden>(),
    );
    expect(
      decodeActiveRoomSessionResponse(statusCode: 404, body: empty),
      isA<ActiveRoomSessionMissing>(),
    );
    expect(
      decodeActiveRoomSessionResponse(statusCode: 409, body: empty),
      isA<ActiveRoomSessionConflict>(),
    );
    expect(
      decodeActiveRoomSessionResponse(statusCode: 503, body: empty),
      isA<ActiveRoomSessionHttpFailure>(),
    );
  });
}
