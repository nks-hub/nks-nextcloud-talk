part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneHistoryScopeTests() {
  testWidgets('switching rooms revokes a pending legacy history read', (
    tester,
  ) async {
    final fixture =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )
            as Map;
    final roomJson = Map<String, Object?>.from(
      ((fixture['ocs'] as Map)['data'] as List).first as Map,
    );
    roomJson['token'] = conversation.token;
    await (database.update(
      database.cachedConversations,
    )..where((row) => row.token.equals(conversation.token))).write(
      CachedConversationsCompanion(rawJson: Value(jsonEncode(roomJson))),
    );
    final scope = ChatScopesCompanion.insert(
      accountId: account.id,
      roomToken: conversation.token,
      scopeKey: 'root',
      historyCursor: '10',
      futureCursor: '10',
      lastCommonRead: '10',
      lastReadMessage: 0,
      unreadMessages: 0,
      hasHistory: true,
      futureConverged: true,
      blocksJson: '[["10","10"]]',
    );
    await database.into(database.chatScopes).insert(scope);
    final heldVault = _HeldSendCredentialVault();
    var oldRoomReads = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                talkFeatures: const [
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                ],
              ),
            ),
            200,
          );
        }
        if (request.url.path.endsWith('/chat/rooma123')) oldRoomReads++;
        return http.Response('', 304);
      }),
    );
    final service = ChatService(
      accounts: accounts,
      chat: ChatRepository(database),
      credentials: heldVault,
      api: api,
    );
    addTearDown(service.close);
    addTearDown(api.close);
    addTearDown(() {
      heldVault.hold = false;
      if (!heldVault.release.isCompleted) heldVault.release.complete(null);
    });
    final selected = ValueNotifier(conversation);
    addTearDown(selected.dispose);
    await tester.pumpWidget(
      app(
        overrides: [chatServiceProvider.overrideWithValue(service)],
        home: Scaffold(
          body: ValueListenableBuilder<CachedConversation>(
            valueListenable: selected,
            builder: (context, room, child) =>
                ChatRoomPane(account: account, conversation: room),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    heldVault.hold = true;
    await tester.tap(find.byKey(const Key('chat-load-older')));
    for (var i = 0; i < 200 && !heldVault.started.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    expect(heldVault.started.isCompleted, isTrue);
    final oldState = tester.state(find.byType(ChatRoomPane));
    heldVault.hold = false;
    selected.value = conversation.copyWith(token: 'roomb456');
    await tester.pump();
    expect(
      identical(tester.state(find.byType(ChatRoomPane)), oldState),
      isTrue,
    );
    heldVault.release.complete('fixture-password');
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    expect(
      oldRoomReads,
      0,
      reason: 'Active room B cannot authorize history reads for room A',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.close);
    await tester.pumpAndSettle();
  });
}
