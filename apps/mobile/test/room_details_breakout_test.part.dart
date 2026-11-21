part of 'room_details_screen_test.dart';

void _registerBreakoutTests() {
  testWidgets('a participant can reach and switch to the last breakout room', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'breakout-rooms-v1'});
    final parentOverrides = <String, Object?>{
      'participantType': 3,
      'breakoutRoomMode': 3,
      'breakoutRoomStatus': 1,
    };
    final parent = await _insertConversation(
      database,
      capableAccount,
      overrides: parentOverrides,
    );
    final children = <Map<String, Object?>>[
      for (var index = 1; index <= breakoutRoomsMaximum; index++)
        _breakoutRoomJson(index),
    ];
    String? switchedTarget;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/rooma123/breakout-rooms')) {
        return _ocsSuccess(children);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/breakout-rooms/rooma123/switch')) {
        switchedTarget = Uri.splitQueryString(request.body)['target'];
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..addAll(parentOverrides),
        );
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: parent,
      client: client,
      height: 800,
    );
    final actionFinder = find.byKey(const Key('room-details-breakout-switch'));
    await tester.ensureVisible(actionFinder);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(actionFinder);

    final listFinder = find.byKey(
      const Key('room-details-breakout-switch-list'),
    );
    await _pumpUntil(tester, () => listFinder.evaluate().isNotEmpty);
    final list = tester.widget<ListView>(listFinder);
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
    expect(
      find.byKey(const Key('room-details-breakout-switch-breakout20')),
      findsNothing,
      reason: 'off-screen breakout rooms must not be built up front',
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('room-details-breakout-switch-breakout20')),
      300,
      scrollable: find.descendant(
        of: listFinder,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(
      find.byKey(const Key('room-details-breakout-switch-breakout20')),
    );
    await _pumpUntil(
      tester,
      () =>
          switchedTarget == 'breakout20' &&
          find.text('You are now in Breakout 20.').evaluate().isNotEmpty,
    );

    expect(switchedTarget, 'breakout20');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Map<String, Object?> _breakoutRoomJson(int index) {
  final token = 'breakout${index.toString().padLeft(2, '0')}';
  final room = Map<String, Object?>.from(_conversationRoomJson())
    ..['token'] = token
    ..['name'] = 'Breakout $index'
    ..['displayName'] = 'Breakout $index'
    ..['objectType'] = 'room'
    ..['objectId'] = 'rooma123'
    ..['participantType'] = 3
    ..['breakoutRoomMode'] = 3
    ..['breakoutRoomStatus'] = 1;
  final lastMessage = room['lastMessage'];
  if (lastMessage is Map<String, Object?>) {
    room['lastMessage'] = Map<String, Object?>.from(lastMessage)
      ..['token'] = token;
  }
  return room;
}
