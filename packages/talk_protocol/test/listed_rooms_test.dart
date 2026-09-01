import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');
  final account = AccountId.parse('account-a');

  ListedRoomsRequest request({String term = ''}) =>
      ListedRoomsRequest(accountId: account, server: server, searchTerm: term);

  ListedRoomsResponse decode(int statusCode, [String body = '']) =>
      decodeListedRoomsResponse(
        request: request(),
        statusCode: statusCode,
        body: Uint8List.fromList(utf8.encode(body)),
      );

  String payload(List<Map<String, Object?>> rooms) => jsonEncode({
    'ocs': {
      'meta': {'statuscode': 200},
      'data': rooms,
    },
  });

  test('asks the only endpoint that returns rooms the account is not in', () {
    expect(
      request().uri.toString(),
      'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/'
      'listed-room?format=json',
    );
    expect(request(term: 'open').uri.queryParameters['searchTerm'], 'open');
  });

  test('refuses a control character or an oversized search term', () {
    expect(
      () => request(term: 'bad\nterm'),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => request(term: 'a' * 257),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('reads only what a room nobody has joined can honestly carry', () {
    final response = decode(
      200,
      payload([
        {
          'token': 'open1234',
          'displayName': 'Open room',
          'description': 'Anyone may join',
          'lastActivity': 1756000000,
          'hasPassword': true,
        },
      ]),
    );

    expect(response.outcome, ListedRoomsOutcome.listed);
    final room = response.rooms.single;
    expect(room.token.value, 'open1234');
    expect(room.displayName, 'Open room');
    expect(room.description, 'Anyone may join');
    expect(room.hasPassword, isTrue);
    expect(
      room.lastActivity,
      DateTime.fromMillisecondsSinceEpoch(1756000000000, isUtc: true),
    );
  });

  test('a missing name, description or activity is absent, never invented', () {
    final room = decode(
      200,
      payload([
        {'token': 'open1234'},
      ]),
    ).rooms.single;

    expect(room.displayName, isEmpty);
    expect(room.description, isEmpty);
    expect(room.lastActivity, isNull);
    expect(room.hasPassword, isFalse);
  });

  test('classifies the answers that are not a listing', () {
    expect(decode(401).outcome, ListedRoomsOutcome.reauthenticationRequired);
    expect(decode(404).outcome, ListedRoomsOutcome.unavailable);
    expect(decode(403).outcome, ListedRoomsOutcome.unavailable);
    expect(decode(503).outcome, ListedRoomsOutcome.transientError);
    expect(() => decode(418), throwsA(isA<TalkProtocolException>()));
  });

  test('an OCS failure inside HTTP 200 is not an empty list', () {
    expect(
      () => decode(
        200,
        jsonEncode({
          'ocs': {
            'meta': {'statuscode': 403},
            'data': <Object?>[],
          },
        }),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test(
    'a malformed room fails the whole listing rather than being skipped',
    () {
      expect(
        () => decode(
          200,
          payload([
            {'token': 'open1234'},
            {'token': 'x'},
          ]),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test('a listing longer than the cap is refused', () {
    expect(
      () => decode(
        200,
        payload(
          List.generate(
            listedRoomsMaximumRooms + 1,
            (index) => {'token': 'open${index.toString().padLeft(4, '0')}'},
          ),
        ),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  group('join', () {
    JoinListedRoomRequest join({String password = ''}) => JoinListedRoomRequest(
      accountId: account,
      server: server,
      roomToken: ConversationToken.parse('open1234', path: r'$.token'),
      password: password,
    );

    JoinListedRoomResponse decodeJoin(int statusCode, [String body = '']) =>
        decodeJoinListedRoomResponse(
          request: join(),
          statusCode: statusCode,
          body: Uint8List.fromList(utf8.encode(body)),
        );

    test('posts to the participants endpoint of that one room', () {
      expect(
        join().uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v4/room/'
        'open1234/participants/active?format=json',
      );
      expect(join().httpMethod, 'POST');
      expect(utf8.decode(join().bodyBytes), isEmpty);
    });

    test('a password travels in the body and not in the URL', () {
      final request = join(password: 'open sesame');

      expect(utf8.decode(request.bodyBytes), 'password=open+sesame');
      expect(request.uri.toString(), isNot(contains('sesame')));
      expect(request.toString(), isNot(contains('sesame')));
    });

    test('only an OCS success counts as joined', () {
      expect(
        decodeJoin(
          200,
          jsonEncode({
            'ocs': {
              'meta': {'statuscode': 200},
              'data': <String, Object?>{},
            },
          }),
        ).outcome,
        JoinListedRoomOutcome.joined,
      );
      expect(
        decodeJoin(
          200,
          jsonEncode({
            'ocs': {
              'meta': {'statuscode': 403},
              'data': <String, Object?>{},
            },
          }),
        ).outcome,
        JoinListedRoomOutcome.unavailable,
      );
    });

    test('classifies the refusals a server can answer with', () {
      expect(decodeJoin(403).outcome, JoinListedRoomOutcome.passwordRequired);
      expect(decodeJoin(404).outcome, JoinListedRoomOutcome.unavailable);
      expect(
        decodeJoin(401).outcome,
        JoinListedRoomOutcome.reauthenticationRequired,
      );
      expect(decodeJoin(429).outcome, JoinListedRoomOutcome.transientError);
      expect(() => decodeJoin(418), throwsA(isA<TalkProtocolException>()));
    });
  });
}
