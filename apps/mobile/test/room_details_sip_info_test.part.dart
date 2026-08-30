part of 'room_details_screen_test.dart';

void _registerSipInfoTests() {
  testWidgets('every participant sees SIP instructions, meeting ID and PIN', (
    tester,
  ) async {
    final capable = await withCapabilities({'sip-support'});
    final enabled = await _insertConversation(
      database,
      account,
      overrides: {
        'canEnableSIP': false,
        'participantType': 3,
        'sipEnabled': 1,
        'attendeePin': '1234567',
      },
    );
    var settingsRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/signaling/settings')) {
        settingsRequests++;
        expect(request.url.queryParameters['token'], 'rooma123');
        return _signalingSettingsSuccess(
          'Call +1 202-555-0100 and follow the voice instructions.',
        );
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: enabled,
      client: client,
    );
    await _pumpUntil(
      tester,
      () => find
          .text('Call +1 202-555-0100 and follow the voice instructions.')
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byKey(const Key('room-details-sip')), findsNothing);
    expect(find.byKey(const Key('room-details-sip-dial-in')), findsOneWidget);
    expect(find.text('roo ma1 23'), findsOneWidget);
    expect(find.text('123 4567'), findsOneWidget);
    expect(settingsRequests, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('SIP without PIN omits the personal PIN row', (tester) async {
    final capable = await withCapabilities({'sip-support'});
    final enabled = await _insertConversation(
      database,
      account,
      overrides: {
        'canEnableSIP': false,
        'participantType': 3,
        'sipEnabled': 2,
        'attendeePin': null,
      },
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.url.path.endsWith('/signaling/settings')) {
        return _signalingSettingsSuccess('');
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: enabled,
      client: client,
    );
    await _pumpUntil(
      tester,
      () => find
          .text('The server did not provide dial-in instructions.')
          .evaluate()
          .isNotEmpty,
    );

    expect(find.text('roo ma1 23'), findsOneWidget);
    expect(
      find.byKey(const Key('room-details-sip-personal-pin')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('failed SIP instructions can be retried without losing IDs', (
    tester,
  ) async {
    final capable = await withCapabilities({'sip-support'});
    final enabled = await _insertConversation(
      database,
      account,
      overrides: {
        'canEnableSIP': false,
        'sipEnabled': 1,
        'attendeePin': '1234567',
      },
    );
    var settingsRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.url.path.endsWith('/signaling/settings')) {
        settingsRequests++;
        return settingsRequests == 1
            ? _ocsFailure(503)
            : _signalingSettingsSuccess('Synthetic retry instructions');
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capable,
      forConversation: enabled,
      client: client,
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('room-details-sip-instructions-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('roo ma1 23'), findsOneWidget);
    expect(find.text('123 4567'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('room-details-sip-instructions-retry')),
    );
    await _pumpUntil(
      tester,
      () => find.text('Synthetic retry instructions').evaluate().isNotEmpty,
    );

    expect(settingsRequests, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

http.Response _signalingSettingsSuccess(String sipDialinInfo) {
  return _ocsSuccess({
    'signalingMode': 'internal',
    'userId': 'fixture-user',
    'hideWarning': false,
    'server': '',
    'federation': null,
    'stunservers': <Object?>[],
    'turnservers': <Object?>[],
    'sipDialinInfo': sipDialinInfo,
  });
}
