part of 'chat_typing_indicator_test.dart';

void _registerTypingProviderLifecycleTests() {
  test('session zero activates the room before peer typing', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final credentials = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'signaling-v3', 'typing-privacy'},
      createdAt: DateTime.utc(2026, 9, 1),
    );
    await ChatRepository(database).recordCapabilities(
      accountId: 'account-a',
      talkFeatures: const {'signaling-v3', 'typing-privacy'},
      observedAt: DateTime.utc(2026, 9, 1),
    );
    credentials.values['account-a'] = 'fixture-password';
    final account = (await accounts.getAccount('account-a'))!;
    final conversation = _sessionZeroConversation();
    final key = chatTypingRoomKeyFor(
      account: account,
      conversation: conversation,
    )!;
    final client = _ActiveTypingClient();
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    final sockets = _ActiveTypingSockets();
    final coordinator = CallSignalingCoordinator(
      accounts: accounts,
      sessions: CallSessionRepository(database),
      credentials: credentials,
      api: api,
      socketConnector: sockets,
      refreshConversationSession: (_, _) async =>
          ConversationSessionId.parse('active-session'),
    );
    addTearDown(coordinator.dispose);
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(credentials),
        nextcloudApiProvider.overrideWithValue(api),
        callSignalingCoordinatorProvider.overrideWithValue(coordinator),
      ],
    );
    addTearDown(container.dispose);
    final states = <ChatTypingState>[];
    final subscription = container.listen(chatTypingStateProvider(key), (
      _,
      next,
    ) {
      final state = next.valueOrNull;
      if (state != null) states.add(state);
    }, fireImmediately: true);
    addTearDown(subscription.close);

    final socket = await sockets.connected.future.timeout(
      const Duration(seconds: 5),
    );
    socket.add(_activeWelcome());
    final hello = jsonDecode(await socket.sent(0)) as Map<String, Object?>;
    await _flushAsync();
    socket.add(_activeHello(hello['id']! as String));
    final room = jsonDecode(await socket.sent(1)) as Map<String, Object?>;
    expect(
      (room['room']! as Map<String, Object?>)['sessionid'],
      'active-session',
    );
    await _flushAsync();
    socket.add(_activeRoom(room['id']! as String));
    await _flushAsync();
    socket
      ..add(_activePeerJoin())
      ..add(_activeTyping());
    final state = await _firstTypingState(states);

    expect(state.participants.single.actorId, 'alice');
    expect(
      client.paths.indexWhere((path) => path.endsWith('/participants/active')),
      lessThan(client.paths.indexWhere((path) => path.endsWith('/settings'))),
    );
    final stored = await database.select(database.callSessions).getSingle();
    expect(stored.nextcloudSessionId, 'active-session');
  });

  test('account shutdown during activation blocks late signaling', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final credentials = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'signaling-v3', 'typing-privacy'},
      createdAt: DateTime.utc(2026, 9, 1),
    );
    credentials.values['account-a'] = 'fixture-password';
    final account = (await accounts.getAccount('account-a'))!;
    final key = chatTypingRoomKeyFor(
      account: account,
      conversation: _sessionZeroConversation(),
    )!;
    final client = _ActiveTypingClient(holdActive: true);
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    final sockets = _ActiveTypingSockets();
    final coordinator = CallSignalingCoordinator(
      accounts: accounts,
      sessions: CallSessionRepository(database),
      credentials: credentials,
      api: api,
      socketConnector: sockets,
      refreshConversationSession: (_, _) async => null,
    );
    addTearDown(coordinator.dispose);
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(credentials),
        nextcloudApiProvider.overrideWithValue(api),
        callSignalingCoordinatorProvider.overrideWithValue(coordinator),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      chatTypingStateProvider(key),
      (_, _) {},
      fireImmediately: true,
    );
    await client.activeStarted.future.timeout(const Duration(seconds: 5));
    addTearDown(subscription.close);
    final coordinatorShutdown = coordinator.shutdownAccount('account-a');
    final sessionShutdown = api.shutdownAccountSession(
      accountId: 'account-a',
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    client.releaseActive.complete();
    await Future.wait([coordinatorShutdown, sessionShutdown]);
    await container.pump();

    expect(client.deletes, 1);
    expect(client.settings, 0);
    expect(sockets.connected.isCompleted, isFalse);
    expect(await database.select(database.callSessions).get(), isEmpty);
  });

  test('active session 401 marks the account for reauthentication', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final credentials = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'signaling-v3', 'typing-privacy'},
      createdAt: DateTime.utc(2026, 9, 1),
    );
    await ChatRepository(database).recordCapabilities(
      accountId: 'account-a',
      talkFeatures: const {'signaling-v3', 'typing-privacy'},
      observedAt: DateTime.utc(2026, 9, 1),
    );
    credentials.values['account-a'] = 'fixture-password';
    final account = (await accounts.getAccount('account-a'))!;
    final api = HttpNextcloudApi(
      client: _ActiveTypingClient(activeStatus: 401),
    );
    addTearDown(api.close);
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(credentials),
        nextcloudApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      chatTypingStateProvider(
        chatTypingRoomKeyFor(
          account: account,
          conversation: _sessionZeroConversation(),
        )!,
      ),
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    for (var attempt = 0; attempt < 100; attempt++) {
      final capability = await database
          .select(database.chatCapabilities)
          .getSingleOrNull();
      if (capability?.lane == ChatAccountLane.reauthenticationRequired.name) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Account was not marked for reauthentication');
  });

  // Live on 5 September 2026 the server saw FOUR requests in the second the
  // conversation opened - POST, DELETE, POST, DELETE on
  // `/room/{token}/participants/active` - and the last was a DELETE, so the
  // client ended up holding no room session at all. The signalling lane had
  // started with an id from one of those two short-lived sessions, its first
  // pull was answered 409, and 409 is classified as a terminated session, so
  // the lane stopped for good and a joined call never negotiated with anybody.
  // Activating a room session is exclusive, so the second activation is what
  // kills the first. One listener, held for the whole test, must produce
  // exactly one activation and no release.
  test('opening a room activates its session once and keeps it', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    final credentials = MemoryCredentialVault();
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {'signaling-v3', 'typing-privacy'},
      createdAt: DateTime.utc(2026, 9, 1),
    );
    await ChatRepository(database).recordCapabilities(
      accountId: 'account-a',
      talkFeatures: const {'signaling-v3', 'typing-privacy'},
      observedAt: DateTime.utc(2026, 9, 1),
    );
    credentials.values['account-a'] = 'fixture-password';
    final account = (await accounts.getAccount('account-a'))!;
    final client = _ActiveTypingClient();
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    final sockets = _ActiveTypingSockets();
    final coordinator = CallSignalingCoordinator(
      accounts: accounts,
      sessions: CallSessionRepository(database),
      credentials: credentials,
      api: api,
      socketConnector: sockets,
      refreshConversationSession: (_, _) async =>
          ConversationSessionId.parse('active-session'),
    );
    addTearDown(coordinator.dispose);
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(credentials),
        nextcloudApiProvider.overrideWithValue(api),
        callSignalingCoordinatorProvider.overrideWithValue(coordinator),
      ],
    );
    addTearDown(container.dispose);
    final key = chatTypingRoomKeyFor(
      account: account,
      conversation: _sessionZeroConversation(),
    )!;
    final subscription = container.listen(
      chatTypingStateProvider(key),
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await client.activeStarted.future;
    // Long enough for a late-registered dependency to re-run the provider
    // body, which is what a second activation would look like.
    for (var attempt = 0; attempt < 50; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final activations = client.paths
        .where((path) => path.endsWith('/participants/active'))
        .length;
    expect(
      activations - client.deletes,
      1,
      reason: 'the room session has to stay activated while it is listened to',
    );
    expect(
      client.deletes,
      0,
      reason: 'nothing released the room session while the listener was held',
    );
  });
}
