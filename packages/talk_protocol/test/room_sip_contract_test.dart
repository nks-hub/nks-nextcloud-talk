import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

AccountId _accountId() => AccountId.parse('account-a');
ServerBase _server() => ServerBase.parse('https://cloud.example.invalid');
ConversationToken _token() =>
    ConversationToken.parse('rooma123', path: r'$.roomToken');

SetRoomSipRequest _request(RoomSipState state) => SetRoomSipRequest(
  accountId: _accountId(),
  server: _server(),
  roomToken: _token(),
  state: state,
);

Uint8List _ocsBody({
  String status = 'ok',
  int statusCode = 200,
  Object? data = const <Object?>[],
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

Map<String, Object?> _room({required int sipEnabled, String? attendeePin}) {
  final root =
      jsonDecode(
            File(
              '../../contracts/conversation-list/fixtures/'
              'conversations-full.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>)
    ..['canEnableSIP'] = true
    ..['sipEnabled'] = sipEnabled
    ..['attendeePin'] = attendeePin;
}

Matcher _protocolFailure(TalkProtocolErrorCode code) => throwsA(
  isA<TalkProtocolException>().having((error) => error.code, 'code', code),
);

void main() {
  test('PUTs every SIP state to the v4 webinar SIP endpoint', () {
    for (final state in RoomSipState.values) {
      final request = _request(state);

      expect(request.httpMethod, 'PUT');
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/'
        'room/rooma123/webinar/sip?format=json',
      );
      expect(request.formBody, {'state': state.wireValue.toString()});
    }
  });

  test('preserves the bounded SIP state and redacted attendee PIN', () {
    final request = _request(RoomSipState.enabledWithoutPin);
    final response = decodeRoomAdministrationResponse(
      request: request,
      statusCode: 200,
      body: _ocsBody(data: _room(sipEnabled: 2, attendeePin: '1234567')),
    );

    final success = response as RoomAdministrationSuccess;
    expect(success.room?.sipEnabled, 2);
    expect(success.room?.attendeePin, '1234567');
    expect(success.room.toString(), isNot(contains('1234567')));
    expect(
      () => decodeRoomAdministrationResponse(
        request: request,
        statusCode: 200,
        body: _ocsBody(data: _room(sipEnabled: 3)),
      ),
      _protocolFailure(TalkProtocolErrorCode.invalidConversationResponse),
    );
  });

  test('classifies an unconfigured SIP bridge as a precondition failure', () {
    final response = decodeRoomAdministrationResponse(
      request: _request(RoomSipState.enabledWithPin),
      statusCode: 412,
      body: _ocsBody(
        status: 'failure',
        statusCode: 412,
        data: {'error': 'config'},
      ),
    );

    expect(response, isA<RoomAdministrationPreconditionFailed>());
  });
}
