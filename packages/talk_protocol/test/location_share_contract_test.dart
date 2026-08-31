import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('builds canonical bounded location share form', () {
    final request = _request(latitude: -0.0, longitude: 14.42076);
    expect(request.uri.path, endsWith('/chat/rooma123/share'));
    expect(request.objectId, 'geo:0.0,14.42076');
    expect(request.formBody['objectType'], 'geo-location');
    expect(request.formBody['threadId'], 42);
    final metadata =
        jsonDecode(request.formBody['metaData']! as String)
            as Map<String, Object?>;
    expect(metadata['latitude'], '0.0');
    expect(metadata['name'], 'Shared location');
  });

  test('rejects capability, coordinate, name and thread violations', () {
    expect(
      () => _request(available: false),
      throwsA(isA<TalkProtocolException>()),
    );
    for (final latitude in <double>[double.nan, -91, 91]) {
      expect(
        () => _request(latitude: latitude),
        throwsA(isA<TalkProtocolException>()),
      );
    }
    expect(() => _request(name: ' '), throwsA(isA<TalkProtocolException>()));
    expect(() => _request(threadId: 0), throwsA(isA<TalkProtocolException>()));
    expect(
      () => _request(userAgent: 'bad\nagent'),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('decodes exact confirmed room and named thread', () {
    final request = _request();
    final response = decodeLocationShareResponse(
      request: request,
      statusCode: 201,
      body: _body(_message()),
    );
    expect(response.classification, LocationShareClassification.confirmed);
    expect(response.message?.messageId, 500);
    expect(response.message?.threadId, 42);

    final rootRequest = _request(threadId: null);
    final rootMessage = _message()..['threadId'] = 500;
    final rootResponse = decodeLocationShareResponse(
      request: rootRequest,
      statusCode: 201,
      body: _body(rootMessage),
    );
    expect(rootResponse.message?.threadId, 500);
  });

  test('rejects a response for another request or location', () {
    final request = _request();
    final wrongReference = _message()..['referenceId'] = 'another-request';
    final wrongLocation = _message();
    final parameters =
        wrongLocation['messageParameters']! as Map<String, Object?>;
    final object = parameters['object']! as Map<String, Object?>;
    object['latitude'] = '49.0';
    final wrongName = _message();
    final wrongNameParameters =
        wrongName['messageParameters']! as Map<String, Object?>;
    final wrongNameObject =
        wrongNameParameters['object']! as Map<String, Object?>;
    wrongNameObject['name'] = 'Another place';

    for (final message in <Map<String, Object?>>[
      wrongReference,
      wrongLocation,
      wrongName,
    ]) {
      expect(
        () => decodeLocationShareResponse(
          request: request,
          statusCode: 201,
          body: _body(message),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    }
    expect(
      () => decodeLocationShareResponse(
        request: _request(threadId: null),
        statusCode: 201,
        body: _body(_message()..['threadId'] = 499),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('classifies deterministic errors without parsing a body', () {
    final request = _request();
    for (final entry in <(int, LocationShareClassification)>[
      (400, LocationShareClassification.invalidInput),
      (401, LocationShareClassification.reauthenticationRequired),
      (403, LocationShareClassification.permissionDenied),
      (404, LocationShareClassification.notFound),
      (429, LocationShareClassification.rateLimited),
      (503, LocationShareClassification.serviceUnavailable),
    ]) {
      expect(
        decodeLocationShareResponse(
          request: request,
          statusCode: entry.$1,
          body: Uint8List(0),
        ).classification,
        entry.$2,
      );
    }
  });
}

LocationShareRequest _request({
  double latitude = 50.0875,
  double longitude = 14.42076,
  String name = 'Shared location',
  bool available = true,
  int? threadId = 42,
  String userAgent = chatContractUserAgent,
}) => LocationShareRequest(
  accountId: AccountId.parse('account-a'),
  requestId: ChatRequestId.parse('location-reference'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
  latitude: latitude,
  longitude: longitude,
  name: name,
  locationSharingAvailable: available,
  threadId: threadId,
  userAgent: userAgent,
);

Uint8List _body(Object? data) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'ocs': {
        'meta': {'status': 'ok', 'statuscode': 201, 'message': 'OK'},
        'data': data,
      },
    }),
  ),
);

Map<String, Object?> _message() => {
  'id': 500,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'user-a',
  'actorDisplayName': 'User A',
  'timestamp': 1787443000,
  'systemMessage': 'object_shared',
  'messageType': 'system',
  'isReplyable': true,
  'referenceId': 'location-reference',
  'message': '{object}',
  'messageParameters': {
    'object': {
      'type': 'geo-location',
      'id': 'geo:50.0875,14.42076',
      'name': 'Shared location',
      'latitude': '50.0875',
      'longitude': '14.42076',
    },
  },
  'markdown': false,
  'reactions': <String, Object?>{},
  'threadId': 42,
};
