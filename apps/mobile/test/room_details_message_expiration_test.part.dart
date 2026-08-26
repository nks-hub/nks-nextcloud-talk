part of 'room_details_screen_test.dart';

void _registerMessageExpirationTests() {
  testWidgets('hides expiration without capability or moderator role', (
    tester,
  ) async {
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(
      find.byKey(const Key('room-details-message-expiration')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());

    final capableAccount = await withCapabilities({'message-expiration'});
    final participantConversation = await _insertConversation(
      database,
      capableAccount,
      overrides: {'participantType': 3},
    );
    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: participantConversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(
      find.byKey(const Key('room-details-message-expiration')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows current expiration and applies an upstream preset', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'message-expiration'});
    final customConversation = await _insertConversation(
      database,
      capableAccount,
      overrides: {'messageExpiration': 777},
    );
    final postedSeconds = <String>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _messageExpirationCapabilitiesResponse();
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/message-expiration')) {
        postedSeconds.add(request.bodyFields['seconds']!);
        final room = _conversationRoomJson()
          ..['messageExpiration'] = int.parse(postedSeconds.single);
        return _ocsSuccess(room);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: customConversation,
      client: client,
    );

    final tile = find.byKey(const Key('room-details-message-expiration'));
    expect(tile, findsOneWidget);
    expect(
      _textByKey(tester, 'room-details-message-expiration-subtitle'),
      'Custom (777 seconds)',
    );

    await tester.tap(tile);
    await tester.pump();
    expect(
      find.byKey(const Key('room-details-message-expiration-dialog')),
      findsOneWidget,
    );
    expect(find.text('1 hour'), findsOneWidget);
    expect(find.text('8 hours'), findsOneWidget);
    expect(find.text('1 day'), findsOneWidget);
    expect(find.text('1 week'), findsOneWidget);
    expect(find.text('4 weeks'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('room-details-message-expiration-604800')),
    );
    await _pumpUntil(
      tester,
      () =>
          postedSeconds.length == 1 &&
          _textByKey(tester, 'room-details-message-expiration-subtitle') ==
              '1 week',
    );
    expect(postedSeconds, ['604800']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

http.Response _messageExpirationCapabilitiesResponse() {
  final root =
      _readFixtureJson(
            'client-bootstrap/fixtures/capabilities-authenticated.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  spreed['features'] = <Object?>['message-expiration'];
  return http.Response(jsonEncode(root), 200);
}
