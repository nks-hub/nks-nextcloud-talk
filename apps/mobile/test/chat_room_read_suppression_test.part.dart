part of 'chat_room_live_sync_test.dart';

Future<void> _verifySuppressedRootRead(
  WidgetTester tester, {
  AppLifecycleState lifecycleState = AppLifecycleState.resumed,
  int? jumpToMessageId,
  bool disposeBeforeResponse = false,
  bool idleWindow = false,
  bool coveredByDialog = false,
  bool supportsSilentFetch = true,
  bool resumeLegacy = false,
}) async {
  final readerActivity = StateProvider<bool>((ref) => !idleWindow);
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
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
  final conversation = await ChatRepository(
    database,
  ).getConversation(accountId: account.id, roomToken: room.token.value);

  final delayedResponse = Completer<http.Response>();
  final longPollResponse = Completer<http.Response>();
  final longPollReleased = Completer<void>();
  final readTargets = <int>[];
  var futureRequests = 0;
  var capabilityRequests = 0;
  var longPollStarted = false;
  final api = HttpNextcloudApi(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/cloud/capabilities')) {
        capabilityRequests++;
        return http.Response(
          jsonEncode(
            capabilitiesJson(
              talkFeatures: <String>[
                'conversation-v4',
                'chat-v2',
                'chat-read-marker',
                'chat-read-last',
                if (supportsSilentFetch) 'chat-keep-notifications',
              ],
            ),
          ),
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
        return http.Response(jsonEncode(_readMarkerResponse(target)), 200);
      }
      if (request.url.queryParameters['lookIntoFuture'] == '0') {
        if (idleWindow && supportsSilentFetch) {
          expect(request.url.queryParameters['noStatusUpdate'], '1');
          expect(request.url.queryParameters['markNotificationsAsRead'], '0');
        }
        return http.Response('', 304);
      }
      if (idleWindow && supportsSilentFetch) {
        expect(request.url.queryParameters['noStatusUpdate'], '1');
        expect(request.url.queryParameters['markNotificationsAsRead'], '0');
      }
      futureRequests++;
      if (futureRequests == 1 && (disposeBeforeResponse || coveredByDialog)) {
        return delayedResponse.future;
      }
      if (futureRequests == 1) {
        return http.Response(
          jsonEncode(
            _externalRootMessagesResponse(
              includeOlder: jumpToMessageId != null,
            ),
          ),
          200,
          headers: const {
            'X-Chat-Last-Given': '120',
            'X-Chat-Last-Common-Read': '110',
          },
        );
      }
      if (futureRequests == 2 && !disposeBeforeResponse) {
        return http.Response('', 304);
      }
      longPollStarted = true;
      try {
        return await longPollResponse.future;
      } finally {
        if (!longPollReleased.isCompleted) {
          longPollReleased.complete();
        }
      }
    }),
  );
  addTearDown(api.close);

  tester.binding.handleAppLifecycleStateChanged(lifecycleState);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (idleWindow)
          windowActiveProvider.overrideWith((ref) => ref.watch(readerActivity)),
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        connectivityWakeEventsProvider.overrideWithValue(
          const Stream<void>.empty(),
        ),
      ],
      child: localizedTestApp(
        home: ChatRoomPane(
          account: account,
          conversation: conversation!,
          jumpToMessageId: jumpToMessageId,
        ),
      ),
    ),
  );

  final legacyIdle = idleWindow && !supportsSilentFetch;
  int? legacyRequests;
  if (legacyIdle) {
    await _pumpUntil(tester, () => capabilityRequests > 0);
    for (var turn = 0; turn < 15; turn++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    legacyRequests = futureRequests;
    if (resumeLegacy) {
      ProviderScope.containerOf(
        tester.element(find.byType(ChatRoomPane)),
      ).read(readerActivity.notifier).state = true;
      for (var turn = 0; turn < 50 && readTargets.isEmpty; turn++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
    }
  } else if (lifecycleState != AppLifecycleState.resumed) {
    await tester.pump(const Duration(milliseconds: 100));
    expect(futureRequests, 0);
  } else if (coveredByDialog) {
    await _pumpUntil(tester, () => futureRequests == 1);
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(ChatRoomPane)),
        builder: (_) => const AlertDialog(content: Text('Covering dialog')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    delayedResponse.complete(
      http.Response(
        jsonEncode(_externalRootMessagesResponse()),
        200,
        headers: const {
          'X-Chat-Last-Given': '120',
          'X-Chat-Last-Common-Read': '110',
        },
      ),
    );
    await _pumpUntil(tester, () => futureRequests >= 2);
    await tester.pump(const Duration(milliseconds: 100));
  } else if (disposeBeforeResponse) {
    await _pumpUntil(tester, () => futureRequests == 1);
    await tester.pumpWidget(const SizedBox.shrink());
    delayedResponse.complete(
      http.Response(
        jsonEncode(_externalRootMessagesResponse()),
        200,
        headers: const {
          'X-Chat-Last-Given': '120',
          'X-Chat-Last-Common-Read': '110',
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await _pumpUntil(
      tester,
      () =>
          find.text('Newer message', findRichText: true).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  final completedReads = List<int>.of(readTargets);
  await tester.pumpWidget(const SizedBox.shrink());
  if (!longPollResponse.isCompleted) {
    longPollResponse.complete(http.Response('', 304));
  }
  if (longPollStarted && !longPollReleased.isCompleted) {
    await _pumpUntil(tester, () => longPollReleased.isCompleted);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 1)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  if (legacyIdle) expect(legacyRequests, 0);
  if (disposeBeforeResponse) expect(futureRequests, 1);
  expect(completedReads, resumeLegacy ? contains(120) : isEmpty);
}
