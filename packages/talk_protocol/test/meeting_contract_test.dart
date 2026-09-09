import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 9, 12);
  final start = now.add(const Duration(days: 1));

  ScheduleMeetingRequest request({
    String calendarUri = 'personal',
    DateTime? at,
    DateTime? until,
    String? title = 'Sprint review',
    String? description,
    List<int> attendeeIds = const <int>[],
    CapabilitySnapshot? capabilities,
  }) => ScheduleMeetingRequest(
    accountId: AccountId.parse('account-1'),
    server: ServerBase.parse('https://cloud.example.com'),
    roomToken: ConversationToken.parse('rooma123', path: r'$.roomToken'),
    calendarUri: calendarUri,
    start: at ?? start,
    end: until,
    title: title,
    description: description,
    attendeeIds: attendeeIds,
    capabilities: capabilities ?? _capabilities(),
    now: now,
  );

  group('ScheduleMeetingRequest', () {
    test('sends seconds, the bare calendar name and nothing else', () {
      final scheduled = request(
        until: start.add(const Duration(hours: 1)),
        description: 'What we shipped',
      );

      expect(scheduled.httpMethod, 'POST');
      expect(scheduled.uri.path, endsWith('/room/rooma123/meeting'));
      expect(scheduled.formFields, <String, List<String>>{
        'calendarUri': <String>['personal'],
        'start': <String>['${start.millisecondsSinceEpoch ~/ 1000}'],
        'end': <String>[
          '${start.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}',
        ],
        'title': <String>['Sprint review'],
        'description': <String>['What we shipped'],
      });
    });

    test('a server without schedule-meeting is never asked', () {
      expect(
        () => request(
          capabilities: _capabilities(features: const <String>{'chat-v2'}),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => request(
          capabilities: _capabilities(context: CapabilityContext.anonymous),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test(
      'a date the server would refuse is refused before anyone is invited',
      () {
        // Measured: the server answers 400 {"error": "start"} and
        // 400 {"error": "end"} for exactly these.
        expect(
          () => request(at: now.subtract(const Duration(minutes: 1))),
          throwsA(isA<TalkProtocolException>()),
        );
        expect(() => request(at: now), throwsA(isA<TalkProtocolException>()));
        expect(
          () => request(until: start),
          throwsA(isA<TalkProtocolException>()),
        );
        expect(
          () => request(until: start.subtract(const Duration(hours: 1))),
          throwsA(isA<TalkProtocolException>()),
        );
        expect(
          () => request(until: start.add(const Duration(days: 2))),
          throwsA(isA<TalkProtocolException>()),
        );
      },
    );

    test('a full DAV address is not a calendar name', () {
      // The server takes `personal`, not the href the listing hands back.
      expect(
        () => request(calendarUri: '/remote.php/dav/calendars/user/personal/'),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('never renders the room or the title in its description', () {
      expect(request().toString(), isNot(contains('rooma123')));
      expect(request().toString(), isNot(contains('Sprint review')));
    });
  });

  group('decodeScheduleMeetingResponse', () {
    ScheduleMeetingResponse decode(int statusCode, [String body = '']) =>
        decodeScheduleMeetingResponse(
          statusCode: statusCode,
          body: Uint8List.fromList(utf8.encode(body)),
        );

    String refusal(String error) => jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{'status': 'failure', 'statuscode': 400},
        'data': <String, Object?>{'error': error},
      },
    });

    test('reads the server error vocabulary that was measured', () {
      expect(
        decode(400, refusal('calendar')).refusal,
        ScheduleMeetingRefusal.calendar,
      );
      expect(
        decode(400, refusal('email')).refusal,
        ScheduleMeetingRefusal.email,
      );
      expect(
        decode(400, refusal('start')).refusal,
        ScheduleMeetingRefusal.start,
      );
      expect(decode(400, refusal('end')).refusal, ScheduleMeetingRefusal.end);
      expect(
        decode(400, refusal('something-new')).refusal,
        ScheduleMeetingRefusal.unknown,
      );
      expect(decode(400).refusal, ScheduleMeetingRefusal.unknown);
    });

    test('a written meeting is a success and carries no refusal', () {
      final response = decode(200, '{"ocs":{"data":null}}');

      expect(response.isSuccess, isTrue);
      expect(response.refusal, isNull);
    });

    test('the 500 a read-only calendar produces is a server failure', () {
      // Measured: the generated birthday calendar answers 500 with `[]`.
      final response = decode(500, '[]');

      expect(response.outcome, ScheduleMeetingOutcome.serverFailure);
      expect(response.isSuccess, isFalse);
    });

    test('classifies the other answers the endpoint can give', () {
      expect(
        decode(401).outcome,
        ScheduleMeetingOutcome.reauthenticationRequired,
      );
      expect(decode(403).outcome, ScheduleMeetingOutcome.forbidden);
      expect(decode(404).outcome, ScheduleMeetingOutcome.roomMissing);
      expect(decode(429).outcome, ScheduleMeetingOutcome.rateLimited);
      expect(() => decode(302), throwsA(isA<TalkProtocolException>()));
    });
  });

  group('decodeCalendarListResponse', () {
    CalendarListResponse decode(int statusCode, String body) =>
        decodeCalendarListResponse(
          statusCode: statusCode,
          body: Uint8List.fromList(utf8.encode(body)),
        );

    test('keeps the calendars that take events and drops the machinery', () {
      final response = decode(207, _listing);

      expect(response.outcome, CalendarListOutcome.listed);
      expect(response.calendars.map((calendar) => calendar.uri), <String>[
        'personal',
        'contact_birthdays',
      ]);
      expect(response.calendars.first.displayName, 'Personal');
    });

    test('a property the server does not serve is not read as present', () {
      // The reference instance returns `current-user-privileges` inside a 404
      // propstat of its own; only the 200 block describes what exists.
      final response = decode(207, _listing);

      expect(response.calendars, hasLength(2));
    });

    test('classifies the answers a listing can fail with', () {
      expect(
        decode(401, '').outcome,
        CalendarListOutcome.reauthenticationRequired,
      );
      expect(decode(403, '').outcome, CalendarListOutcome.unavailable);
      expect(decode(503, '').outcome, CalendarListOutcome.transientError);
      expect(() => decode(200, ''), throwsA(isA<TalkProtocolException>()));
      expect(
        () => decode(207, 'not xml at all <'),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}

/// The shape the reference instance answers, including the empty scheduling
/// collections and the 404 propstat it puts unserved properties into.
const String _listing = '''
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/remote.php/dav/calendars/user/</d:href>
    <d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/calendars/user/personal/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Personal</d:displayname>
        <cal:supported-calendar-component-set>
          <cal:comp name="VEVENT"/>
        </cal:supported-calendar-component-set>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop><d:current-user-privileges/></d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/calendars/user/contact_birthdays/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Contact birthdays</d:displayname>
        <cal:supported-calendar-component-set>
          <cal:comp name="VEVENT"/>
        </cal:supported-calendar-component-set>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/calendars/user/inbox/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Inbox</d:displayname>
        <cal:supported-calendar-component-set>
          <cal:comp name="VEVENT"/>
        </cal:supported-calendar-component-set>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/calendars/user/tasks/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Tasks</d:displayname>
        <cal:supported-calendar-component-set>
          <cal:comp name="VTODO"/>
        </cal:supported-calendar-component-set>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

CapabilitySnapshot _capabilities({
  Set<String> features = const <String>{'schedule-meeting'},
  CapabilityContext context = CapabilityContext.authenticated,
}) => CapabilitySnapshot.fromJson(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'version': <String, Object?>{
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': <String, Object?>{
        'spreed': <String, Object?>{'features': features.toList()},
      },
    },
  },
}, context: context);
