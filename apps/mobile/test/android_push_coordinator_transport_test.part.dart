part of 'android_push_coordinator_test.dart';

/// Leaving the Web Push transport has to take the server-side registration
/// with it. Nextcloud keys a push registration by device, so a subscription
/// left behind competes with the proxy registration that replaces it.
void _registerAndroidPushTransportHandoverTests() {
  test(
    'failed overlapping revocation restores Web Push after every worker',
    () async {
      final fixture = await _createAccounts(const <String>[
        'account-a',
        'account-b',
      ]);
      final bothDeletesStarted = Completer<void>();
      final releaseDeletes = Completer<void>();
      final deletingAccounts = <String>{};
      var activeDeletes = 0;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.method == 'DELETE' &&
              request.url.path.endsWith('/webpush')) {
            final authorization = request.headers['authorization']!;
            final login = utf8
                .decode(base64Decode(authorization.substring('Basic '.length)))
                .split(':')
                .first;
            final accountId = login.replaceFirst('fixture-', '');
            deletingAccounts.add(accountId);
            activeDeletes++;
            if (deletingAccounts.length == 2 &&
                !bothDeletesStarted.isCompleted) {
              bothDeletesStarted.complete();
            }
            await releaseDeletes.future;
            activeDeletes--;
            if (accountId == 'account-b') {
              return http.Response('', 503);
            }
            return http.Response(jsonEncode(_ocs(const <Object>[], 200)), 200);
          }
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
      addTearDown(() {
        if (!releaseDeletes.isCompleted) {
          releaseDeletes.complete();
        }
      });
      final platform = _FakeAndroidWebPushPlatform()
        ..phase = AndroidWebPushRegistrationPhase.active
        ..generation = 1
        ..emitEndpointOnRegister = false;
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (_) async {},
      );
      addTearDown(coordinator.close);
      final store = _MemoryAndroidPushTransportStore(
        AndroidPushTransport.webPush,
      );
      var restoreCalls = 0;
      int? activeDeletesAtRestore;
      bool? accountARetiredAtRestore;
      final transportSwitch = AndroidPushTransportSwitch(
        store: store,
        revoke: (_) => coordinator.revokeAllRegistrations(),
        restore: (_) async {
          restoreCalls++;
          activeDeletesAtRestore = activeDeletes;
          accountARetiredAtRestore = platform.retiredServerRevocations.contains(
            (accountId: 'account-a', generation: 1),
          );
          coordinator.subscribes = true;
          await coordinator.reconcileAllAfterCurrent();
        },
      );

      final switching = transportSwitch.select(
        AndroidPushTransport.proxy,
        current: AndroidPushTransport.webPush,
      );
      final failure = expectLater(
        switching,
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
      await bothDeletesStarted.future.timeout(const Duration(seconds: 2));
      expect(coordinator.subscribes, isFalse);
      expect(deletingAccounts, <String>{'account-a', 'account-b'});
      releaseDeletes.complete();
      await failure;

      expect(store.stored, AndroidPushTransport.webPush);
      expect(restoreCalls, 1);
      expect(activeDeletesAtRestore, 0);
      expect(accountARetiredAtRestore, isTrue);
      expect(coordinator.subscribes, isTrue);
      expect(
        platform.registrations.map((registration) => registration.accountId),
        containsAll(<String>['account-a', 'account-b']),
      );
    },
  );

  test('revoking for a transport switch clears every account', () async {
    final fixture = await _createAccounts(const <String>[
      'account-a',
      'account-b',
    ]);
    final requests = <http.Request>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/webpush')) {
          return http.Response(jsonEncode(_ocs(const <Object>[], 200)), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.active
      ..generation = 1;
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
    );
    addTearDown(coordinator.close);

    await coordinator.revokeAllRegistrations();

    // `watchAccounts` does not promise an order, only that every account is
    // in there exactly once.
    expect(platform.preparedServerRevocations, hasLength(2));
    expect(platform.preparedServerRevocations.toSet(), <String>{
      'account-a',
      'account-b',
    });
    expect(platform.retiredServerRevocations.toSet(), <Object>{
      (accountId: 'account-a', generation: 1),
      (accountId: 'account-b', generation: 1),
    });
    expect(
      requests.where((request) => request.method == 'DELETE'),
      hasLength(2),
    );
  });

  test('transport switch bounds concurrent account revocations', () async {
    final fixture = await _createAccounts(const <String>[
      'account-a',
      'account-b',
      'account-c',
      'account-d',
      'account-e',
      'account-f',
    ]);
    final gates = <Completer<void>>[];
    final firstBatchStarted = Completer<void>();
    var inFlight = 0;
    var peakInFlight = 0;
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/webpush')) {
          final gate = Completer<void>();
          gates.add(gate);
          inFlight++;
          if (inFlight > peakInFlight) {
            peakInFlight = inFlight;
          }
          if (gates.length == 4) {
            firstBatchStarted.complete();
          }
          await gate.future;
          inFlight--;
          return http.Response(jsonEncode(_ocs(const <Object>[], 200)), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.active
      ..generation = 1;
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
    );
    addTearDown(coordinator.close);

    Future<void> releaseAll() async {
      for (var turn = 0; turn < 100 && gates.length < 6; turn++) {
        for (final gate in gates) {
          if (!gate.isCompleted) {
            gate.complete();
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      for (final gate in gates) {
        if (!gate.isCompleted) {
          gate.complete();
        }
      }
    }

    Future<void>? pendingRevocation;
    addTearDown(() async {
      if (pendingRevocation != null) {
        await releaseAll();
        await pendingRevocation;
      }
    });

    final revoking = coordinator.revokeAllRegistrations();
    pendingRevocation = revoking;
    await firstBatchStarted.future.timeout(const Duration(seconds: 2));
    expect(gates, hasLength(4));
    expect(peakInFlight, 4);

    gates.first.complete();
    for (var turn = 0; turn < 50 && gates.length < 5; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gates, hasLength(5));
    expect(peakInFlight, 4);

    await releaseAll();
    await revoking;
    expect(gates, hasLength(6));
    expect(platform.retiredServerRevocations, hasLength(6));
  });

  test('a revoked account does not register itself again', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/webpush')) {
          return http.Response(jsonEncode(_ocs(const <Object>[], 200)), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.active
      ..generation = 1;
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
    );
    addTearDown(coordinator.close);

    await coordinator.revokeAllRegistrations();
    // A wake event or the periodic timer can still fire between the
    // revocation and the coordinator being torn down.
    await coordinator.reconcileAccount('account-a');

    expect(platform.registrations, isEmpty);
  });

  test(
    'the proxy transport keeps taps and actions but stops subscribing',
    () async {
      final fixture = await _createAccounts(const <String>['account-a']);
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );
      addTearDown(api.close);
      final platform = _FakeAndroidWebPushPlatform();
      final drained = <String>[];
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        subscribes: false,
        onWakeUp: (_) async {},
        onNotificationAction: (action) async {
          drained.add(action.id);
          return AndroidPushActionOutcome.completed;
        },
      );
      addTearDown(coordinator.close);
      platform.notificationActions.add(
        _markReadAction(
          id: 'action-1',
          accountId: 'account-a',
          room: 'roomtok1',
        ),
      );

      await coordinator.reconcileAccount('account-a');

      // No capabilities read, no VAPID, no register — the MockClient would have
      // failed the test. The reply the user typed still gets run.
      expect(platform.registrations, isEmpty);
      expect(drained, <String>['action-1']);
    },
  );

  test('a failed revocation is reported, not swallowed', () async {
    final fixture = await _createAccounts(const <String>['account-a']);
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/webpush')) {
          return http.Response('', 503);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.active
      ..generation = 1;
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
    );
    addTearDown(coordinator.close);

    await expectLater(
      coordinator.revokeAllRegistrations(),
      throwsA(isA<NextcloudApiException>()),
    );
    expect(platform.retiredServerRevocations, isEmpty);
  });

  test('removing an account gives up its Web Push registration', () async {
    final fixture = await _createAccounts(const <String>[
      'account-a',
      'account-b',
    ]);
    final requests = <http.Request>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/webpush')) {
          return http.Response(jsonEncode(_ocs(const <Object>[], 200)), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..phase = AndroidWebPushRegistrationPhase.active
      ..generation = 1;
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
    );
    addTearDown(coordinator.close);

    // The order account removal uses: stop the account first, so nothing
    // re-registers behind the revocation, and only then give the
    // registration up. Suspending alone used to be the whole story, which
    // left the device registered for an account that no longer existed.
    await coordinator.suspendAccount('account-a');
    expect(await coordinator.revokeAccount('account-a'), isTrue);

    expect(platform.preparedServerRevocations, <String>['account-a']);
    expect(platform.retiredServerRevocations, <Object>[
      (accountId: 'account-a', generation: 1),
    ]);
    expect(
      requests.where((request) => request.method == 'DELETE'),
      hasLength(1),
    );
  });
}

final class _MemoryAndroidPushTransportStore
    implements AndroidPushTransportStore {
  _MemoryAndroidPushTransportStore(this.stored);

  AndroidPushTransport stored;

  @override
  Future<AndroidPushTransport> read() async => stored;

  @override
  Future<void> write(AndroidPushTransport transport) async {
    stored = transport;
  }
}
