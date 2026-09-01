part of 'chat_room_pane_test.dart';

void _registerChatRoomPanePollMenuTests() {
  testWidgets(
    'open attachment sheet replaces pending poll check when capability loads',
    (tester) async {
      final pollAvailability = await _openPendingPollMenu(tester);

      pollAvailability.complete(true);
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('create-poll')).evaluate().isNotEmpty,
      );

      expect(find.byKey(const Key('create-poll-checking')), findsNothing);
      expect(find.byKey(const Key('create-poll')), findsOneWidget);
      expect(find.text('Anketa'), findsOneWidget);
      expect(find.byKey(const Key('attach-source-contact')), findsOneWidget);
      expect(find.text('Kontakt'), findsOneWidget);
      expect(
        tester.widget<ListTile>(find.byKey(const Key('create-poll'))).enabled,
        isTrue,
      );
      expect(tester.takeException(), isNull);

      await _closePollMenu(tester);
    },
  );

  testWidgets(
    'open attachment sheet clears pending poll check after capability failure',
    (tester) async {
      final pollAvailability = await _openPendingPollMenu(tester);

      pollAvailability.completeError(
        StateError('Synthetic capability failure'),
        StackTrace.empty,
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('create-poll-checking')).evaluate().isEmpty,
      );

      expect(find.byKey(const Key('attachment-source-sheet')), findsOneWidget);
      expect(find.byKey(const Key('create-poll')), findsNothing);
      expect(find.byKey(const Key('share-current-location')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _closePollMenu(tester);
    },
  );
}

Future<Completer<bool>> _openPendingPollMenu(WidgetTester tester) async {
  final pollAvailability = Completer<bool>();
  await tester.pumpWidget(
    app(
      home: roomScreen(),
      locale: const Locale('cs'),
      overrides: [
        chatMessageActionsProfileProvider.overrideWith(
          (ref, key) async => RichChatCapabilityProfile.fromTalkFeatures(
            talkFeatures: const ['chat-v2', 'geo-location-sharing'],
            talkLocalFeatures: const <String>[],
            federated: false,
            moderator: false,
            participantPermissions: 0,
          ),
        ),
        pollAvailabilityProvider.overrideWith(
          (ref, key) => pollAvailability.future,
        ),
      ],
    ),
  );
  await _pumpUntil(
    tester,
    () =>
        tester
            .widget<IconButton>(find.byKey(const Key('pick-image-attachment')))
            .onPressed !=
        null,
  );

  await tester.tap(find.byKey(const Key('pick-image-attachment')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(const Key('attachment-source-sheet')), findsOneWidget);
  expect(find.byKey(const Key('create-poll-checking')), findsOneWidget);
  expect(find.byKey(const Key('create-poll')), findsNothing);
  return pollAvailability;
}

Future<void> _closePollMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}
