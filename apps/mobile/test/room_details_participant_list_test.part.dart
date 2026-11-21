part of 'room_details_screen_test.dart';

void _registerParticipantListTests() {
  testWidgets(
    'large participant list builds lazily and moderates the last row',
    (tester) async {
      var promoted = false;
      var listRequests = 0;
      List<Map<String, Object?>> participants() => [
        for (var id = 1; id <= 80; id++)
          _participantJson(
            attendeeId: id,
            actorId: 'synthetic-$id',
            displayName: 'Participant $id',
            participantType: id == 80 && promoted ? 2 : 3,
          ),
      ];
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/participants')) {
          listRequests++;
          return _ocsSuccess(participants());
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/moderators')) {
          expect(request.url.queryParameters['attendeeId'], '80');
          promoted = true;
          return _ocsSuccess();
        }
        return http.Response('', 404);
      });

      await openDetails(
        tester,
        forAccount: account,
        forConversation: conversation,
        client: client,
      );
      final listFinder = find.byKey(const Key('room-details-participant-list'));
      await _pumpUntil(tester, () => listFinder.evaluate().isNotEmpty);

      final list = tester.widget<ListView>(listFinder);
      expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
      expect(
        find.byKey(const Key('room-participant-80')),
        findsNothing,
        reason: 'off-screen participants must not be built up front',
      );

      await _scrollToParticipant(tester, listFinder, 80);
      await tester.tap(find.byKey(const Key('room-participant-menu-80')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('room-participant-80-promote')));
      await _pumpUntil(tester, () => promoted && listRequests == 2);
      await _pumpUntil(
        tester,
        () =>
            listFinder.evaluate().isNotEmpty &&
            find.byKey(const Key('room-participant-1')).evaluate().isNotEmpty,
      );

      await _scrollToParticipant(tester, listFinder, 80);
      await tester.tap(find.byKey(const Key('room-participant-menu-80')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('room-participant-80-demote')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('room-participant-80-promote')),
        findsNothing,
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _scrollToParticipant(
  WidgetTester tester,
  Finder listFinder,
  int attendeeId,
) async {
  await tester.scrollUntilVisible(
    find.byKey(Key('room-participant-$attendeeId')),
    600,
    scrollable: find.descendant(
      of: listFinder,
      matching: find.byType(Scrollable),
    ),
  );
}
