part of 'room_details_screen_test.dart';

void _registerMeetingTests() {
  testWidgets(
    'maximum calendar list stays lazy and schedules the selected calendar',
    (tester) async {
      final capableAccount = await withCapabilities({'schedule-meeting'});
      String? meetingBody;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/participants')) {
          return _ocsSuccess();
        }
        if (request.method == 'PROPFIND' &&
            request.url.path.endsWith(
              '/remote.php/dav/calendars/fixture-user/',
            )) {
          return http.Response(_calendarListing(maximumCalendars), 207);
        }
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(talkFeatures: const ['schedule-meeting']),
            ),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/api/v4/room/rooma123/meeting')) {
          meetingBody = request.body;
          return http.Response(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
                'data': null,
              },
            }),
            200,
          );
        }
        return http.Response('', 404);
      });

      await openDetails(
        tester,
        forAccount: capableAccount,
        forConversation: conversation,
        client: client,
        textScale: 2,
      );
      final action = find.byKey(const Key('room-details-meeting'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('room-details-meeting-dialog'))
            .evaluate()
            .isNotEmpty,
      );

      expect(find.text('Calendar 001'), findsOneWidget);
      await tester.tap(find.byKey(const Key('room-details-meeting-calendar')));
      await tester.pumpAndSettle();
      final listFinder = find.byKey(
        const Key('room-details-meeting-calendar-list'),
      );
      final list = tester.widget<ListView>(listFinder);
      expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
      expect(
        find.byKey(
          const Key('room-details-meeting-calendar-option-calendar-064'),
        ),
        findsNothing,
        reason: 'off-screen calendars must not be built up front',
      );

      await tester.enterText(
        find.byKey(const Key('room-details-meeting-calendar-search')),
        'Calendar 064',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(
          const Key('room-details-meeting-calendar-option-calendar-064'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Calendar 064'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('room-details-meeting-title')),
        'Project review',
      );
      await tester.tap(find.byKey(const Key('room-details-meeting-confirm')));
      await _pumpUntil(
        tester,
        () =>
            meetingBody != null &&
            find.text('The meeting is in the calendar').evaluate().isNotEmpty,
      );

      final fields = Uri.splitQueryString(meetingBody!);
      expect(fields['calendarUri'], 'calendar-064');
      expect(fields['title'], 'Project review');
      expect(
        int.parse(fields['end']!),
        greaterThan(int.parse(fields['start']!)),
      );
      expect(find.text('The meeting is in the calendar'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

String _calendarListing(int count) {
  final xml = StringBuffer(
    '<?xml version="1.0"?>'
    '<d:multistatus xmlns:d="DAV:" '
    'xmlns:cal="urn:ietf:params:xml:ns:caldav">',
  );
  for (var index = 1; index <= count; index++) {
    final suffix = index.toString().padLeft(3, '0');
    xml.write(
      '<d:response>'
      '<d:href>/remote.php/dav/calendars/fixture-user/'
      'calendar-$suffix/</d:href>'
      '<d:propstat><d:prop>'
      '<d:displayname>Calendar $suffix</d:displayname>'
      '<cal:supported-calendar-component-set>'
      '<cal:comp name="VEVENT"/>'
      '</cal:supported-calendar-component-set>'
      '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
      '</d:response>',
    );
  }
  xml.write('</d:multistatus>');
  return xml.toString();
}
