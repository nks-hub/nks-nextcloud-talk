part of 'android_push_coordinator_test.dart';

void _registerAndroidPushRetryRoutingTests() {
  for (final terminal in <({String name, Object error})>[
    (name: 'StateError', error: StateError('synthetic invariant failure')),
    (
      name: 'FormatException',
      error: const FormatException('synthetic protocol failure'),
    ),
    (
      name: 'PlatformException',
      error: PlatformException(code: 'synthetic_platform_failure'),
    ),
  ]) {
    test('does not retry terminal ${terminal.name}', () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform()
        ..drainFailure = terminal.error;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          fail('A terminal platform failure must not reach the server.');
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
        throwsA(same(terminal.error)),
      );

      expect(retryTimers, isEmpty);
    });
  }

  test(
    'backs off per account and resets after a successful operation',
    () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform();
      var requests = 0;
      var now = DateTime.utc(2026, 8, 25, 12);
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          expect(request.url.path, endsWith('/cloud/capabilities'));
          requests++;
          if (requests == 4) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          return http.Response('', 503);
        }),
        clock: () => now,
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
        retryMaximumDelay: const Duration(seconds: 4),
        randomDouble: () => 1,
        createRetryTimer: (duration, callback) {
          final timer = _ManualRetryTimer(duration, callback);
          retryTimers.add(timer);
          return timer;
        },
      );
      addTearDown(coordinator.close);

      await expectLater(
        coordinator.reconcileAccount('account-a'),
        throwsA(isA<NextcloudApiException>()),
      );
      expect(retryTimers.map((timer) => timer.duration), <Duration>[
        const Duration(milliseconds: 1200),
      ]);

      retryTimers[0].fire();
      await _waitUntil(() => retryTimers.length == 2);
      retryTimers[1].fire();
      await _waitUntil(() => retryTimers.length == 3);
      expect(retryTimers.map((timer) => timer.duration), <Duration>[
        const Duration(milliseconds: 1200),
        const Duration(milliseconds: 2400),
        const Duration(seconds: 4),
      ]);

      await coordinator.reconcileAccount('account-a');
      expect(retryTimers[2].isActive, isFalse);
      // The successful reconcile cached the snapshot; let it fall out of its
      // validity window so the next reconcile reaches the failing server again.
      now = now.add(const Duration(minutes: 6));
      await expectLater(
        coordinator.reconcileAccount('account-a'),
        throwsA(isA<NextcloudApiException>()),
      );

      expect(retryTimers.map((timer) => timer.duration), <Duration>[
        const Duration(milliseconds: 1200),
        const Duration(milliseconds: 2400),
        const Duration(seconds: 4),
        const Duration(milliseconds: 1200),
      ]);
    },
  );

  test('retries the explicit temporary platform event', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final platform = _FakeAndroidWebPushPlatform()
      ..events.add(
        AndroidWebPushEvent(
          id: 'temporary-unavailable',
          accountId: 'account-a',
          generation: 1,
          type: AndroidWebPushEventType.temporaryUnavailable,
          createdAt: DateTime.utc(2026),
          coalescedCount: 1,
          stale: false,
        ),
      );
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        fail('A drained temporary event must not reach the server directly.');
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
      retryDelay: const Duration(seconds: 1),
      retryMaximumDelay: const Duration(seconds: 4),
      randomDouble: () => 0.5,
      createRetryTimer: (duration, callback) {
        final timer = _ManualRetryTimer(duration, callback);
        retryTimers.add(timer);
        return timer;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(platform.acknowledgedEventIds, <String>['temporary-unavailable']);
    expect(retryTimers, hasLength(1));
    expect(retryTimers.single.duration, const Duration(seconds: 1));
    expect(retryTimers.single.isActive, isTrue);
  });

  test('repeated registration failures use bounded account backoff', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.registering
      ..generation = 1
      ..emitEndpointOnRegister = false
      ..events.add(
        _platformEvent(
          id: 'registration-failed-1',
          type: AndroidWebPushEventType.registrationFailed,
        ),
      );
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
        fail('Unexpected request: ${request.method} ${request.url.path}');
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
      retryDelay: const Duration(seconds: 1),
      retryMaximumDelay: const Duration(seconds: 4),
      randomDouble: () => 0.5,
      createRetryTimer: (duration, callback) {
        final timer = _ManualRetryTimer(duration, callback);
        retryTimers.add(timer);
        return timer;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');
    expect(retryTimers.map((timer) => timer.duration), <Duration>[
      const Duration(seconds: 1),
    ]);

    platform.events.add(
      _platformEvent(
        id: 'registration-failed-2',
        type: AndroidWebPushEventType.registrationFailed,
      ),
    );
    retryTimers[0].fire();
    await _waitUntil(() => retryTimers.length == 2);
    expect(retryTimers.map((timer) => timer.duration), <Duration>[
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]);

    platform.events.add(
      _platformEvent(
        id: 'registration-failed-3',
        type: AndroidWebPushEventType.registrationFailed,
      ),
    );
    retryTimers[1].fire();
    await _waitUntil(() => retryTimers.length == 3);

    expect(retryTimers.map((timer) => timer.duration), <Duration>[
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
    ]);
    expect(platform.acknowledgedEventIds, <String>[
      'registration-failed-1',
      'registration-failed-2',
      'registration-failed-3',
    ]);
  });

  test(
    'unregistered event keeps one immediate next-generation retry',
    () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform()
        ..phase = AndroidWebPushRegistrationPhase.unregistered
        ..generation = 1
        ..emitEndpointOnRegister = false
        ..events.add(
          _platformEvent(
            id: 'unregistered-1',
            type: AndroidWebPushEventType.unregistered,
          ),
        );
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
          fail('Unexpected request: ${request.method} ${request.url.path}');
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
        retryDelay: const Duration(seconds: 1),
        randomDouble: () => 0.5,
        createRetryTimer: (duration, callback) {
          final timer = _ManualRetryTimer(duration, callback);
          retryTimers.add(timer);
          return timer;
        },
      );
      addTearDown(coordinator.close);

      await coordinator.drainAccount('account-a');

      expect(platform.acknowledgedEventIds, <String>['unregistered-1']);
      expect(retryTimers, hasLength(1));
      expect(retryTimers.single.duration, Duration.zero);

      retryTimers.single.fire();
      await _waitUntil(() => platform.registrations.isNotEmpty);

      expect(platform.registrations, <({String accountId, int generation})>[
        (accountId: 'account-a', generation: 2),
      ]);
      expect(retryTimers, hasLength(1));
    },
  );

  test(
    'commits an idempotent 200 after a lost registration response',
    () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform();
      var registrationAttempts = 0;
      final firstLostResponse = Completer<void>();
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
          if (request.url.path.endsWith('/webpush')) {
            registrationAttempts++;
            if (registrationAttempts == 1) {
              firstLostResponse.complete();
              throw http.ClientException('synthetic lost response');
            }
            return http.Response(jsonEncode(_ocs(const <Object>[], 200)), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );
      addTearDown(api.close);
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async {},
        retryDelay: const Duration(milliseconds: 5),
      );
      addTearDown(coordinator.close);

      await coordinator.start();
      await firstLostResponse.future.timeout(const Duration(seconds: 1));
      await platform.endpointCommitted.future.timeout(
        const Duration(seconds: 1),
      );
      await _waitUntil(
        () => platform.acknowledgedEventIds.contains('endpoint-1'),
      );

      expect(registrationAttempts, 2);
      expect(platform.phase, AndroidWebPushRegistrationPhase.active);
      expect(platform.acknowledgedEventIds, contains('endpoint-1'));
    },
  );

  test(
    'retries registering activation after endpoint commit then acks',
    () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform()
        ..phase = AndroidWebPushRegistrationPhase.registering
        ..generation = 1
        ..events.addAll(<AndroidWebPushEvent>[
          _messageEvent(
            id: 'activation-before-endpoint',
            type: AndroidWebPushEventType.activation,
            content: <String, Object>{
              'activationToken': '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
            },
          ),
          _endpointEvent(id: 'endpoint-after-activation'),
        ]);
      final paths = <String>[];
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          paths.add(request.url.path);
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
            return http.Response(jsonEncode(_ocs(const <Object>[], 202)), 202);
          }
          if (request.url.path.endsWith('/webpush')) {
            return http.Response(jsonEncode(_ocs(const <Object>[], 201)), 201);
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );
      addTearDown(api.close);
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async {},
        retryDelay: const Duration(milliseconds: 5),
      );
      addTearDown(coordinator.close);

      await coordinator.drainAccount('account-a');
      expect(
        platform.acknowledgedEventIds,
        contains('endpoint-after-activation'),
      );
      expect(
        platform.acknowledgedEventIds,
        isNot(contains('activation-before-endpoint')),
      );
      await _waitUntil(
        () => platform.acknowledgedEventIds.contains(
          'activation-before-endpoint',
        ),
      );

      final endpointIndex = paths.indexWhere(
        (path) => path.endsWith('/webpush'),
      );
      final activationIndex = paths.indexWhere(
        (path) => path.endsWith('/webpush/activate'),
      );
      expect(endpointIndex, greaterThanOrEqualTo(0));
      expect(activationIndex, greaterThan(endpointIndex));
      expect(platform.registrations, isNotEmpty);
    },
  );

  test('acks an activation from a stale generation without retry', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.active
      ..generation = 2
      ..events.add(
        _messageEvent(
          id: 'stale-generation-activation',
          generation: 1,
          type: AndroidWebPushEventType.activation,
          content: <String, Object>{
            'activationToken': '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc',
          },
        ),
      );
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        fail('A stale activation must not reach the server.');
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

    await coordinator.drainAccount('account-a');

    expect(
      platform.acknowledgedEventIds,
      contains('stale-generation-activation'),
    );
    expect(platform.events, isEmpty);
    expect(retryTimers, isEmpty);
  });

  test('keeps a transient retry isolated from another account', () async {
    final fixture = await _createAccounts(const <String>[
      'account-a',
      'account-b',
    ]);
    const activationToken = '9f9bcfc4-93db-4f23-a8f4-5f2403f722cc';
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.active
      ..generation = 1
      ..events.addAll(<AndroidWebPushEvent>[
        _messageEvent(
          id: 'account-a-activation',
          accountId: 'account-a',
          type: AndroidWebPushEventType.activation,
          content: const <String, Object>{'activationToken': activationToken},
        ),
        _messageEvent(
          id: 'account-b-message',
          accountId: 'account-b',
          content: const <String, Object>{
            'nid': 7,
            'app': 'spreed',
            'subject': 'Talk activity',
          },
        ),
      ]);
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
            return http.Response('', 503);
          }
          return http.Response(jsonEncode(_ocs(const <Object>[], 202)), 202);
        }
        if (request.url.path.endsWith('/webpush')) {
          return http.Response(jsonEncode(_ocs(const <Object>[], 200)), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(api.close);
    final wakeUps = <String>[];
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (accountId) async => wakeUps.add(accountId),
      retryDelay: const Duration(milliseconds: 100),
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.drainAccount('account-a'),
      throwsA(isA<NextcloudApiException>()),
    );
    await coordinator.drainAccount('account-b');

    expect(wakeUps, <String>['account-b']);
    expect(platform.acknowledgedEventIds, contains('account-b-message'));
    expect(
      platform.acknowledgedEventIds,
      isNot(contains('account-a-activation')),
    );
    await _waitUntil(
      () => platform.acknowledgedEventIds.contains('account-a-activation'),
    );
    expect(
      platform.registrations.map((registration) => registration.accountId),
      everyElement('account-a'),
    );
  });

  test(
    'replays a cold-start notification open without exposing content',
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
      final platform = _FakeAndroidWebPushPlatform()
        ..launchNotification = const AndroidNotificationOpen(
          accountId: 'account-a',
          notificationId: 8,
          app: 'spreed',
          type: 'chat',
          objectId: 'room-a',
        );
      final wakeUps = <String>[];
      final coordinator = AndroidPushCoordinator(
        accounts: accounts,
        credentials: credentials,
        api: api,
        platform: platform,
        onWakeUp: (accountId) async => wakeUps.add(accountId),
      );
      addTearDown(coordinator.close);

      await coordinator.start();

      final open = coordinator.takeNextNotificationOpen();
      expect(open?.accountId, 'account-a');
      expect(open?.objectId, 'room-a');
      expect(wakeUps, <String>['account-a']);
    },
  );
}
