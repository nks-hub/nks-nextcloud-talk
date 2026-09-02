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
      _textByKey(tester, 'room-details-summary-type'),
      'Group conversation',
    );
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
    expect(_textByKey(tester, 'room-details-summary-type'), 'Public channel');
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
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: account,
      forConversation: publicConversation,
      client: client,
    );
    expect(_textByKey(tester, 'room-details-summary-type'), 'Public channel');

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
    expect(
      _textByKey(tester, 'room-details-summary-type'),
      'Group conversation',
    );
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

  testWidgets('SIP settings need both capability and server permission', (
    tester,
  ) async {
    final permitted = await _insertConversation(
      database,
      account,
      overrides: {'canEnableSIP': true},
    );
    await openDetails(
      tester,
      forAccount: account,
      forConversation: permitted,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-sip')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));

    final capable = await withCapabilities({'sip-support'});
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-sip')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: permitted,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-sip')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));

    final classified = await _insertConversation(
      database,
      account,
      overrides: {'canEnableSIP': true, 'attributes': 4},
    );
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: classified,
      client: participantsClient(const <Object?>[]),
    );
    expect(find.byKey(const Key('room-details-sip')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('SIP without PIN stays hidden without its own capability', (
    tester,
  ) async {
    final capable = await withCapabilities({'sip-support'});
    final permitted = await _insertConversation(
      database,
      account,
      overrides: {'canEnableSIP': true},
    );
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: permitted,
      client: participantsClient(const <Object?>[]),
    );

    await tester.tap(find.byKey(const Key('room-details-sip')));
    await tester.pump();
    expect(
      find.byKey(const Key('room-details-sip-enabledWithPin')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('room-details-sip-enabledWithoutPin')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('enabling SIP with PIN sends state 1 and uses the server room', (
    tester,
  ) async {
    final capable = await withCapabilities({'sip-support'});
    final permitted = await _insertConversation(
      database,
      account,
      overrides: {'canEnableSIP': true},
    );
    Map<String, String>? sent;
    var settingsRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/signaling/settings')) {
        settingsRequests++;
        return _signalingSettingsSuccess('Enabled SIP instructions');
      }
      if (request.method == 'PUT' &&
          request.url.path.endsWith('/webinar/sip')) {
        sent = request.bodyFields;
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['canEnableSIP'] = true
            ..['sipEnabled'] = 1
            ..['attendeePin'] = '1234567',
        );
      }
      return http.Response('', 404);
    });
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: permitted,
      client: client,
    );
    expect(_textByKey(tester, 'room-details-sip-subtitle'), 'Disabled');

    await tester.tap(find.byKey(const Key('room-details-sip')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-sip-enabledWithPin')));
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-sip-subtitle') ==
          'Enabled with a personal PIN',
    );
    await _pumpUntil(
      tester,
      () => find.text('Enabled SIP instructions').evaluate().isNotEmpty,
    );

    expect(sent, {'state': '1'});
    expect(settingsRequests, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('SIP no-PIN mode sends state 2 and uses the server room', (
    tester,
  ) async {
    final capable = await withCapabilities({
      'sip-support',
      'sip-support-nopin',
    });
    final permitted = await _insertConversation(
      database,
      account,
      overrides: {'canEnableSIP': true, 'sipEnabled': 1},
    );
    Map<String, String>? sent;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' &&
          request.url.path.endsWith('/webinar/sip')) {
        sent = request.bodyFields;
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['canEnableSIP'] = true
            ..['sipEnabled'] = 2,
        );
      }
      return http.Response('', 404);
    });
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: permitted,
      client: client,
    );

    await tester.tap(find.byKey(const Key('room-details-sip')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('room-details-sip-enabledWithoutPin')),
    );
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-sip-subtitle') ==
          'Enabled without a PIN',
    );

    expect(sent, {'state': '2'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('disabling SIP sends state 0 and uses the server room', (
    tester,
  ) async {
    final capable = await withCapabilities({'sip-support'});
    final permitted = await _insertConversation(
      database,
      account,
      overrides: {'canEnableSIP': true, 'sipEnabled': 1},
    );
    Map<String, String>? sent;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' &&
          request.url.path.endsWith('/webinar/sip')) {
        sent = request.bodyFields;
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['canEnableSIP'] = true
            ..['sipEnabled'] = 0,
        );
      }
      return http.Response('', 404);
    });
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: permitted,
      client: client,
    );

    await tester.tap(find.byKey(const Key('room-details-sip')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-sip-disabled')));
    await _pumpUntil(
      tester,
      () => _textByKey(tester, 'room-details-sip-subtitle') == 'Disabled',
    );

    expect(sent, {'state': '0'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('SIP refuses a success response without the authoritative room', (
    tester,
  ) async {
    final capable = await withCapabilities({'sip-support'});
    final permitted = await _insertConversation(
      database,
      account,
      overrides: {'canEnableSIP': true},
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'PUT' &&
          request.url.path.endsWith('/webinar/sip')) {
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });
    await openDetails(
      tester,
      forAccount: capable,
      forConversation: permitted,
      client: client,
    );

    await tester.tap(find.byKey(const Key('room-details-sip')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-sip-enabledWithPin')));
    await _pumpUntil(
      tester,
      () => find
          .text('The change could not be saved. Please try again.')
          .evaluate()
          .isNotEmpty,
    );

    expect(_textByKey(tester, 'room-details-sip-subtitle'), 'Disabled');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'an unconfigured SIP bridge keeps the old state and explains it',
    (tester) async {
      final capable = await withCapabilities({'sip-support'});
      final permitted = await _insertConversation(
        database,
        account,
        overrides: {'canEnableSIP': true},
      );
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/participants')) {
          return _ocsSuccess(const <Object?>[]);
        }
        if (request.method == 'PUT' &&
            request.url.path.endsWith('/webinar/sip')) {
          return _ocsFailure(412);
        }
        return http.Response('', 404);
      });
      await openDetails(
        tester,
        forAccount: capable,
        forConversation: permitted,
        client: client,
      );

      await tester.tap(find.byKey(const Key('room-details-sip')));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('room-details-sip-enabledWithPin')),
      );
      await _pumpUntil(
        tester,
        () => find
            .text('SIP dial-in is not configured on this server.')
            .evaluate()
            .isNotEmpty,
      );

      expect(_textByKey(tester, 'room-details-sip-subtitle'), 'Disabled');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

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
        final state = int.parse(request.bodyFields['state']!);
        if (state == 0) {
          return _ocsSuccess(const <Object?>[]);
        }
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['readOnly'] = state,
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
    expect(_textByKey(tester, 'room-details-summary-read-only'), 'No');

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
    expect(_textByKey(tester, 'room-details-summary-read-only'), 'Yes');

    await tester.tap(find.byKey(const Key('room-details-read-only-toggle')));
    await _pumpUntil(
      tester,
      () =>
          _textByKey(tester, 'room-details-read-only-subtitle') ==
              'Everyone can write' &&
          _textByKey(tester, 'room-details-summary-read-only') == 'No',
    );

    expect(sent, [
      {'state': '1'},
      {'state': '0'},
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the room password dialog fits at 200 % text', (tester) async {
    final publicConversation = await _insertConversation(
      database,
      account,
      overrides: {'type': 3},
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    // One of the thirteen dialogs that were given `scrollable: true` after the
    // share confirmation was measured overflowing. A dialog holding a text
    // field is the case Flutter itself recommends the flag for, so it is worth
    // one real screen rather than trust.
    await openDetails(
      tester,
      forAccount: account,
      forConversation: publicConversation,
      client: client,
      textScale: 2,
      height: 6000,
    );
    await tester.tap(find.byKey(const Key('room-details-password')));
    await tester.pump();

    final overflows = await overflowsWhile(() async {
      tester.view.physicalSize = const Size(360, 640);
      await tester.pump();
      await tester.pump();
    });

    expect(
      find.byKey(const Key('room-details-password-field')),
      findsOneWidget,
      reason: 'the field must survive the larger text on a small screen',
    );
    expect(overflows, isEmpty, reason: overflows.join(' | '));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
