part of 'room_details_screen_test.dart';

void _registerAvatarAndBanTests() {
  testWidgets('an emoji avatar posts to the v1 avatar endpoint', (
    tester,
  ) async {
    final capable = await withCapabilities({'avatar'});
    Uri? posted;
    Map<String, String>? sent;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/avatar/emoji')) {
        posted = request.url;
        sent = request.bodyFields;
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['isCustomAvatar'] = true,
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
    expect(find.byKey(const Key('room-details-avatar')), findsOneWidget);
    expect(find.byKey(const Key('room-details-avatar-remove')), findsNothing);

    await tester.tap(find.byKey(const Key('room-details-avatar')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('room-details-avatar-emoji-\u{1F680}')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-avatar-save')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-avatar-remove'))
          .evaluate()
          .isNotEmpty,
    );

    expect(
      posted?.path,
      '/ocs/v2.php/apps/spreed/api/v1/room/rooma123/avatar/emoji',
    );
    expect(sent, {'emoji': '\u{1F680}'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a chosen background colour rides along with the emoji', (
    tester,
  ) async {
    // The default is deliberately no colour at all, so the server can follow
    // the reader's bright or dark mode. Only an explicit pick sends `color`.
    final capable = await withCapabilities({'avatar'});
    Map<String, String>? sent;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/avatar/emoji')) {
        sent = request.bodyFields;
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['isCustomAvatar'] = true,
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
    await tester.tap(find.byKey(const Key('room-details-avatar')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('room-details-avatar-emoji-\u{1F680}')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('room-details-avatar-color-0082C9')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-avatar-save')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-avatar-remove'))
          .evaluate()
          .isNotEmpty,
    );

    expect(sent, {'emoji': '\u{1F680}', 'color': '0082C9'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a picked picture is uploaded as a multipart avatar', (
    tester,
  ) async {
    final capable = await withCapabilities({'avatar'});
    final picker = _StubImagePicker(_onePixelPng, 'holiday photo.png');
    String? contentType;
    List<int>? uploaded;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/avatar')) {
        contentType = request.headers['Content-Type'];
        uploaded = request.bodyBytes;
        return _ocsSuccess(
          Map<String, Object?>.from(_conversationRoomJson())
            ..['isCustomAvatar'] = true,
        );
      }
      return http.Response('', 404);
    });

    _growViewport(tester, height: 2600);
    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(
          account: capable,
          conversation: conversation,
          linkSharer: _RecordingLinkSharer(),
          imagePicker: picker,
        ),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-avatar')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-details-avatar')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-avatar-pick-image')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-avatar-remove'))
          .evaluate()
          .isNotEmpty,
    );

    expect(contentType, startsWith('multipart/form-data; boundary=nkstalk'));
    final body = utf8.decode(uploaded!, allowMalformed: true);
    expect(
      body,
      contains(
        'Content-Disposition: form-data; name="file"; '
        'filename="holiday photo.png"',
      ),
    );
    expect(body, contains('Content-Type: image/png'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a picture the server refuses shows its own explanation', (
    tester,
  ) async {
    final capable = await withCapabilities({'avatar'});
    final picker = _StubImagePicker(_onePixelPng, 'wide.png');
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/avatar')) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'failure', 'statuscode': 400},
                'data': {'message': 'Obrázek musí být čtvercový.'},
              },
            }),
          ),
          400,
        );
      }
      return http.Response('', 404);
    });

    _growViewport(tester, height: 2600);
    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(
          account: capable,
          conversation: conversation,
          linkSharer: _RecordingLinkSharer(),
          imagePicker: picker,
        ),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-avatar')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-details-avatar')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-avatar-pick-image')));
    await _pumpUntil(
      tester,
      () => find.text('Obrázek musí být čtvercový.').evaluate().isNotEmpty,
    );

    expect(find.byKey(const Key('room-details-avatar-remove')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a picture of a type the server rejects never leaves the app', (
    tester,
  ) async {
    final capable = await withCapabilities({'avatar'});
    // A GIF header: a real image, but not one of the two types Talk accepts.
    final picker = _StubImagePicker(
      Uint8List.fromList(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
      'animation.gif',
    );
    var uploads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/avatar')) {
        uploads++;
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    _growViewport(tester, height: 2600);
    await tester.pumpWidget(
      app(
        home: RoomDetailsScreen(
          account: capable,
          conversation: conversation,
          linkSharer: _RecordingLinkSharer(),
          imagePicker: picker,
        ),
        client: client,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-details-avatar')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-details-avatar')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('room-details-avatar-pick-image')));
    await _pumpUntil(
      tester,
      () => find
          .text('Only a square PNG or JPEG works as a conversation picture.')
          .evaluate()
          .isNotEmpty,
    );

    expect(uploads, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('removing a custom avatar deletes it and hides the action', (
    tester,
  ) async {
    final capable = await withCapabilities({'avatar'});
    final decorated = await _insertConversation(
      database,
      account,
      overrides: {'isCustomAvatar': true},
    );
    var deletes = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'DELETE' && request.url.path.endsWith('/avatar')) {
        deletes++;
        return _ocsSuccess(const <Object?>[]);
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: decorated,
      client: client,
    );
    expect(find.byKey(const Key('room-details-avatar-remove')), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-details-avatar-remove')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-avatar-remove'))
          .evaluate()
          .isEmpty,
    );

    expect(deletes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the ban action needs the ban-v1 feature', (tester) async {
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(_moderationParticipants()),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-participant-menu-3'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const Key('room-details-bans')), findsNothing);

    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('room-participant-3-remove')), findsOneWidget);
    expect(find.byKey(const Key('room-participant-3-ban')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('banning a participant posts to the ban API and reloads', (
    tester,
  ) async {
    final capable = await withCapabilities({'ban-v1'});
    var banned = false;
    var listRequests = 0;
    Uri? banUri;
    Map<String, String>? sent;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        listRequests++;
        return _ocsSuccess(
          banned
              ? _moderationParticipants().sublist(0, 2)
              : _moderationParticipants(),
        );
      }
      if (request.method == 'POST' && request.url.path.contains('/ban/')) {
        banUri = request.url;
        sent = request.bodyFields;
        banned = true;
        return _ocsSuccess(<String, Object?>{
          'id': 5,
          'moderatorActorType': 'users',
          'moderatorActorId': 'fixture-user',
          'moderatorDisplayName': 'Signed-in Moderator',
          'bannedActorType': 'users',
          'bannedActorId': 'synthetic-member',
          'bannedDisplayName': 'Synthetic Member',
          'bannedTime': 1724300100,
          'internalNote': 'Repeated spam',
        });
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: conversation,
      client: client,
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-participant-menu-3'))
          .evaluate()
          .isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('room-participant-3-ban')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('room-details-ban-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('room-details-ban-note-field')),
      'Repeated spam',
    );
    await tester.tap(find.byKey(const Key('room-details-ban-confirm')));
    await _pumpUntil(tester, () => banned && listRequests == 2);
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-participant-3')).evaluate().isEmpty,
    );

    expect(banUri?.path, '/ocs/v2.php/apps/spreed/api/v1/ban/rooma123');
    expect(sent, {
      'actorType': 'users',
      'actorId': 'synthetic-member',
      'internalNote': 'Repeated spam',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the ban list shows every ban and lifts one', (tester) async {
    final capable = await withCapabilities({'ban-v1'});
    var lifted = false;
    Uri? unbanUri;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'GET' && request.url.path.contains('/ban/')) {
        return _ocsSuccess(
          lifted
              ? const <Object?>[]
              : <Object?>[
                  <String, Object?>{
                    'id': 5,
                    'moderatorActorType': 'users',
                    'moderatorActorId': 'fixture-user',
                    'moderatorDisplayName': 'Signed-in Moderator',
                    'bannedActorType': 'users',
                    'bannedActorId': 'synthetic-member',
                    'bannedDisplayName': 'Synthetic Member',
                    'bannedTime': 1724300100,
                    'internalNote': 'Repeated spam',
                  },
                ],
        );
      }
      if (request.method == 'DELETE' && request.url.path.contains('/ban/')) {
        unbanUri = request.url;
        lifted = true;
        return _ocsSuccess();
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: conversation,
      client: client,
    );

    await tester.tap(find.byKey(const Key('room-details-bans')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-ban-5')).evaluate().isNotEmpty,
    );
    expect(find.text('Synthetic Member'), findsOneWidget);
    expect(find.text('Repeated spam'), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-ban-5-lift')));
    await _pumpUntil(
      tester,
      () => find.text('Nobody is banned.').evaluate().isNotEmpty,
    );

    expect(unbanUri?.path, '/ocs/v2.php/apps/spreed/api/v1/ban/rooma123/5');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a plain participant sees no administration action at all', (
    tester,
  ) async {
    final capable = await withCapabilities({
      'avatar',
      'read-only-rooms',
      'webinary-lobby',
      'ban-v1',
    });
    final memberConversation = await _insertConversation(
      database,
      account,
      overrides: {
        'type': 3,
        'participantType': 3,
        'canLeaveConversation': true,
        'hasPassword': true,
        'isCustomAvatar': true,
      },
    );

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: memberConversation,
      client: participantsClient(const <Object?>[]),
    );

    for (final key in const <String>[
      'room-details-avatar',
      'room-details-avatar-remove',
      'room-details-guests-toggle',
      'room-details-password',
      'room-details-password-remove',
      'room-details-lobby-toggle',
      'room-details-read-only-toggle',
      'room-details-bans',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    // The guest link is not a moderator action: any participant of a public
    // conversation may pass it on.
    expect(find.byKey(const Key('room-details-invite-link')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a one-to-one conversation offers no administration action', (
    tester,
  ) async {
    final capable = await withCapabilities({
      'avatar',
      'read-only-rooms',
      'webinary-lobby',
      'ban-v1',
    });
    final oneToOne = await _insertConversation(
      database,
      account,
      overrides: {'type': 1, 'isCustomAvatar': true},
    );

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: oneToOne,
      client: participantsClient(const <Object?>[]),
    );

    for (final key in const <String>[
      'room-details-avatar',
      'room-details-avatar-remove',
      'room-details-guests-toggle',
      'room-details-invite-link',
      'room-details-password',
      'room-details-lobby-toggle',
      'room-details-read-only-toggle',
      'room-details-bans',
      // Talk refuses a name or a description on a one-to-one room, so the
      // actions must not be offered there either.
      'room-details-rename',
      'room-details-description-edit',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
