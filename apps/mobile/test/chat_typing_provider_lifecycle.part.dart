part of 'chat_typing_indicator_test.dart';

void _registerTypingProviderLifecycleTests() {
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
}
