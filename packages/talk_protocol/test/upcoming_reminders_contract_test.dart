import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

/// Wire contract of `GET v1/chat/upcoming-reminders`, the account-wide reminder
/// list behind the reminder inbox.
///
/// Every shape here was measured against Nextcloud 34.0.1 / Talk 24.0.2 on
/// 9 September 2026, including the `messageParameters: []` encoding and the
/// `200` that a delete answers with.
void main() {
  group('capability gate', () {
    test('remind-me-later alone does not open the account-wide list', () {
      final profile = RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: const <String>['chat-v2', 'remind-me-later'],
        talkLocalFeatures: const <String>[],
        federated: false,
        moderator: false,
        participantPermissions: 254,
      );
      expect(profile.reminders, isTrue);
      expect(profile.upcomingReminders, isFalse);
      expect(
        () => RichChatRequest.upcomingReminders(
          accountId: _accountId,
          requestId: _requestId,
          server: _server,
          profile: profile,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('upcoming-reminders alone does not open the per-message routes', () {
      final profile = RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: const <String>['chat-v2', 'upcoming-reminders'],
        talkLocalFeatures: const <String>[],
        federated: false,
        moderator: false,
        participantPermissions: 254,
      );
      expect(profile.upcomingReminders, isTrue);
      expect(profile.reminders, isFalse);
      expect(
        () => RichChatRequest.deleteReminder(
          accountId: _accountId,
          requestId: _requestId,
          server: _server,
          roomToken: _roomToken,
          profile: profile,
          messageId: 79988,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('request shape', () {
    test('the route carries no room token', () {
      final request = _listRequest();
      expect(request.requestPath, endsWith('/chat/upcoming-reminders'));
      expect(request.method, RichChatHttpMethod.get);
      expect(request.roomToken, isNull);
      expect(request.formBody, isNull);
      expect(request.queryParameters['format'], 'json');
    });

    test('reading the list is not a mutation', () {
      expect(RichChatOperation.getUpcomingReminders.isMutation, isFalse);
    });
  });

  group('response shape', () {
    test('an entry keeps its deadline, room, message and author', () {
      final response = _decode(
        _listRequest(),
        200,
        _envelope(200, <Object?>[_entryJson()]),
      );
      expect(response.classification, RichChatResponseClassification.success);
      expect(response.upcomingReminders, hasLength(1));
      final entry = response.upcomingReminders.single;
      expect(entry.reminderTimestamp, 1_789_041_873);
      expect(entry.roomToken.value, 'hqowhbbz');
      expect(entry.messageId, 79988);
      expect(entry.actorType, 'users');
      expect(entry.actorId, 'nctalk-test');
      expect(entry.actorDisplayName, 'NCloudTalk Test');
      expect(entry.message, 'UP-20 reminder inbox probe');
      expect(entry.preview, 'UP-20 reminder inbox probe');
    });

    test('nothing pending is an empty list, not a failure', () {
      final response = _decode(
        _listRequest(),
        200,
        _envelope(200, <Object?>[]),
      );
      expect(response.classification, RichChatResponseClassification.success);
      expect(response.upcomingReminders, isEmpty);
    });

    // The server answered with an empty JSON *list* here, which is what an
    // empty PHP array renders as. A decoder that requires a map rejects every
    // real answer.
    test('messageParameters as an empty list decodes as no parameters', () {
      final response = _decode(
        _listRequest(),
        200,
        _envelope(200, <Object?>[_entryJson()]),
      );
      expect(response.upcomingReminders.single.messageParameters, isEmpty);
    });

    test('messageParameters as an object expands the placeholder', () {
      final response = _decode(
        _listRequest(),
        200,
        _envelope(200, <Object?>[
          _entryJson(
            message: 'Shared {file} with you',
            messageParameters: <String, Object?>{
              'file': <String, Object?>{
                'type': 'file',
                'id': '4711',
                'name': 'plan.pdf',
              },
            },
          ),
        ]),
      );
      final entry = response.upcomingReminders.single;
      expect(entry.messageParameters.keys, <String>['file']);
      expect(entry.preview, 'Shared plan.pdf with you');
    });

    // Dropping the token would leave a row claiming to remind of a message
    // whose text is not the message.
    test('an unknown placeholder is left in place', () {
      final response = _decode(
        _listRequest(),
        200,
        _envelope(200, <Object?>[_entryJson(message: 'See {file} now')]),
      );
      expect(response.upcomingReminders.single.preview, 'See {file} now');
    });

    test('a missing deadline is refused', () {
      final entry = _entryJson()..remove('reminderTimestamp');
      expect(
        () => _decode(_listRequest(), 200, _envelope(200, <Object?>[entry])),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('an entry without a room token is refused', () {
      final entry = _entryJson()..['roomToken'] = '';
      expect(
        () => _decode(_listRequest(), 200, _envelope(200, <Object?>[entry])),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    // A reminder is held per user, room and message, so one account cannot
    // hold two for the same message.
    test('the same message twice in one answer is refused', () {
      expect(
        () => _decode(
          _listRequest(),
          200,
          _envelope(200, <Object?>[_entryJson(), _entryJson()]),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('two rooms in one answer are both kept', () {
      final response = _decode(
        _listRequest(),
        200,
        _envelope(200, <Object?>[
          _entryJson(),
          _entryJson(roomToken: 'thy64xrj', messageId: 79989),
        ]),
      );
      expect(response.upcomingReminders, hasLength(2));
    });

    test('an object where a list belongs is refused', () {
      expect(
        () => _decode(
          _listRequest(),
          200,
          _envelope(200, <String, Object?>{'0': _entryJson()}),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('401 stays a reauthentication answer, not an empty list', () {
      final response = _decode(_listRequest(), 401, _failureEnvelope(401));
      expect(
        response.classification,
        RichChatResponseClassification.reauthenticationRequired,
      );
      expect(response.upcomingReminders, isEmpty);
    });

    test('a server error is never ambiguous for a read', () {
      final response = _decode(_listRequest(), 503, _failureEnvelope(503));
      expect(
        response.classification,
        RichChatResponseClassification.serverError,
      );
    });
  });

  group('delete answer', () {
    // Measured live: `200` with `"data": []`, and deleting a reminder that is
    // already gone answers the same way.
    test('deleting a reminder is a 200 with an empty list', () {
      final response = _decode(
        _deleteRequest(),
        200,
        _envelope(200, <Object?>[]),
      );
      expect(response.classification, RichChatResponseClassification.success);
    });
  });
}

final _accountId = AccountId.parse('11111111-2222-3333-4444-555555555555');
final _requestId = ChatRequestId.parse('66666666-7777-8888-9999-aaaaaaaaaaaa');
final _server = ServerBase.parse('https://cloud.example.invalid');
final _roomToken = ConversationToken.parse(
  'hqowhbbz',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidRichChatRequest,
);

RichChatCapabilityProfile _profile() =>
    RichChatCapabilityProfile.fromTalkFeatures(
      talkFeatures: const <String>[
        'chat-v2',
        'remind-me-later',
        'upcoming-reminders',
      ],
      talkLocalFeatures: const <String>[],
      federated: false,
      moderator: false,
      participantPermissions: 254,
    );

RichChatRequest _listRequest() => RichChatRequest.upcomingReminders(
  accountId: _accountId,
  requestId: _requestId,
  server: _server,
  profile: _profile(),
);

RichChatRequest _deleteRequest() => RichChatRequest.deleteReminder(
  accountId: _accountId,
  requestId: _requestId,
  server: _server,
  roomToken: _roomToken,
  profile: _profile(),
  messageId: 79988,
);

/// The exact entry the reference server answered with on 9 September 2026.
Map<String, Object?> _entryJson({
  String roomToken = 'hqowhbbz',
  int messageId = 79988,
  String message = 'UP-20 reminder inbox probe',
  Object? messageParameters = const <Object?>[],
}) => <String, Object?>{
  'reminderTimestamp': 1_789_041_873,
  'roomToken': roomToken,
  'messageId': messageId,
  'actorType': 'users',
  'actorId': 'nctalk-test',
  'actorDisplayName': 'NCloudTalk Test',
  'message': message,
  'messageParameters': messageParameters,
};

RichChatResponse _decode(
  RichChatRequest request,
  int statusCode,
  Object? body,
) => decodeRichChatResponse(
  request: request,
  statusCode: statusCode,
  body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
);

Map<String, Object?> _envelope(int statusCode, Object? data) =>
    <String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': statusCode,
          'message': 'OK',
        },
        'data': data,
      },
    };

Map<String, Object?> _failureEnvelope(int statusCode) => <String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'failure',
      'statuscode': statusCode,
      'message': 'Error',
    },
    'data': <Object?>[],
  },
};
