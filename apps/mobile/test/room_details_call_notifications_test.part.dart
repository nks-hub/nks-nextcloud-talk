part of 'room_details_screen_test.dart';

void _registerCallNotificationTests() {
  testWidgets('toggles this participant call notifications', (tester) async {
    final levels = <String>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/notify-calls')) {
        final level = request.bodyFields['level']!;
        levels.add(level);
        final room = _conversationRoomJson()
          ..['notificationCalls'] = int.parse(level);
        return _ocsSuccess(room);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: client,
    );

    final toggle = find.byKey(
      const Key('room-details-call-notifications-toggle'),
    );
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await _pumpUntil(
      tester,
      () =>
          levels.length == 1 &&
          tester.widget<SwitchListTile>(toggle).value == false,
    );
    expect(levels, ['0']);

    await tester.tap(toggle);
    await _pumpUntil(
      tester,
      () =>
          levels.length == 2 &&
          tester.widget<SwitchListTile>(toggle).value == true,
    );
    expect(levels, ['0', '1']);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
