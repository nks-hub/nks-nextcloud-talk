part of 'room_details_screen_test.dart';

/// The default picker: the moderator opened the dialog and picked nothing.
Future<XFile?> _noCsvSelected(XTypeGroup typeGroup) async => null;

const String _invitationCsv =
    'email,name\n'
    'up08.alpha@example.org,Alpha Tester\n'
    'up08.beta@example.org,Beta Tester\n';

/// Stands in for the system file picker, which no widget test can reach.
PickInvitationCsv _csvPicker(String contents, {String name = 'people.csv'}) {
  return (typeGroup) async =>
      XFile.fromData(Uint8List.fromList(utf8.encode(contents)), name: name);
}

void _registerEmailInvitationTests() {
  testWidgets('hides the CSV import without capability or moderator role', (
    tester,
  ) async {
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(const <Object?>[]),
    );
    expect(
      find.byKey(const Key('room-details-email-invitations')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());

    final capableAccount = await withCapabilities({'email-csv-import'});
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
      find.byKey(const Key('room-details-email-invitations')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a preview uploads testRun=1 and sends nothing', (tester) async {
    final capableAccount = await withCapabilities({'email-csv-import'});
    final uploads = <String>[];
    final client = _emailInvitationClient(uploads);

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      csvPicker: _csvPicker(_invitationCsv),
    );
    await tester.tap(find.byKey(const Key('room-details-email-invitations')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-email-invitations-preview'))
          .evaluate()
          .isNotEmpty,
    );

    expect(uploads, hasLength(1));
    expect(uploads.single, contains('name="testRun"\r\n\r\n1'));
    expect(uploads.single, contains('up08.alpha@example.org'));
    expect(
      _textByKey(tester, 'room-details-email-invitations-invites'),
      '2 addresses will be invited',
    );
    expect(
      _textByKey(tester, 'room-details-email-invitations-duplicates'),
      '1 address is already invited or repeated',
    );
    expect(
      _textByKey(tester, 'room-details-email-invitations-nothing-sent'),
      'Nothing has been sent yet. This is only a preview of what the server '
      'found in the file.',
    );

    await tester.tap(
      find.byKey(const Key('room-details-email-invitations-cancel')),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // Cancelling after the preview must leave the count where it was: the
    // preview is the only request that ran.
    expect(uploads, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('confirming the preview posts a second, real import', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'email-csv-import'});
    final uploads = <String>[];
    final client = _emailInvitationClient(uploads);

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      csvPicker: _csvPicker(_invitationCsv),
    );
    await tester.tap(find.byKey(const Key('room-details-email-invitations')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-email-invitations-preview'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const Key('room-details-email-invitations-send')),
    );
    await _pumpUntil(
      tester,
      () => find.text('2 invitations were sent.').evaluate().isNotEmpty,
    );

    expect(uploads, hasLength(2));
    expect(uploads.first, contains('name="testRun"\r\n\r\n1'));
    expect(uploads.last, contains('name="testRun"\r\n\r\n0'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a preview with nothing to invite cannot be sent', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'email-csv-import'});
    final uploads = <String>[];
    final client = _emailInvitationClient(
      uploads,
      previewData: const {'invites': 0, 'duplicates': 2},
    );

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      csvPicker: _csvPicker(_invitationCsv),
    );
    await tester.tap(find.byKey(const Key('room-details-email-invitations')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-email-invitations-preview'))
          .evaluate()
          .isNotEmpty,
    );

    expect(
      _textByKey(tester, 'room-details-email-invitations-invites'),
      'No new address to invite',
    );
    final send = tester.widget<FilledButton>(
      find.byKey(const Key('room-details-email-invitations-send')),
    );
    expect(send.onPressed, isNull);

    await tester.tap(
      find.byKey(const Key('room-details-email-invitations-cancel')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(uploads, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('invalid rows are reported per line and stop the import', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'email-csv-import'});
    final uploads = <String>[];
    final client = _emailInvitationClient(
      uploads,
      previewStatus: 400,
      previewData: const {
        'error': 'Following lines are invalid: 2, 5',
        'message': 'Following lines are invalid: 2, 5',
        'invites': 2,
        'duplicates': 1,
        'invalid': 2,
        'invalidLines': [2, 5],
      },
    );

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      csvPicker: _csvPicker(_invitationCsv),
    );
    await tester.tap(find.byKey(const Key('room-details-email-invitations')));
    await _pumpUntil(
      tester,
      () => find
          .text(
            'The server refused the file and imported nothing. Invalid '
            'lines: 2, 5.',
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(
      find.byKey(const Key('room-details-email-invitations-preview')),
      findsNothing,
    );
    expect(uploads, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an oversized CSV is refused before anything is uploaded', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'email-csv-import'});
    final uploads = <String>[];
    final client = _emailInvitationClient(uploads);
    final oversized = StringBuffer('email,name\n');
    while (oversized.length <= emailInvitationCsvMaximumBytes) {
      oversized.write('up08.bulk${oversized.length}@example.org,Bulk\n');
    }

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      csvPicker: _csvPicker(oversized.toString()),
    );
    await tester.tap(find.byKey(const Key('room-details-email-invitations')));
    await _pumpUntil(
      tester,
      () => find
          .text(
            'This file is larger than 512 kB. Split the list and import it '
            'in parts.',
          )
          .evaluate()
          .isNotEmpty,
    );

    expect(uploads, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a role refusal is reported and never repeated', (tester) async {
    final capableAccount = await withCapabilities({'email-csv-import'});
    final uploads = <String>[];
    final client = _emailInvitationClient(
      uploads,
      previewStatus: 403,
      previewData: const <Object?>[],
    );

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      csvPicker: _csvPicker(_invitationCsv),
    );
    await tester.tap(find.byKey(const Key('room-details-email-invitations')));
    await _pumpUntil(
      tester,
      () => find
          .text("You don't have permission to do this.")
          .evaluate()
          .isNotEmpty,
    );

    expect(uploads, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a send that ends without an answer is reported as uncertain', (
    tester,
  ) async {
    final capableAccount = await withCapabilities({'email-csv-import'});
    var imports = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess();
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return _emailInvitationCapabilities();
      }
      if (request.url.path.endsWith('/import-emails')) {
        imports++;
        if (imports == 1) {
          return _emailInvitationResponse(200, const {
            'invites': 2,
            'duplicates': 0,
          });
        }
        throw http.ClientException('connection reset');
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      csvPicker: _csvPicker(_invitationCsv),
    );
    await tester.tap(find.byKey(const Key('room-details-email-invitations')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-email-invitations-preview'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const Key('room-details-email-invitations-send')),
    );
    await _pumpUntil(
      tester,
      () => find
          .text(
            'The connection dropped while the invitations were being sent, '
            'so it is not known whether they went out. Check the participant '
            'list before trying again — nothing was repeated automatically.',
          )
          .evaluate()
          .isNotEmpty,
    );

    // Exactly the one real attempt: the failed send is reported, not retried.
    expect(imports, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('resend-all is offered only where an e-mail attendee exists', (
    tester,
  ) async {
    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient([
        _participantJson(
          attendeeId: 1,
          actorId: 'fixture-user',
          participantType: 1,
          displayName: 'Owner',
        ),
      ]),
    );
    expect(
      find.byKey(const Key('room-details-resend-invitations')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());

    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: participantsClient(_emailAttendeeList()),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('room-participant-2')).evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const Key('room-details-resend-invitations')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('resend-all POSTs once, without an attendee id', (tester) async {
    final bodies = <String>[];
    final client = _resendClient(bodies);

    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: client,
    );
    await _pumpUntilResendTile(tester);
    await tester.tap(find.byKey(const Key('room-details-resend-invitations')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('room-details-resend-invitations-confirm')),
    );
    await _pumpUntil(
      tester,
      () => find.text('The invitations were sent again.').evaluate().isNotEmpty,
    );

    expect(bodies, <String>['']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelling the resend warning sends nothing', (tester) async {
    final bodies = <String>[];
    final client = _resendClient(bodies);

    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: client,
    );
    await _pumpUntilResendTile(tester);
    await tester.tap(find.byKey(const Key('room-details-resend-invitations')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('room-details-resend-invitations-cancel')),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(bodies, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one attendee can be resent from the participant menu', (
    tester,
  ) async {
    final bodies = <String>[];
    final client = _resendClient(bodies);

    await openDetails(
      tester,
      forAccount: account,
      forConversation: conversation,
      client: client,
    );
    await _pumpUntilResendTile(tester);
    // A user attendee has the moderation actions but no invitation to resend;
    // only the e-mail attendee gets the extra entry.
    await tester.tap(find.byKey(const Key('room-participant-menu-3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-participant-3-promote')), findsOneWidget);
    expect(
      find.byKey(const Key('room-participant-3-resendInvitation')),
      findsNothing,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('room-participant-menu-2')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('room-participant-2-resendInvitation')),
    );
    await _pumpUntil(
      tester,
      () => find.text('The invitation was sent again.').evaluate().isNotEmpty,
    );

    expect(bodies, <String>['attendeeId=2']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// A moderator, plus one attendee invited by e-mail.
List<Map<String, Object?>> _emailAttendeeList() => [
  _participantJson(
    attendeeId: 1,
    actorId: 'fixture-user',
    participantType: 1,
    displayName: 'Owner',
  ),
  _participantJson(
    attendeeId: 2,
    actorType: 'emails',
    actorId: 'hashed-email-actor',
    participantType: 3,
    displayName: 'Alpha Tester',
  ),
  _participantJson(
    attendeeId: 3,
    actorId: 'synthetic-user',
    participantType: 3,
    displayName: 'Synthetic User',
  ),
];

/// The resend tile only appears once the participant list has arrived, which
/// is a second request after the screen itself is up.
Future<void> _pumpUntilResendTile(WidgetTester tester) {
  return _pumpUntil(
    tester,
    () => find
        .byKey(const Key('room-details-resend-invitations'))
        .evaluate()
        .isNotEmpty,
  );
}

http.Response _emailInvitationCapabilities() => http.Response(
  jsonEncode(
    capabilitiesJson(talkFeatures: const <String>['email-csv-import']),
  ),
  200,
);

http.Response _emailInvitationResponse(int statusCode, Object? data) =>
    http.Response(
      jsonEncode({
        'ocs': {
          'meta': {
            'status': statusCode == 200 ? 'ok' : 'failure',
            'statuscode': statusCode,
            'message': 'OK',
          },
          'data': data,
        },
      }),
      statusCode,
    );

/// Records every multipart body that reaches `import-emails`. The first call
/// answers with [previewData]; a second one is always the real send and
/// echoes `type`, which is how the server marks it.
http.Client _emailInvitationClient(
  List<String> uploads, {
  int previewStatus = 200,
  Object? previewData = const {'invites': 2, 'duplicates': 1},
}) {
  return MockClient((request) async {
    if (request.url.path.endsWith('/participants')) {
      return _ocsSuccess();
    }
    if (request.url.path.endsWith('/cloud/capabilities')) {
      return _emailInvitationCapabilities();
    }
    if (request.url.path.endsWith('/import-emails')) {
      final body = utf8.decode(request.bodyBytes);
      uploads.add(body);
      if (body.contains('name="testRun"\r\n\r\n1')) {
        return _emailInvitationResponse(previewStatus, previewData);
      }
      return _emailInvitationResponse(200, const {
        'invites': 2,
        'duplicates': 1,
        'type': 3,
      });
    }
    return http.Response('', 404);
  });
}

/// Records every resend body and always answers the documented `200` with a
/// `null` payload.
http.Client _resendClient(List<String> bodies) {
  return MockClient((request) async {
    if (request.url.path.endsWith('/participants/resend-invitations')) {
      bodies.add(request.body);
      return _emailInvitationResponse(200, null);
    }
    if (request.url.path.endsWith('/participants')) {
      return _ocsSuccess(_emailAttendeeList());
    }
    if (request.url.path.endsWith('/cloud/capabilities')) {
      return _emailInvitationCapabilities();
    }
    return http.Response('', 404);
  });
}
