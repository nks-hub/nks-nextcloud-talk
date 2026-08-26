part of 'android_push_coordinator_test.dart';

void _registerAndroidPushMultiServerTests() {
  test(
    'keeps registration and 401 cache invalidation isolated by server',
    () async {
      final fixture = await _createAccountsOnDistinctServers();
      final capabilityRequests = <String, int>{};
      final registrationRequests = <Uri>[];
      var rejectFirstVapid = false;
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            capabilityRequests.update(
              request.url.host,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
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
            if (rejectFirstVapid && request.url.host == _firstPushHost) {
              return http.Response('', 401);
            }
            return http.Response(
              jsonEncode(_ocs(<String, Object>{'vapid': 'B${'a' * 86}'})),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/webpush')) {
            registrationRequests.add(request.url);
            return http.Response(jsonEncode(_ocs(const <Object>[], 200)), 200);
          }
          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(api.close);
      final platform = _FakeAndroidWebPushPlatform()
        ..emitEndpointOnRegister = false
        ..events.addAll(<AndroidWebPushEvent>[
          _endpointEvent(id: 'endpoint-a', accountId: 'account-a'),
          _endpointEvent(id: 'endpoint-b', accountId: 'account-b'),
        ]);
      final wakeUps = <String>[];
      final coordinator = AndroidPushCoordinator(
        accounts: fixture.accounts,
        credentials: fixture.credentials,
        api: api,
        platform: platform,
        onWakeUp: (accountId) async => wakeUps.add(accountId),
      );
      addTearDown(coordinator.close);

      await coordinator.reconcileAccount('account-a');
      await coordinator.reconcileAccount('account-b');

      expect(registrationRequests.map((request) => request.host), <String>[
        _firstPushHost,
        _secondPushHost,
      ]);
      expect(registrationRequests[0].path, startsWith('/first/'));
      expect(registrationRequests[1].path, startsWith('/second/'));
      expect(platform.committedEventIds, <String>['endpoint-a', 'endpoint-b']);
      expect(
        platform.registrationStates['account-a']?.phase,
        AndroidWebPushRegistrationPhase.active,
      );
      expect(
        platform.registrationStates['account-b']?.phase,
        AndroidWebPushRegistrationPhase.active,
      );
      expect(capabilityRequests, <String, int>{
        _firstPushHost: 1,
        _secondPushHost: 1,
      });

      rejectFirstVapid = true;
      await expectLater(
        coordinator.reconcileAccount('account-a'),
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      await coordinator.reconcileAccount('account-b');

      expect(
        capabilityRequests[_secondPushHost],
        1,
        reason: 'the healthy server keeps its authenticated snapshot',
      );
      expect(
        platform.registrationStates['account-b']?.phase,
        AndroidWebPushRegistrationPhase.active,
      );
      expect(
        wakeUps.where((accountId) => accountId == 'account-b'),
        hasLength(2),
      );
    },
  );

  test('revoking one server preserves the other active generation', () async {
    final fixture = await _createAccountsOnDistinctServers();
    final requests = <http.Request>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/cloud/capabilities')) {
          final features = request.url.host == _firstPushHost
              ? const <String>['devices']
              : const <String>['webpush'];
          return http.Response(
            jsonEncode(capabilitiesJson(notificationPushFeatures: features)),
            200,
          );
        }
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/webpush')) {
          return http.Response(jsonEncode(_ocs(const <Object>[])), 200);
        }
        if (request.url.path.endsWith('/webpush/vapid')) {
          return http.Response(
            jsonEncode(_ocs(<String, Object>{'vapid': 'B${'a' * 86}'})),
            200,
          );
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..emitEndpointOnRegister = false
      ..registrationStates['account-a'] = const AndroidWebPushRegistrationState(
        generation: 2,
        nextGeneration: 3,
        phase: AndroidWebPushRegistrationPhase.active,
        pendingEventCount: 0,
      )
      ..registrationStates['account-b'] = const AndroidWebPushRegistrationState(
        generation: 7,
        nextGeneration: 8,
        phase: AndroidWebPushRegistrationPhase.active,
        pendingEventCount: 0,
      );
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
    );
    addTearDown(coordinator.close);

    await coordinator.reconcileAccount('account-a');
    await coordinator.reconcileAccount('account-b');

    expect(platform.preparedServerRevocations, <String>['account-a']);
    expect(platform.retiredServerRevocations, <Object>[
      (accountId: 'account-a', generation: 2),
    ]);
    expect(platform.registrationStates['account-a'], isNull);
    expect(platform.registrationStates['account-b']?.generation, 7);
    expect(
      platform.registrationStates['account-b']?.phase,
      AndroidWebPushRegistrationPhase.active,
    );
    expect(
      requests.where((request) => request.method == 'DELETE').single.url.host,
      _firstPushHost,
    );
    expect(
      await fixture.credentials.readAppPassword('account-b'),
      _sharedPushPassword,
    );
  });
}

const _firstPushHost = 'first.example.invalid';
const _secondPushHost = 'second.example.invalid';
const _sharedPushPassword = 'shared-password';

Future<({AccountRepository accounts, MemoryCredentialVault credentials})>
_createAccountsOnDistinctServers() async {
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  final credentials = MemoryCredentialVault();
  for (final account in <({String id, String serverUrl})>[
    (id: 'account-a', serverUrl: 'https://$_firstPushHost/first'),
    (id: 'account-b', serverUrl: 'https://$_secondPushHost/second'),
  ]) {
    await accounts.upsertAccount(
      accountId: account.id,
      serverUrl: account.serverUrl,
      loginName: 'shared-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    credentials.values[account.id] = _sharedPushPassword;
  }
  return (accounts: accounts, credentials: credentials);
}
