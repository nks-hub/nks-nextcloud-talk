import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

/// Wire shapes for pin, reminder and scheduled messages that the synthetic
/// fixture set does not carry, taken from spreed `f2958bb`
/// `lib/Controller/ChatController.php` and the generated `openapi-full.json`.
void main() {
  group('empty no-payload responses', () {
    // Talk does not use one encoding for "no payload". Hiding a pin returns
    // `null`, while deleting a reminder or a scheduled message returns an
    // empty object, which OCS renders as an empty array only once PHP has an
    // empty list. All three must decode as success.
    for (final payload in <Object?>[null, <Object?>[], <String, Object?>{}]) {
      final label = payload == null
          ? 'null'
          : payload is List
          ? 'empty array'
          : 'empty object';

      test('hiding a pin accepts $label', () {
        final response = _decode(
          _hidePinnedRequest(),
          200,
          _envelope(200, payload),
        );
        expect(
          response.classification,
          RichChatResponseClassification.success,
        );
      });

      test('deleting a reminder accepts $label', () {
        final response = _decode(
          _deleteReminderRequest(),
          200,
          _envelope(200, payload),
        );
        expect(
          response.classification,
          RichChatResponseClassification.success,
        );
      });

      test('deleting a scheduled message accepts $label', () {
        final response = _decode(
          _deleteScheduledRequest(),
          200,
          _envelope(200, payload),
        );
        expect(
          response.classification,
          RichChatResponseClassification.success,
        );
      });
    }

    test('a non-empty payload is still rejected', () {
      expect(
        () => _decode(
          _deleteReminderRequest(),
          200,
          _envelope(200, <String, Object?>{'error': 'message'}),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('pin capability gate', () {
    test('a moderator on a server with pinned-messages may pin', () {
      final profile = _profile(moderator: true);
      expect(profile.pin, isTrue);
      expect(profile.hidePinned, isTrue);
    });

    // `#[RequireModeratorParticipant]` on the pin route, versus
    // `#[RequireParticipant]` on `pin/self`.
    test('an ordinary participant may hide a pin but not pin', () {
      final profile = _profile(moderator: false);
      expect(profile.pin, isFalse);
      expect(profile.hidePinned, isTrue);
      expect(
        () => RichChatRequest.pinMessage(
          accountId: _accountId,
          requestId: _requestId,
          server: _server,
          roomToken: _roomToken,
          profile: profile,
          messageId: 7,
          pinUntil: 0,
          now: 1_724_300_000,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('pinUntil 0 means indefinitely and a past timestamp is refused', () {
      final request = RichChatRequest.pinMessage(
        accountId: _accountId,
        requestId: _requestId,
        server: _server,
        roomToken: _roomToken,
        profile: _profile(moderator: true),
        messageId: 7,
        pinUntil: 0,
        now: 1_724_300_000,
      );
      expect(request.formBody?['pinUntil'], 0);
      expect(request.requestPath, endsWith('/chat/rooma123/7/pin'));
      expect(
        () => RichChatRequest.pinMessage(
          accountId: _accountId,
          requestId: _requestId,
          server: _server,
          roomToken: _roomToken,
          profile: _profile(moderator: true),
          messageId: 7,
          pinUntil: 1_724_299_999,
          now: 1_724_300_000,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('hiding a pin targets the pin/self route', () {
      expect(
        _hidePinnedRequest().requestPath,
        endsWith('/chat/rooma123/7/pin/self'),
      );
      expect(_hidePinnedRequest().method, RichChatHttpMethod.delete);
    });
  });

  group('scheduled message capability gate', () {
    // `scheduled-messages` is announced under `features-local` only, and the
    // route is not federation supported.
    test('a global feature entry never enables scheduling', () {
      final profile = RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: const <String>['chat-v2', 'scheduled-messages'],
        talkLocalFeatures: const <String>[],
        federated: false,
        moderator: false,
        participantPermissions: 254,
      );
      expect(profile.scheduled, isFalse);
    });

    test('a local feature entry enables scheduling', () {
      expect(_profile(moderator: false).scheduled, isTrue);
    });

    test('a federated conversation never schedules', () {
      final profile = RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: const <String>['chat-v2'],
        talkLocalFeatures: const <String>['scheduled-messages'],
        federated: true,
        moderator: true,
        participantPermissions: 254,
      );
      expect(profile.scheduled, isFalse);
    });

    test('create sends message, sendAt and silent', () {
      final request = RichChatRequest.createScheduled(
        accountId: _accountId,
        requestId: _requestId,
        server: _server,
        roomToken: _roomToken,
        profile: _profile(moderator: false),
        message: 'Later',
        sendAt: 1_724_400_000,
        silent: false,
        threadId: 0,
        threadTitle: '',
        now: 1_724_300_000,
      );
      expect(request.requestPath, endsWith('/chat/rooma123/schedule'));
      expect(request.method, RichChatHttpMethod.post);
      expect(request.formBody?['message'], 'Later');
      expect(request.formBody?['sendAt'], 1_724_400_000);
      expect(request.formBody?['silent'], false);
    });

    test('a sendAt in the past is refused before any request is built', () {
      expect(
        () => RichChatRequest.createScheduled(
          accountId: _accountId,
          requestId: _requestId,
          server: _server,
          roomToken: _roomToken,
          profile: _profile(moderator: false),
          message: 'Later',
          sendAt: 1_724_299_999,
          silent: false,
          threadId: 0,
          threadTitle: '',
          now: 1_724_300_000,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    // The schedule identifier is a Snowflake string, unlike the integer
    // message IDs used everywhere else in the chat API.
    test('a listed schedule keeps its string identifier', () {
      final response = _decode(
        _listScheduledRequest(),
        200,
        _envelope(200, <Object?>[_scheduledMessageJson('9007199254740993')]),
      );
      expect(response.scheduledMessages, hasLength(1));
      expect(
        response.scheduledMessages.single.scheduleId.value,
        '9007199254740993',
      );
      expect(response.scheduledMessages.single.sendAt, 1_724_400_000);
    });

    test('delete addresses the schedule by that identifier', () {
      expect(
        _deleteScheduledRequest().requestPath,
        endsWith('/chat/rooma123/schedule/9007199254740993'),
      );
    });
  });

  group('reminder wire shape', () {
    test('setting a reminder is a 201 carrying the reminder back', () {
      final request = RichChatRequest.setReminder(
        accountId: _accountId,
        requestId: _requestId,
        server: _server,
        roomToken: _roomToken,
        profile: _profile(moderator: false),
        messageId: 7,
        timestamp: 1_724_400_000,
      );
      expect(request.requestPath, endsWith('/chat/rooma123/7/reminder'));
      expect(request.formBody?['timestamp'], 1_724_400_000);
      final response = _decode(request, 201, _envelope(201, _reminderJson()));
      expect(
        response.classification,
        RichChatResponseClassification.success,
      );
      expect(response.reminder?.timestamp, 1_724_400_000);
      expect(response.reminder?.messageId, 7);
    });

    // "The user has no reminder for this message" is one of the documented
    // causes of a 404, so it must stay a deterministic answer the caller can
    // read as "none set" instead of an ambiguous transport result.
    test('a missing reminder is a deterministic 404', () {
      final response = _decode(
        _getReminderRequest(),
        404,
        _failureEnvelope(404),
      );
      expect(
        response.classification,
        RichChatResponseClassification.deterministicFailure,
      );
      expect(response.statusCode, 404);
    });

    test('a reminder bound to another message is refused', () {
      expect(
        () => _decode(
          _getReminderRequest(),
          200,
          _envelope(200, _reminderJson(messageId: 8)),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('reminders need the remind-me-later feature', () {
      final profile = RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: const <String>['chat-v2'],
        talkLocalFeatures: const <String>[],
        federated: false,
        moderator: true,
        participantPermissions: 254,
      );
      expect(profile.reminders, isFalse);
      expect(
        () => RichChatRequest.getReminder(
          accountId: _accountId,
          requestId: _requestId,
          server: _server,
          roomToken: _roomToken,
          profile: profile,
          messageId: 7,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });

  group('room pinned identifiers', () {
    test('a room exposes lastPinnedId and hiddenPinnedId', () {
      final room = ConversationRoom.fromJson(
        _roomJson(lastPinnedId: 7, hiddenPinnedId: 0),
      );
      expect(room.lastPinnedId, 7);
      expect(room.hiddenPinnedId, 0);
    });

    // `RoomService::setLastPinnedId` resets every attendee's hidden ID when a
    // new message is pinned, so equality is the only "hidden" state.
    test('a hidden pin reports both identifiers unchanged', () {
      final room = ConversationRoom.fromJson(
        _roomJson(lastPinnedId: 7, hiddenPinnedId: 7),
      );
      expect(room.lastPinnedId, room.hiddenPinnedId);
    });

    test('an unpinned room reports zero', () {
      final room = ConversationRoom.fromJson(_roomJson());
      expect(room.lastPinnedId, 0);
      expect(room.hiddenPinnedId, 0);
    });
  });
}

final _accountId = AccountId.parse('11111111-2222-3333-4444-555555555555');
final _requestId = ChatRequestId.parse(
  '66666666-7777-8888-9999-aaaaaaaaaaaa',
);
final _server = ServerBase.parse('https://cloud.example.invalid');
final _roomToken = ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidRichChatRequest,
);

RichChatCapabilityProfile _profile({required bool moderator}) =>
    RichChatCapabilityProfile.fromTalkFeatures(
      talkFeatures: const <String>[
        'chat-v2',
        'pinned-messages',
        'remind-me-later',
      ],
      talkLocalFeatures: const <String>['scheduled-messages'],
      federated: false,
      moderator: moderator,
      participantPermissions: 254,
    );

RichChatRequest _hidePinnedRequest() => RichChatRequest.hidePinnedMessage(
  accountId: _accountId,
  requestId: _requestId,
  server: _server,
  roomToken: _roomToken,
  profile: _profile(moderator: false),
  messageId: 7,
);

RichChatRequest _getReminderRequest() => RichChatRequest.getReminder(
  accountId: _accountId,
  requestId: _requestId,
  server: _server,
  roomToken: _roomToken,
  profile: _profile(moderator: false),
  messageId: 7,
);

RichChatRequest _deleteReminderRequest() => RichChatRequest.deleteReminder(
  accountId: _accountId,
  requestId: _requestId,
  server: _server,
  roomToken: _roomToken,
  profile: _profile(moderator: false),
  messageId: 7,
);

RichChatRequest _listScheduledRequest() => RichChatRequest.getScheduled(
  accountId: _accountId,
  requestId: _requestId,
  server: _server,
  roomToken: _roomToken,
  profile: _profile(moderator: false),
);

RichChatRequest _deleteScheduledRequest() => RichChatRequest.deleteScheduled(
  accountId: _accountId,
  requestId: _requestId,
  server: _server,
  roomToken: _roomToken,
  profile: _profile(moderator: false),
  scheduleId: RichChatScheduleId.parse('9007199254740993'),
);

RichChatResponse _decode(
  RichChatRequest request,
  int statusCode,
  Map<String, Object?> body,
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
      'message': 'Not found',
    },
    'data': <String, Object?>{'error': 'message'},
  },
};

Map<String, Object?> _reminderJson({int messageId = 7}) => <String, Object?>{
  'userId': 'fixture-user',
  'token': 'rooma123',
  'messageId': messageId,
  'timestamp': 1_724_400_000,
};

Map<String, Object?> _scheduledMessageJson(String id) => <String, Object?>{
  'id': id,
  'actorId': 'fixture-user',
  'actorType': 'users',
  'threadId': 0,
  'message': 'Later',
  'messageType': 'comment',
  'createdAt': 1_724_300_000,
  'sendAt': 1_724_400_000,
  'silent': false,
};

/// The conversation payload with the two pin identifiers the room carries.
/// Everything here mirrors the recorded conversation-list fixture; only the
/// pin identifiers vary per case.
Map<String, Object?> _roomJson({
  int lastPinnedId = 0,
  int hiddenPinnedId = 0,
}) {
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
  final room = jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
  room['lastPinnedId'] = lastPinnedId;
  room['hiddenPinnedId'] = hiddenPinnedId;
  return room;
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/rich-chat/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
