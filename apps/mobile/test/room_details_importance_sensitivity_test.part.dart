part of 'room_details_screen_test.dart';

void _registerImportanceSensitivityTests() {
  testWidgets('shows capability-gated toggles and trusts returned room flags', (
    tester,
  ) async {
    var important = false;
    var sensitive = false;
    final mutations = <(String, String)>[];
    final capableAccount = await withCapabilities(const <String>{
      'important-conversations',
      'sensitive-conversations',
    });
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/participants')) {
        return _ocsSuccess(const <Object?>[]);
      }
      if (request.url.path.endsWith('/cloud/capabilities')) {
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: const <String>[
                'important-conversations',
                'sensitive-conversations',
              ],
            ),
          ),
          200,
        );
      }
      if (request.url.path.endsWith('/important')) {
        important = request.method == 'POST';
        mutations.add((request.method, 'important'));
        return _ocsSuccess(
          _conversationRoomJson()
            ..['isImportant'] = important
            ..['isSensitive'] = sensitive,
        );
      }
      if (request.url.path.endsWith('/sensitive')) {
        sensitive = request.method == 'POST';
        mutations.add((request.method, 'sensitive'));
        return _ocsSuccess(
          _conversationRoomJson()
            ..['isImportant'] = important
            ..['isSensitive'] = sensitive,
        );
      }
      return http.Response('', 404);
    });

    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: conversation,
      client: client,
      height: 3000,
    );

    final importantToggle = find.byKey(
      const Key('room-details-important-toggle'),
    );
    final sensitiveToggle = find.byKey(
      const Key('room-details-sensitive-toggle'),
    );
    expect(importantToggle, findsOneWidget);
    expect(sensitiveToggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(importantToggle).value, isFalse);
    expect(tester.widget<SwitchListTile>(sensitiveToggle).value, isFalse);

    await tester.tap(importantToggle);
    await _pumpUntil(
      tester,
      () => tester.widget<SwitchListTile>(importantToggle).value,
    );
    await tester.tap(sensitiveToggle);
    await _pumpUntil(
      tester,
      () => tester.widget<SwitchListTile>(sensitiveToggle).value,
    );
    await tester.tap(importantToggle);
    await _pumpUntil(
      tester,
      () => !tester.widget<SwitchListTile>(importantToggle).value,
    );
    await tester.tap(sensitiveToggle);
    await _pumpUntil(
      tester,
      () => !tester.widget<SwitchListTile>(sensitiveToggle).value,
    );

    expect(mutations, <(String, String)>[
      ('POST', 'important'),
      ('POST', 'sensitive'),
      ('DELETE', 'important'),
      ('DELETE', 'sensitive'),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hides both toggles when the cached capabilities do not admit them',
    (tester) async {
      await openDetails(
        tester,
        forAccount: account,
        forConversation: conversation,
        client: participantsClient(const <Object?>[]),
      );

      expect(
        find.byKey(const Key('room-details-important-toggle')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('room-details-sensitive-toggle')),
        findsNothing,
      );
    },
  );

  testWidgets('keeps classified conversations visibly sensitive and locked', (
    tester,
  ) async {
    final capableAccount = await withCapabilities(const <String>{
      'sensitive-conversations',
    });
    final classified = await _insertConversation(
      database,
      capableAccount,
      overrides: const <String, Object?>{'attributes': 4, 'isSensitive': true},
    );
    await openDetails(
      tester,
      forAccount: capableAccount,
      forConversation: classified,
      client: participantsClient(const <Object?>[]),
      height: 2800,
    );

    final toggle = find.byKey(const Key('room-details-sensitive-toggle'));
    expect(toggle, findsOneWidget);
    final widget = tester.widget<SwitchListTile>(toggle);
    expect(widget.value, isTrue);
    expect(widget.onChanged, isNull);
    expect(find.text('Required for classified conversations'), findsOneWidget);
  });
}
