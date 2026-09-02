part of 'android_push_coordinator_test.dart';

/// Leaving the Web Push transport has to take the server-side registration
/// with it. Nextcloud keys a push registration by device, so a subscription
/// left behind competes with the proxy registration that replaces it.
void _registerAndroidPushTransportHandoverTests() {
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
}
