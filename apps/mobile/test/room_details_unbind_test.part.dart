part of 'room_details_screen_test.dart';

void _registerUnbindTests() {
  testWidgets('offered only for a binding the server would accept', (
    tester,
  ) async {
    // Without the capability, even an event room does not show it.
    final eventConversation = await _insertConversation(
      database,
      account,
      overrides: {'objectType': 'event', 'objectId': 'probe-event'},
    );
    await openDetails(
      tester,
      forAccount: account,
      forConversation: eventConversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-unbind')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    final capable = await withCapabilities({'unbind-conversation'});
    for (final entry in const <String, bool>{
      'event': true,
      'instant_meeting': true,
      'phone_temporary': true,
      // Measured: everything below answers 400 object-type, so the row is not
      // shown at all rather than offering a refusal.
      'phone_persist': false,
      'note_to_self': false,
      '': false,
    }.entries) {
      final conversation = await _insertConversation(
        database,
        capable,
        overrides: {'objectType': entry.key, 'objectId': 'probe'},
      );
      await openDetails(
        tester,
        forAccount: capable,
        forConversation: conversation,
        client: participantsClient(const <Object?>[]),
      );
      expect(
        find.byKey(const Key('room-details-unbind')),
        entry.value ? findsOneWidget : findsNothing,
        reason: entry.key,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
