import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/push/android_push_coordinator.dart';
import 'package:nextcloudtalk/features/push/android_web_push_bridge.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
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

      expect(wakeUps, <String>[accountId]);
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
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          expect(request.url.path, endsWith('/cloud/capabilities'));
          requests++;
          if (requests == 4) {
            return http.Response(jsonEncode(capabilitiesJson()), 200);
          }
          return http.Response('', 503);
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

AndroidWebPushEvent _messageEvent({
  required String id,
  required Map<String, Object> content,
  String accountId = 'account-a',
  int generation = 1,
  AndroidWebPushEventType type = AndroidWebPushEventType.message,
}) {
  return AndroidWebPushEvent(
    id: id,
    accountId: accountId,
    generation: generation,
    type: type,
    createdAt: DateTime.utc(2026),
    coalescedCount: 1,
    stale: false,
    content: Uint8List.fromList(utf8.encode(jsonEncode(content))),
    decrypted: true,
  );
}

AndroidWebPushEvent _endpointEvent({
  required String id,
  String accountId = 'account-a',
  int generation = 1,
}) {
  return AndroidWebPushEvent(
    id: id,
    accountId: accountId,
    generation: generation,
    type: AndroidWebPushEventType.endpoint,
    createdAt: DateTime.utc(2026),
    coalescedCount: 1,
    stale: false,
    endpoint: AndroidWebPushEndpoint(
      url: 'https://push.example.invalid/subscription',
      temporary: false,
      publicKey: 'B${'b' * 86}',
      authSecret: 'c' * 22,
    ),
  );
}

Future<({AccountRepository accounts, MemoryCredentialVault credentials})>
_createAccounts(List<String> accountIds) async {
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  final credentials = MemoryCredentialVault();
  for (final accountId in accountIds) {
    await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-$accountId',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    credentials.values[accountId] = 'fixture-password';
  }
  return (accounts: accounts, credentials: credentials);
}

Map<String, Object?> _ocs(Object? data, [int statusCode = 200]) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': statusCode,
        'message': 'OK',
      },
      'data': data,
    },
  };
}

final class _FakeAndroidWebPushPlatform implements AndroidWebPushPlatform {
  final eventsController = StreamController<int>.broadcast();
  final openController = StreamController<AndroidNotificationOpen>.broadcast();
  final events = <AndroidWebPushEvent>[];
  final registrations = <({String accountId, int generation})>[];
  final committedEventIds = <String>[];
  final acknowledgedEventIds = <String>[];
  final endpointCommitted = Completer<void>();
  AndroidWebPushRegistrationPhase? phase;
  int? generation;
  Object? drainFailure;
  AndroidNotificationOpen? launchNotification;
  var permission = AndroidNotificationPermission.notDetermined;
  var permissionRequests = 0;

  @override
  Stream<int> get eventsAvailable => eventsController.stream;

  @override
  Stream<AndroidNotificationOpen> get notificationOpened =>
      openController.stream;

  @override
  Future<AndroidWebPushAvailability> getAvailability() async {
    return const AndroidWebPushAvailability(
      available: true,
      playServicesAvailable: true,
    );
  }

  @override
  Future<AndroidWebPushRegistrationState> getRegistrationState({
    required String accountId,
  }) async {
    return AndroidWebPushRegistrationState(
      generation: generation,
      nextGeneration: (generation ?? 0) + 1,
      phase: phase,
      pendingEventCount: events.length,
    );
  }

  @override
  Future<AndroidNotificationPermission> getNotificationPermission() async {
    return permission;
  }

  @override
  Future<AndroidNotificationPermission> requestNotificationPermission() async {
    permissionRequests++;
    return permission = AndroidNotificationPermission.granted;
  }

  @override
  Future<AndroidNotificationOpen?> getLaunchNotification() async {
    final result = launchNotification;
    launchNotification = null;
    return result;
  }

  @override
  Future<AndroidWebPushRegistrationResult> register({
    required String accountId,
    required int generation,
    required String vapidPublicKey,
  }) async {
    final existingActiveRegistration =
        this.generation == generation &&
        phase == AndroidWebPushRegistrationPhase.active;
    registrations.add((accountId: accountId, generation: generation));
    this.generation = generation;
    if (!existingActiveRegistration) {
      phase = AndroidWebPushRegistrationPhase.registering;
    }
    if (events
        .where((event) => event.type == AndroidWebPushEventType.endpoint)
        .isEmpty) {
      events.add(
        AndroidWebPushEvent(
          id: 'endpoint-1',
          accountId: accountId,
          generation: generation,
          type: AndroidWebPushEventType.endpoint,
          createdAt: DateTime.utc(2026),
          coalescedCount: 1,
          stale: false,
          endpoint: AndroidWebPushEndpoint(
            url: 'https://push.example.invalid/subscription',
            temporary: false,
            publicKey: 'B${'b' * 86}',
            authSecret: 'c' * 22,
          ),
        ),
      );
    }
    return AndroidWebPushRegistrationResult(
      generation: generation,
      status: AndroidWebPushRegistrationStatus.created,
    );
  }

  @override
  Future<AndroidWebPushCommitResult> commitEndpoint({
    required String accountId,
    required int generation,
    required String eventId,
  }) async {
    committedEventIds.add(eventId);
    phase = AndroidWebPushRegistrationPhase.active;
    if (!endpointCommitted.isCompleted) {
      endpointCommitted.complete();
    }
    return const AndroidWebPushCommitResult(serverRevokeGenerations: <int>[]);
  }

  @override
  Future<int> retireAfterServerRevocation({
    required String accountId,
    required int generation,
  }) async => 1;

  @override
  Future<int> pendingEventCount({required String accountId}) async {
    return events.length;
  }

  @override
  Future<List<AndroidWebPushEvent>> drainEvents({
    required String accountId,
    int limit = 50,
  }) async {
    final failure = drainFailure;
    if (failure != null) {
      throw failure;
    }
    return events
        .where((event) => event.accountId == accountId)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<int> acknowledge({
    required String accountId,
    required Iterable<String> eventIds,
  }) async {
    final ids = eventIds.toSet();
    acknowledgedEventIds.addAll(ids);
    final before = events.length;
    events.removeWhere(
      (event) => event.accountId == accountId && ids.contains(event.id),
    );
    return before - events.length;
  }

  @override
  Future<void> dispose() async {
    await eventsController.close();
    await openController.close();
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

final class _ManualRetryTimer implements Timer {
  _ManualRetryTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  var _active = true;
  var _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  void fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _tick = 1;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
  }
}
