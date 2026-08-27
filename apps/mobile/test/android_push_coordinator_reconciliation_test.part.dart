part of 'android_push_coordinator_test.dart';

void _registerAndroidPushReconciliationTests() {
  test('an explicit follow-up reconcile survives an in-flight run', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final firstRequestStarted = Completer<void>();
    final releaseFirstRequest = Completer<void>();
    var vapidRequests = 0;
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
          vapidRequests++;
          if (vapidRequests == 1) {
            firstRequestStarted.complete();
            await releaseFirstRequest.future;
          }
          return http.Response(
            jsonEncode(_ocs(<String, Object>{'vapid': 'B${'a' * 86}'})),
            200,
          );
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
      platform: _FakeAndroidWebPushPlatform(),
      onWakeUp: (_) async {},
    );
    addTearDown(coordinator.close);

    final first = coordinator.reconcileAll();
    await firstRequestStarted.future;
    final followUp = coordinator.reconcileAllAfterCurrent();
    releaseFirstRequest.complete();
    await Future.wait([first, followUp]);

    expect(vapidRequests, 2);
  });

  test(
    'coalesces periodic, resume and connectivity reconciliation signals',
    () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform();
      final wakeEvents = StreamController<void>.broadcast(sync: true);
      addTearDown(wakeEvents.close);
      var vapidRequests = 0;
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
            vapidRequests++;
            return http.Response(
              jsonEncode(_ocs(<String, Object>{'vapid': 'B${'a' * 86}'})),
              200,
            );
          }
          if (request.url.path.endsWith('/webpush')) {
            return http.Response(jsonEncode(_ocs(const <Object>[], 201)), 201);
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );
      addTearDown(api.close);
      final periodicTimers = <_ManualPeriodicTimer>[];
      final secondCatchUpStarted = Completer<void>();
      final releaseSecondCatchUp = Completer<void>();
      var catchUps = 0;
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        reconciliationWakeEvents: <Stream<void>>[wakeEvents.stream],
        onWakeUp: (_) async {
          catchUps++;
          if (catchUps == 2) {
            secondCatchUpStarted.complete();
            await releaseSecondCatchUp.future;
          }
        },
        reconciliationInterval: const Duration(hours: 3),
        createPeriodicTimer: (duration, callback) {
          final timer = _ManualPeriodicTimer(duration, callback);
          periodicTimers.add(timer);
          return timer;
        },
      );
      addTearDown(coordinator.close);

      await coordinator.start();
      await coordinator.reconcileAll();

      expect(catchUps, 1);
      expect(vapidRequests, 1);
      expect(periodicTimers, hasLength(1));
      expect(periodicTimers.single.duration, const Duration(hours: 3));

      periodicTimers.single.fire();
      final joinedReconciliation = coordinator.reconcileAll();
      wakeEvents.add(null);
      periodicTimers.single.fire();
      await secondCatchUpStarted.future;

      expect(catchUps, 2);
      releaseSecondCatchUp.complete();
      await joinedReconciliation;
      await Future<void>.delayed(Duration.zero);

      expect(catchUps, 2);
      expect(vapidRequests, 2);

      await coordinator.close();
      expect(periodicTimers.single.isActive, isFalse);
      wakeEvents.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(catchUps, 2);
    },
  );

  test(
    'suspending an account drains its flight and blocks stale work',
    () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform();
      final capabilitiesStarted = Completer<void>();
      final releaseCapabilities = Completer<void>();
      var capabilityRequests = 0;
      var vapidRequests = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests++;
            capabilitiesStarted.complete();
            await releaseCapabilities.future;
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
            vapidRequests++;
            return http.Response(
              jsonEncode(_ocs(<String, Object>{'vapid': 'B${'a' * 86}'})),
              200,
            );
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );
      addTearDown(api.close);
      var catchUps = 0;
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async => catchUps++,
      );
      addTearDown(coordinator.close);

      final reconciliation = coordinator.reconcileAccount('account-a');
      await capabilitiesStarted.future;
      final suspension = coordinator.suspendAccount('account-a');
      await coordinator.reconcileAccount('account-a');
      releaseCapabilities.complete();
      await Future.wait(<Future<void>>[reconciliation, suspension]);

      expect(capabilityRequests, 1);
      expect(vapidRequests, 0);
      expect(platform.registrations, isEmpty);
      expect(catchUps, 0);

      await coordinator.reconcileAccount('account-a');
      expect(capabilityRequests, 1);
    },
  );

  test('suspension survives a coordinator start already in flight', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final availability = Completer<AndroidWebPushAvailability>();
    final platform = _FakeAndroidWebPushPlatform()
      ..availabilityFuture = availability.future;
    var capabilityRequests = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          capabilityRequests++;
          return http.Response(jsonEncode(capabilitiesJson()), 200);
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
    );
    addTearDown(coordinator.close);

    final start = coordinator.start();
    await coordinator.suspendAccount('account-a');
    availability.complete(
      const AndroidWebPushAvailability(
        available: true,
        playServicesAvailable: true,
      ),
    );
    await start;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(capabilityRequests, 0);
    expect(platform.registrations, isEmpty);
  });

  test(
    'suspension drains an open catch-up and removes its stale route',
    () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final platform = _FakeAndroidWebPushPlatform();
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
            return http.Response(jsonEncode(_ocs(const <Object>[], 201)), 201);
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );
      addTearDown(api.close);
      final openCatchUpStarted = Completer<void>();
      final releaseOpenCatchUp = Completer<void>();
      var catchUps = 0;
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async {
          catchUps++;
          if (catchUps == 2) {
            openCatchUpStarted.complete();
            await releaseOpenCatchUp.future;
          }
        },
      );
      addTearDown(coordinator.close);

      await coordinator.start();
      await _waitUntil(() => catchUps == 1);
      platform.openController.add(
        const AndroidNotificationOpen(
          accountId: 'account-a',
          notificationId: 8,
          app: 'spreed',
          type: 'chat',
          objectId: 'room-a',
        ),
      );
      await openCatchUpStarted.future;

      var suspensionCompleted = false;
      final suspension = coordinator
          .suspendAccount('account-a')
          .whenComplete(() => suspensionCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(suspensionCompleted, isFalse);
      expect(coordinator.takeNextNotificationOpen(), isNull);

      releaseOpenCatchUp.complete();
      await suspension;
      expect(suspensionCompleted, isTrue);
    },
  );

  test('bounds retry when the OCS catch-up fails transiently', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final platform = _FakeAndroidWebPushPlatform()
      ..emitEndpointOnRegister = false;
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
    final transientFailure = StateError('synthetic catch-up outage');
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async => throw transientFailure,
      retryableError: (error) => identical(error, transientFailure),
      randomDouble: () => 0.5,
      createRetryTimer: (duration, callback) {
        final timer = _ManualRetryTimer(duration, callback);
        retryTimers.add(timer);
        return timer;
      },
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.reconcileAccount('account-a'),
      throwsA(same(transientFailure)),
    );

    expect(retryTimers, hasLength(1));
    expect(retryTimers.single.duration, const Duration(seconds: 30));
    expect(retryTimers.single.isActive, isTrue);
  });

  test('a synced account row rewrite does not re-register push', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final platform = _FakeAndroidWebPushPlatform();
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
          return http.Response(jsonEncode(_ocs(const <Object>[], 201)), 201);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(api.close);
    var catchUps = 0;
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (accountId) async {
        catchUps++;
        // Mirrors ConversationSyncService, which stores the observed Talk
        // features on every catch-up and therefore rewrites the account row.
        await fixture.accounts.updateTalkFeatures(accountId, <String>{
          'chat-v2',
          'threads',
        });
      },
    );
    addTearDown(coordinator.close);

    await coordinator.start();
    await _settle(() => platform.registrations.isNotEmpty);

    expect(platform.registrations, hasLength(1));
    expect(catchUps, 1);
  });

  test('changed push identity of a known account reconciles again', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final platform = _FakeAndroidWebPushPlatform();
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
    );
    addTearDown(coordinator.close);

    await coordinator.start();
    await _settle(() => platform.registrations.isNotEmpty);
    expect(platform.registrations, hasLength(1));

    await fixture.accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://other.example.invalid',
      loginName: 'fixture-account-a',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    await _settle(() => platform.registrations.length >= 2);

    expect(platform.registrations, hasLength(2));
  });
}

/// Waits until [reached] holds and then keeps pumping for a bounded tail, so a
/// runaway reconcile loop shows up as extra work instead of hanging the test.
Future<void> _settle(bool Function() reached) async {
  for (var attempt = 0; attempt < 200 && !reached(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  for (var tail = 0; tail < 40; tail++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
