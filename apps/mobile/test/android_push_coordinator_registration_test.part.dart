part of 'android_push_coordinator_test.dart';

void _registerAndroidPushRegistrationTests() {
  test(
    'registers endpoint, activates it and drains wake-ups by account',
    () async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      const accountId = 'account-a';
      await accounts.upsertAccount(
        accountId: accountId,
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
      );
      final credentials = MemoryCredentialVault()
        ..values[accountId] = 'fixture-password';
      final requests = <http.Request>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return http.Response(
              jsonEncode(
                capabilitiesJson(
                  notificationPushFeatures: const <String>[
                    'devices',
                    'object-data',
                    'delete',
                    'webpush',
                  ],
                ),
              ),
              200,
            );
          }
          if (request.url.path.endsWith('/webpush/vapid')) {
            return http.Response(
              jsonEncode(_ocs(<String, Object>{'vapid': 'B${'a' * 86}'})),
              200,
            );
          }
          if (request.url.path.endsWith('/webpush/activate')) {
            return http.Response(jsonEncode(_ocs(const <Object>[], 202)), 202);
          }
          if (request.url.path.endsWith('/webpush')) {
            return http.Response(jsonEncode(_ocs(const <Object>[], 201)), 201);
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );
      addTearDown(api.close);
      final platform = _FakeAndroidWebPushPlatform();
      final wakeUps = <String>[];
      final coordinator = AndroidPushCoordinator(
        accounts: accounts,
        credentials: credentials,
        api: api,
        platform: platform,
        onWakeUp: (value) async => wakeUps.add(value),
      );
      addTearDown(coordinator.close);

      await coordinator.reconcileAccount(accountId);

      expect(platform.registrations, <({String accountId, int generation})>[
        (accountId: accountId, generation: 1),
      ]);
      expect(platform.committedEventIds, <String>['endpoint-1']);
      expect(platform.acknowledgedEventIds, contains('endpoint-1'));
      expect(platform.permissionRequests, 1);
      expect(
        requests.any((request) => request.url.path.endsWith('/webpush')),
        isTrue,
      );
      expect(wakeUps, <String>[accountId]);

      platform.events.add(
        _messageEvent(
          id: 'activation-1',
          content: <String, Object>{
            'activationToken': '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
          },
        ),
      );
      await coordinator.drainAccount(accountId);

      expect(
        requests.any(
          (request) => request.url.path.endsWith('/webpush/activate'),
        ),
        isTrue,
      );
      expect(platform.acknowledgedEventIds, contains('activation-1'));

      platform.events.add(
        _messageEvent(
          id: 'message-1',
          content: const <String, Object>{
            'nid': 44,
            'app': 'spreed',
            'subject': 'New Talk activity',
            'type': 'chat',
            'id': 'room-a',
          },
        ),
      );
      await coordinator.drainAccount(accountId);

      expect(wakeUps, <String>[accountId, accountId]);
      expect(platform.acknowledgedEventIds, contains('message-1'));
    },
  );

  test(
    'does not register when authenticated capability omits webpush',
    () async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final accounts = AccountRepository(database);
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
      );
      final credentials = MemoryCredentialVault()
        ..values['account-a'] = 'fixture-password';
      final api = HttpNextcloudApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(
              capabilitiesJson(
                notificationPushFeatures: const <String>['devices'],
              ),
            ),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      final platform = _FakeAndroidWebPushPlatform();
      final coordinator = AndroidPushCoordinator(
        accounts: accounts,
        credentials: credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async {},
      );
      addTearDown(coordinator.close);

      await coordinator.reconcileAccount('account-a');

      expect(platform.registrations, isEmpty);
      expect(platform.permissionRequests, 0);
    },
  );

  test('retries a retained activation after a detached HTTP failure', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    const accountId = 'account-a';
    await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    final credentials = MemoryCredentialVault()
      ..values[accountId] = 'fixture-password';
    final firstActivationAttempt = Completer<void>();
    final secondActivationAttempt = Completer<void>();
    var activationAttempts = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                notificationPushFeatures: const <String>['webpush'],
              ),
            ),
            200,
          );
        }
        if (request.url.path.endsWith('/webpush/vapid')) {
          return http.Response(
            jsonEncode(_ocs(<String, Object>{'vapid': 'B${'a' * 86}'})),
            200,
          );
        }
        if (request.url.path.endsWith('/webpush/activate')) {
          activationAttempts++;
          if (activationAttempts == 1) {
            firstActivationAttempt.complete();
            return http.Response(jsonEncode(_ocs(const <Object>[], 503)), 503);
          }
          if (!secondActivationAttempt.isCompleted) {
            secondActivationAttempt.complete();
          }
          return http.Response(jsonEncode(_ocs(const <Object>[], 202)), 202);
        }
        if (request.url.path.endsWith('/webpush')) {
          return http.Response(jsonEncode(_ocs(const <Object>[], 201)), 201);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform();
    final coordinator = AndroidPushCoordinator(
      accounts: accounts,
      credentials: credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      retryDelay: const Duration(milliseconds: 5),
    );
    addTearDown(coordinator.close);

    await coordinator.start();
    await platform.endpointCommitted.future.timeout(const Duration(seconds: 1));
    platform.events.add(
      _messageEvent(
        id: 'activation-retry',
        content: <String, Object>{
          'activationToken': '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
        },
      ),
    );
    platform.eventsController.add(1);

    await firstActivationAttempt.future.timeout(const Duration(seconds: 1));
    expect(platform.acknowledgedEventIds, isNot(contains('activation-retry')));
    await secondActivationAttempt.future.timeout(
      const Duration(milliseconds: 250),
    );
    await _waitUntil(
      () => platform.acknowledgedEventIds.contains('activation-retry'),
    );

    expect(activationAttempts, 2);
  });

  test('invalid or undecrypted messages are terminally acknowledged', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    final credentials = MemoryCredentialVault()
      ..values['account-a'] = 'fixture-password';
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.active
      ..generation = 1
      ..events.add(
        AndroidWebPushEvent(
          id: 'bad-message',
          accountId: 'account-a',
          generation: 1,
          type: AndroidWebPushEventType.message,
          createdAt: DateTime.utc(2026),
          coalescedCount: 1,
          stale: false,
          content: Uint8List.fromList(utf8.encode('{"subject":"secret"}')),
          decrypted: false,
        ),
      );
    final api = HttpNextcloudApi(
      client: MockClient((_) async => http.Response('', 500)),
    );
    addTearDown(api.close);
    var wakeUps = 0;
    final coordinator = AndroidPushCoordinator(
      accounts: accounts,
      credentials: credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async => wakeUps++,
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(wakeUps, 0);
    expect(platform.acknowledgedEventIds, <String>['bad-message']);
  });

  test('retains activation until its endpoint generation is active', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final accounts = AccountRepository(database);
    const accountId = 'account-a';
    await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    final credentials = MemoryCredentialVault()
      ..values[accountId] = 'fixture-password';
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.registering
      ..generation = 1
      ..events.add(
        _messageEvent(
          id: 'early-activation',
          type: AndroidWebPushEventType.activation,
          content: <String, Object>{
            'activationToken': '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
          },
        ),
      );
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        fail('Activation must wait while registration is not active.');
      }),
    );
    addTearDown(api.close);
    final coordinator = AndroidPushCoordinator(
      accounts: accounts,
      credentials: credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      retryDelay: const Duration(hours: 1),
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount(accountId);

    expect(platform.acknowledgedEventIds, isNot(contains('early-activation')));
    expect(
      platform.events.map((event) => event.id),
      contains('early-activation'),
    );
  });

  for (final statusCode in <int>[401, 403]) {
    test('does not retry terminal activation HTTP $statusCode', () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform()
        ..phase = AndroidWebPushRegistrationPhase.active
        ..generation = 1
        ..events.add(
          _messageEvent(
            id: 'terminal-activation-$statusCode',
            type: AndroidWebPushEventType.activation,
            content: <String, Object>{
              'activationToken': '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
            },
          ),
        );
      var requests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((_) async {
          requests++;
          return http.Response('', statusCode);
        }),
      );
      addTearDown(api.close);
      final retryTimers = <_ManualRetryTimer>[];
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async {},
        createRetryTimer: (duration, callback) {
          final timer = _ManualRetryTimer(duration, callback);
          retryTimers.add(timer);
          return timer;
        },
      );
      addTearDown(coordinator.close);

      await expectLater(
        coordinator.drainAccount('account-a'),
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            statusCode,
          ),
        ),
      );

      expect(requests, 1);
      expect(retryTimers, isEmpty);
      expect(
        platform.acknowledgedEventIds,
        isNot(contains('terminal-activation-$statusCode')),
      );
    });
  }

  for (final statusCode in <int>[408, 429, 500, 599]) {
    test('retries transient activation HTTP $statusCode', () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform()
        ..phase = AndroidWebPushRegistrationPhase.active
        ..generation = 1
        ..events.add(
          _messageEvent(
            id: 'transient-activation-$statusCode',
            type: AndroidWebPushEventType.activation,
            content: <String, Object>{
              'activationToken': '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
            },
          ),
        );
      final api = HttpNextcloudApi(
        client: MockClient((_) async => http.Response('', statusCode)),
      );
      addTearDown(api.close);
      final retryTimers = <_ManualRetryTimer>[];
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async {},
        retryDelay: const Duration(seconds: 1),
        retryMaximumDelay: const Duration(seconds: 8),
        randomDouble: () => 0.5,
        createRetryTimer: (duration, callback) {
          final timer = _ManualRetryTimer(duration, callback);
          retryTimers.add(timer);
          return timer;
        },
      );
      addTearDown(coordinator.close);

      await expectLater(
        coordinator.drainAccount('account-a'),
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            statusCode,
          ),
        ),
      );

      expect(retryTimers, hasLength(1));
      expect(retryTimers.single.duration, const Duration(seconds: 1));
      expect(
        platform.acknowledgedEventIds,
        isNot(contains('transient-activation-$statusCode')),
      );
    });
  }
}
