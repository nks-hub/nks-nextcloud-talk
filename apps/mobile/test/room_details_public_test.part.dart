part of 'room_details_screen_test.dart';

void _registerPublicPasswordTests() {
  testWidgets('reopening a room explains and retains its previous password', (
    tester,
  ) async {
    final room = Map<String, Object?>.from(_conversationRoomJson())
      ..['hasPassword'] = true;
    final cached = await _insertConversation(
      database,
      account,
      overrides: {'hasPassword': true},
    );
    final mutations = <http.Request>[];
    final client = _publicPasswordClient(room, mutations, force: false);
    await openDetails(
      tester,
      forAccount: account,
      forConversation: cached,
      client: client,
    );
    await tester.tap(find.byKey(const Key('room-details-guests-toggle')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-password-dialog'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.text(
        'The previous password is still stored. Leave empty to keep it, or enter a new password.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('room-details-password-save')));
    await _pumpUntil(
      tester,
      () => _textByKey(tester, 'room-details-summary-type') == 'Public channel',
    );
    expect(mutations.single.bodyFields, {'password': ''});
    expect(room['hasPassword'], isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  for (final force in [false, true]) {
    testWidgets(
      'public password form applies atomic protection, forced=$force',
      (tester) async {
        final room = Map<String, Object?>.from(_conversationRoomJson());
        final mutations = <http.Request>[];
        final client = _publicPasswordClient(room, mutations, force: force);
        await openDetails(
          tester,
          forAccount: account,
          forConversation: conversation,
          client: client,
        );
        await tester.tap(find.byKey(const Key('room-details-guests-toggle')));
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('room-details-password-dialog'))
              .evaluate()
              .isNotEmpty,
        );
        expect(mutations, isEmpty);
        if (force) {
          await tester.tap(find.byKey(const Key('room-details-password-save')));
          await tester.pump();
          expect(
            find.text('Enter a password for this public conversation.'),
            findsOneWidget,
          );
          expect(mutations, isEmpty);
          await tester.enterText(
            find.byKey(const Key('room-details-password-field')),
            '  room secret  ',
          );
        }
        await tester.tap(find.byKey(const Key('room-details-password-save')));
        await _pumpUntil(
          tester,
          () =>
              _textByKey(tester, 'room-details-summary-type') ==
              'Public channel',
        );
        expect(mutations.single.bodyFields, {
          'password': force ? '  room secret  ' : '',
        });
        expect(room['hasPassword'], force);
        expect(
          find.byKey(const Key('room-details-invite-link')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets('cancelling the initial public password form never publishes', (
    tester,
  ) async {
    final room = Map<String, Object?>.from(_conversationRoomJson());
    final mutations = <http.Request>[];
    final client = _publicPasswordClient(room, mutations, force: true);
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: client,
    );
    await tester.tap(find.byKey(const Key('room-details-guests-toggle')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-password-dialog'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('room-details-password-field')),
      'private',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(mutations, isEmpty);
    expect(room['type'], 2);
    expect(
      _textByKey(tester, 'room-details-summary-type'),
      'Group conversation',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'rejected password preserves the private room and displays safe hint',
    (tester) async {
      final room = Map<String, Object?>.from(_conversationRoomJson());
      final mutations = <http.Request>[];
      final client = _publicPasswordClient(
        room,
        mutations,
        force: true,
        reject: true,
      );
      await openDetails(
        tester,
        forAccount: account,
        forConversation: conversation,
        client: client,
      );
      await tester.tap(find.byKey(const Key('room-details-guests-toggle')));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('room-details-password-dialog'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('room-details-password-field')),
        'short',
      );
      await tester.tap(find.byKey(const Key('room-details-password-save')));
      await _pumpUntil(
        tester,
        () => find.text('Choose a longer password.').evaluate().isNotEmpty,
      );
      expect(mutations, hasLength(1));
      expect(room['type'], 2);
      expect(find.byKey(const Key('room-details-invite-link')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'guest moderator cannot offer the authenticated-only public toggle',
    (tester) async {
      final guestRoom = await _insertConversation(
        database,
        account,
        overrides: {'participantType': 6, 'type': 2},
      );
      final requests = <http.Request>[];
      await openDetails(
        tester,
        forAccount: account,
        forConversation: guestRoom,
        client: MockClient((request) async {
          requests.add(request);
          return _ocsSuccess(<Object?>[]);
        }),
      );
      final toggle = find.byKey(const Key('room-details-guests-toggle'));
      if (toggle.evaluate().isNotEmpty) {
        expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      }
      expect(requests.where((r) => r.url.path.endsWith('/public')), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'changing rooms while the password dialog is open cannot publish the old room',
    (tester) async {
      final room = Map<String, Object?>.from(_conversationRoomJson());
      final mutations = <http.Request>[];
      final client = _publicPasswordClient(room, mutations, force: true);
      await openDetails(
        tester,
        forAccount: account,
        forConversation: conversation,
        client: client,
      );
      await tester.tap(find.byKey(const Key('room-details-guests-toggle')));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('room-details-password-dialog'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('room-details-password-field')),
        'private',
      );
      final next = conversation.copyWith(
        token: 'otherroom',
        rawJson: jsonEncode({
          ...room,
          'token': 'otherroom',
          'displayName': 'Other room',
        }),
      );
      await tester.pumpWidget(
        app(
          home: RoomDetailsScreen(
            key: const ValueKey('other-room'),
            account: account,
            conversation: next,
          ),
          client: client,
        ),
      );
      await tester.pump();
      if (find
          .byKey(const Key('room-details-password-save'))
          .evaluate()
          .isNotEmpty) {
        await tester.tap(find.byKey(const Key('room-details-password-save')));
      }
      await tester.pump();
      expect(mutations, isEmpty);
      expect(room['type'], 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

MockClient _publicPasswordClient(
  Map<String, Object?> room,
  List<http.Request> mutations, {
  required bool force,
  bool reject = false,
}) => MockClient((request) async {
  if (request.url.path.endsWith('/participants')) {
    return _ocsSuccess(<Object?>[]);
  }
  if (request.url.path.endsWith('/capabilities')) {
    return http.Response(jsonEncode(creationCapabilities(force: force)), 200);
  }
  if (request.method == 'GET' && request.url.path.endsWith('/room')) {
    return _ocsSuccess([room]);
  }
  if (request.method == 'POST' && request.url.path.endsWith('/public')) {
    mutations.add(request);
    if (reject) {
      return http.Response(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'failure', 'statuscode': 400},
            'data': {'message': 'Choose a longer password.'},
          },
        }),
        400,
      );
    }
    room['type'] = 3;
    if (request.bodyFields['password']?.isNotEmpty ?? false) {
      room['hasPassword'] = true;
    }
    return _ocsSuccess(room);
  }
  return http.Response('', 404);
});
