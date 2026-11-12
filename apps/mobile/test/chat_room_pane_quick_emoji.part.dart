part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneQuickEmojiTests() {
  Future<FakeOwnTalkServer> openPane(
    WidgetTester tester, {
    required FakeOwnTalkServer server,
  }) async {
    vault.values[account.id] = 'fixture-password';
    final api = HttpNextcloudApi(client: server.client);
    addTearDown(api.close);
    await tester.pumpWidget(
      app(
        overrides: [
          nextcloudApiProvider.overrideWithValue(api),
          ownTalkSettingsStoreProvider.overrideWith(
            (ref) => Future<OwnTalkSettingsStore>.error(StateError('no store')),
          ),
          appLifecycleResumeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
        ],
        home: Scaffold(
          body: ChatRoomPane(account: account, conversation: conversation),
        ),
      ),
    );
    await tester.pump();
    return server;
  }

  Future<void> unmountPane(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a room quick emoji replaces send while the field is empty', (
    tester,
  ) async {
    final server = FakeOwnTalkServer()
      ..setExternally({'composer.quickEmoji': '\u{1F44D}'});
    await openPane(tester, server: server);
    await pumpUntilCondition(
      tester,
      () => find.byKey(const Key('send-quick-emoji')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('send-message')), findsNothing);
    expect(
      find.byTooltip(RegExp(r'^Send \u{1F44D}', unicode: true)),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const Key('chat-composer')), 'hello');
    await tester.pump();
    expect(find.byKey(const Key('send-quick-emoji')), findsNothing);
    expect(find.byKey(const Key('send-message')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('chat-composer')), '');
    await tester.pump();
    expect(find.byKey(const Key('send-quick-emoji')), findsOneWidget);
    await unmountPane(tester);
  });

  testWidgets('without the capability the composer is unchanged', (
    tester,
  ) async {
    final server = FakeOwnTalkServer(capability: null);
    await openPane(tester, server: server);
    await pumpUntilCondition(tester, () => server.requests.isNotEmpty);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('send-quick-emoji')), findsNothing);
    expect(find.byKey(const Key('send-message')), findsOneWidget);
    expect(server.settingsRequests, isEmpty);
    await unmountPane(tester);
  });

  testWidgets('a capability without the emoji feature keeps send', (
    tester,
  ) async {
    final server = FakeOwnTalkServer(
      capability: ownTalkCapabilityJson(features: ['appearance.colors']),
    )..setExternally({'composer.quickEmoji': '\u{1F44D}'});
    await openPane(tester, server: server);
    await pumpUntilCondition(tester, () => server.settingsRequests.isNotEmpty);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('send-quick-emoji')), findsNothing);
    expect(find.byKey(const Key('send-message')), findsOneWidget);
    await unmountPane(tester);
  });
}
