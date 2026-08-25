part of 'room_details_screen_test.dart';

void _registerAdministrationTests() {
  // -------------------------------------------------------------------------
  // Conversation administration
  // -------------------------------------------------------------------------

  testWidgets('a moderator opens a group conversation to guests', (
    tester,
  ) async {
    final publicJson = Map<String, Object?>.from(_conversationRoomJson())
      ..['type'] = 3;
    var posts = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/public')) {
        posts++;
        return _ocsSuccess(publicJson);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: client,
    );

    expect(find.byKey(const Key('room-details-invite-link')), findsNothing);
    expect(
      _textByKey(tester, 'room-details-guests-subtitle'),
      'Invited people only',
    );

    await tester.tap(find.byKey(const Key('room-details-guests-toggle')));
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-guests-subtitle') ==
          'Anyone with the link can join',
    );

    expect(posts, 1);
    // The guest link only makes sense once anyone can use it.
    expect(find.byKey(const Key('room-details-invite-link')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('closing a conversation to guests asks for confirmation first', (
    tester,
  ) async {
    final publicConversation = await _insertConversation(
      database,
      account,
      overrides: {'type': 3},
    );
    var deletes = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'DELETE' && request.url.path.endsWith('/public')) {
        deletes++;
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())..['type'] = 2,
        );
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: account,
      forConversation: publicConversation,
      client: client,
    );

    await tester.tap(find.byKey(const Key('room-details-guests-toggle')));
    await tester.pump();
    expect(
      find.byKey(const Key('room-details-guests-close-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(deletes, 0);

    await tester.tap(find.byKey(const Key('room-details-guests-toggle')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('room-details-guests-close-confirm')),
    );
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-guests-subtitle') ==
          'Invited people only',
    );

    expect(deletes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('sharing the guest link hands the call URL to the share sheet', (
    tester,
  ) async {
    final publicConversation = await _insertConversation(
      database,
      account,
      overrides: {'type': 3},
    );
    final sharer = _RecordingLinkSharer();

    await openDetails(
      tester,
      forAccount: account,
      forConversation: publicConversation,
      client: participantsClient(const <Object?>[]),
      sharer: sharer,
    );

    await tester.tap(find.byKey(const Key('room-details-invite-link')));
    await _pumpUntil(tester, () => sharer.shared.isNotEmpty);

    expect(
      sharer.shared.single.toString(),
      'https://cloud.example.invalid/index.php/call/rooma123',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a moderator sets a password on a public conversation', (
    tester,
  ) async {
    final publicConversation = await _insertConversation(
      database,
      account,
      overrides: {'type': 3},
    );
    String? sentPassword;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/password')) {
        sentPassword = request.bodyFields['password'];
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['type'] = 3
            ..['hasPassword'] = true,
        );
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: account,
      forConversation: publicConversation,
      client: client,
    );
    expect(_textByKey(tester, 'room-details-password-subtitle'), 'No password');
    expect(find.byKey(const Key('room-details-password-remove')), findsNothing);

    await tester.tap(find.byKey(const Key('room-details-password')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('room-details-password-field')),
      'fixture-secret',
    );
    await tester.tap(find.byKey(const Key('room-details-password-save')));
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-password-subtitle') ==
          'Guests need a password',
    );

    expect(sentPassword, 'fixture-secret');
    // Only a protected conversation can have its protection removed.
    expect(
      find.byKey(const Key('room-details-password-remove')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a refused password shows the policy explanation verbatim', (
    tester,
  ) async {
    final publicConversation = await _insertConversation(
      database,
      account,
      overrides: {'type': 3},
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/password')) {
        // UTF-8 through Response.bytes: the plain String constructor would
        // encode this as latin1 and mangle the accented characters.
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'failure', 'statuscode': 400},
                'data': {'message': 'Heslo musí mít alespoň 10 znaků.'},
              },
            }),
          ),
          400,
        );
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: account,
      forConversation: publicConversation,
      client: client,
    );

    await tester.tap(find.byKey(const Key('room-details-password')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('room-details-password-field')),
      'short',
    );
    await tester.tap(find.byKey(const Key('room-details-password-save')));
    await _pumpUntil(
      tester,
      () => find.text('Heslo musí mít alespoň 10 znaků.').evaluate().isNotEmpty,
    );

    expect(_textByKey(tester, 'room-details-password-subtitle'), 'No password');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('removing the password confirms and sends an empty value', (
    tester,
  ) async {
    final protectedConversation = await _insertConversation(
      database,
      account,
      overrides: {'type': 3, 'hasPassword': true},
    );
    final sent = <String?>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/password')) {
        sent.add(request.bodyFields['password']);
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: account,
      forConversation: protectedConversation,
      client: client,
    );
    expect(
      _textByKey(tester, 'room-details-password-subtitle'),
      'Guests need a password',
    );

    await tester.tap(find.byKey(const Key('room-details-password-remove')));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(sent, isEmpty);

    await tester.tap(find.byKey(const Key('room-details-password-remove')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('room-details-password-remove-confirm')),
    );
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-password-subtitle') == 'No password',
    );

    expect(sent, ['']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the lobby switch only appears with the webinary-lobby feature', (
    tester,
  ) async {
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-lobby-toggle')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));

    final capable = await withCapabilities({'webinary-lobby'});
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-lobby-toggle')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('turning the lobby on sends state 1 without a timer', (
    tester,
  ) async {
    final capable = await withCapabilities({'webinary-lobby'});
    Map<String, String>? sent;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' &&
          request.url.path.endsWith('/webinar/lobby')) {
        sent = request.bodyFields;
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['lobbyState'] = 1,
        );
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: conversation,
      client: client,
    );
    expect(
      _textByKey(tester, 'room-details-lobby-subtitle'),
      'Everyone can take part',
    );

    await tester.tap(find.byKey(const Key('room-details-lobby-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('room-details-lobby-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('room-details-lobby-confirm')));
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-lobby-subtitle') ==
          'Only moderators can take part',
    );

    expect(sent, {'state': '1'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('turning the lobby off sends state 0 without confirmation', (
    tester,
  ) async {
    final capable = await withCapabilities({'webinary-lobby'});
    final lobbied = await _insertConversation(
      database,
      account,
      overrides: {'lobbyState': 1, 'lobbyTimer': 1893456000},
    );
    Map<String, String>? sent;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' &&
          request.url.path.endsWith('/webinar/lobby')) {
        sent = request.bodyFields;
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: lobbied,
      client: client,
    );
    expect(
      _textByKey(tester, 'room-details-lobby-subtitle'),
      startsWith('Only moderators until '),
    );

    await tester.tap(find.byKey(const Key('room-details-lobby-toggle')));
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-lobby-subtitle') ==
          'Everyone can take part',
    );

    expect(sent, {'state': '0'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the read-only switch needs the read-only-rooms feature', (
    tester,
  ) async {
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(
      find.byKey(const Key('room-details-read-only-toggle')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));

    final capable = await withCapabilities({'read-only-rooms'});
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(
      find.byKey(const Key('room-details-read-only-toggle')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('locking a conversation confirms first and sends state 1', (
    tester,
  ) async {
    final capable = await withCapabilities({'read-only-rooms'});
    final sent = <Map<String, String>>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/read-only')) {
        sent.add(request.bodyFields);
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())..['readOnly'] = 1,
        );
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: conversation,
      client: client,
    );

    await tester.tap(find.byKey(const Key('room-details-read-only-toggle')));
    await tester.pump();
    expect(
      find.byKey(const Key('room-details-read-only-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(sent, isEmpty);

    await tester.tap(find.byKey(const Key('room-details-read-only-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-read-only-confirm')));
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-read-only-subtitle') ==
          'Nobody can write or call',
    );

    expect(sent, [
      {'state': '1'},
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
