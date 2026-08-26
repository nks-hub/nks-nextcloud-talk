part of 'chat_room_live_sync_test.dart';

void _registerReadMarkerSerializationTest() {
  testWidgets('visible read markers stay serialized while a POST is pending', (
    tester,
  ) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final chat = ChatRepository(database);
    final vault = MemoryCredentialVault();
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    vault.values[account.id] = 'fixture-app-password-never-use';
    final roomWire = _conversationRoomJson();
    final room = ConversationRoom.fromJson(roomWire);
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: room.token.value,
            displayName: room.displayName,
            description: room.description,
            lastActivity: room.lastActivity,
            unreadMessages: room.unreadMessages,
            favorite: room.isFavorite,
            rawJson: jsonEncode(roomWire),
          ),
        );
    final conversation = (await chat.getConversation(
      accountId: account.id,
      roomToken: room.token.value,
    ))!;

    const features = <String>{
      'conversation-v4',
      'chat-v2',
      'chat-read-marker',
      'chat-read-last',
      'chat-keep-notifications',
    };
    final firstReadResponse = Completer<http.Response>();
    final waitingCycleResponse = Completer<http.Response>();
    final waitingCycleReleased = Completer<void>();
    final readTargets = <int>[];
    var futureRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(capabilitiesJson(talkFeatures: features.toList())),
            200,
          );
        }
        if (request.url.path.contains('/avatar/')) {
          return http.Response('', 404);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/chat/rooma123/read')) {
          final target = int.parse(
            Uri.splitQueryString(request.body)['lastReadMessage']!,
          );
          readTargets.add(target);
          if (target == 120) {
            return firstReadResponse.future;
          }
          return http.Response(jsonEncode(_readMarkerResponse(target)), 200);
        }
        if (request.url.queryParameters['lookIntoFuture'] == '0') {
          return http.Response('', 304);
        }
        futureRequests++;
        if (futureRequests == 5) {
          try {
            return await waitingCycleResponse.future;
          } finally {
            waitingCycleReleased.complete();
          }
        }
        return switch (futureRequests) {
          1 => http.Response(
            jsonEncode(_rootReadMessageResponse(120, 'Message 120')),
            200,
            headers: const {
              'X-Chat-Last-Given': '120',
              'X-Chat-Last-Common-Read': '109',
            },
          ),
          2 => http.Response('', 304),
          3 => http.Response(
            jsonEncode(_rootReadMessageResponse(121, 'Message 121')),
            200,
            headers: const {
              'X-Chat-Last-Given': '121',
              'X-Chat-Last-Common-Read': '109',
            },
          ),
          4 => http.Response('', 304),
          _ => throw StateError('Unexpected future request $futureRequests'),
        };
      }),
    );
    addTearDown(api.close);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          credentialVaultProvider.overrideWithValue(vault),
          nextcloudApiProvider.overrideWithValue(api),
          connectivityWakeEventsProvider.overrideWithValue(
            const Stream<void>.empty(),
          ),
        ],
        child: localizedTestApp(
          home: ChatRoomPane(account: account, conversation: conversation),
        ),
      ),
    );

    await _pumpUntil(tester, () => readTargets.length == 1);
    expect(readTargets, [120]);
    await tester.pump(const Duration(seconds: 1));
    await _pumpUntil(
      tester,
      () =>
          futureRequests >= 4 &&
          find.text('Message 121', findRichText: true).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(seconds: 1));
    await _pumpUntil(tester, () => futureRequests == 5);

    expect(
      readTargets,
      [120],
      reason: 'A newer marker must wait for the earlier POST to settle',
    );

    final finalMarkerApplied = chat
        .watchRootScope(accountId: account.id, roomToken: room.token.value)
        .firstWhere((scope) => scope?.lastReadMessage == 121);
    firstReadResponse.complete(
      http.Response(jsonEncode(_readMarkerResponse(120)), 200),
    );
    await _pumpUntil(tester, () => readTargets.length == 2);
    await tester.runAsync(
      () => finalMarkerApplied.timeout(const Duration(seconds: 2)),
    );
    waitingCycleResponse.complete(http.Response('', 304));
    expect(readTargets, [120, 121]);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(tester, () => waitingCycleReleased.isCompleted);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  });
}

Map<String, Object?> _rootReadMessageResponse(int messageId, String message) {
  final response = _externalMessageResponse(message: message, threadId: null);
  final ocs = response['ocs']! as Map<String, Object?>;
  final wire =
      Map<String, Object?>.from(
          (ocs['data']! as List<Object?>).single! as Map<String, Object?>,
        )
        ..['id'] = messageId
        ..['timestamp'] = 1770000000 + messageId;
  ocs['data'] = <Object?>[wire];
  return response;
}
