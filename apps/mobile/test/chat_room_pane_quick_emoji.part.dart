part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneQuickEmojiTests() {
  Future<FakeOwnTalkServer> openPane(
    WidgetTester tester, {
    required FakeOwnTalkServer server,
    bool withSurface = false,
    CachedConversation? room,
  }) async {
    final shown = room ?? conversation;
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
          body: withSurface
              ? ChatBackgroundSurface(
                  accountId: account.id,
                  roomToken: shown.token,
                  sharedSettings: ownTalkConversationCanShare(
                    roomType: shown.roomType,
                    rawJson: shown.rawJson,
                  ),
                  child: ChatRoomPane(account: account, conversation: shown),
                )
              : ChatRoomPane(account: account, conversation: shown),
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

  testWidgets('a changelog conversation never asks the extension, even with '
      'the capability and a stored quick emoji', (tester) async {
    final server = FakeOwnTalkServer()
      ..setExternally({
        'composer.quickEmoji': '\u{1F44D}',
        'chat.backgroundColor': '#1E3A5F',
      });
    await openPane(
      tester,
      server: server,
      withSurface: true,
      room: conversation.copyWith(roomType: 4),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(server.settingsRequests, isEmpty);
    expect(find.byKey(const Key('send-quick-emoji')), findsNothing);
    expect(find.byKey(const Key('send-message')), findsOneWidget);
    await unmountPane(tester);
  });

  testWidgets('a federated conversation never asks the extension', (
    tester,
  ) async {
    final server = FakeOwnTalkServer()
      ..setExternally({'composer.quickEmoji': '\u{1F44D}'});
    final raw = Map<String, Object?>.from(
      jsonDecode(conversation.rawJson) as Map<String, Object?>,
    )..['remoteServer'] = 'https://other.example';
    await openPane(
      tester,
      server: server,
      withSurface: true,
      room: conversation.copyWith(rawJson: jsonEncode(raw)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(server.settingsRequests, isEmpty);
    expect(find.byKey(const Key('send-quick-emoji')), findsNothing);
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

  Color bubbleColor(WidgetTester tester) {
    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const Key('chat-message-target-10')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    return (container.decoration! as BoxDecoration).color!;
  }

  testWidgets('shared bubble colours reach the message bubble', (tester) async {
    final server = FakeOwnTalkServer()
      ..setExternally({
        'bubble.otherColor': '#112233',
        'bubble.otherTextColor': '#101010',
      });
    await openPane(tester, server: server, withSurface: true);
    await pumpUntilCondition(
      tester,
      () => bubbleColor(tester) == const Color(0xFF112233),
    );
    expect(tester.takeException(), isNull);
    await unmountPane(tester);
  });

  testWidgets('without the capability the bubble keeps the theme colour', (
    tester,
  ) async {
    final server = FakeOwnTalkServer(capability: null);
    await openPane(tester, server: server, withSurface: true);
    await pumpUntilCondition(tester, () => server.requests.isNotEmpty);
    await tester.pump(const Duration(milliseconds: 50));
    final scheme = Theme.of(
      tester.element(find.byKey(const Key('chat-message-target-10'))),
    ).colorScheme;
    expect(bubbleColor(tester), scheme.surfaceContainerHigh);
    await unmountPane(tester);
  });
}
