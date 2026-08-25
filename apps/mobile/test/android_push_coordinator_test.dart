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

  test('runs notification actions only inside their own account', () async {
    final fixture = await _createAccounts(<String>['account-a', 'account-b']);
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..notificationActions.addAll(<AndroidNotificationAction>[
        _replyAction(id: 'action-a', accountId: 'account-a', room: 'rooma'),
        _replyAction(id: 'action-b', accountId: 'account-b', room: 'roomb'),
        _markReadAction(id: 'action-c', accountId: 'account-b', room: 'roomb'),
      ]);
    final handled = <AndroidNotificationAction>[];
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (action) async {
        handled.add(action);
        return AndroidPushActionOutcome.completed;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-b');

    expect(
      handled.map((action) => action.id),
      <String>['action-b', 'action-c'],
      reason: 'account-a work must not run while draining account-b',
    );
    expect(handled.every((action) => action.accountId == 'account-b'), isTrue);
    expect(handled.first.replyText, 'notification reply');
    expect(handled.last.kind, AndroidNotificationActionKind.markRead);
    expect(
      platform.resolvedActions
          .map((resolved) => resolved.outcome)
          .toSet()
          .single,
      AndroidNotificationActionOutcome.completed,
    );
    expect(
      platform.notificationActions.map((action) => action.id),
      <String>['action-a'],
    );
  });

  test('keeps a retryable notification action queued and retries', () async {
    final fixture = await _createAccounts(<String>['account-a']);
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..notificationActions.add(
        _replyAction(id: 'action-a', accountId: 'account-a', room: 'rooma'),
      );
    final timers = <_ManualRetryTimer>[];
    var attempts = 0;
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (_) async {
        attempts++;
        return attempts == 1
            ? AndroidPushActionOutcome.retry
            : AndroidPushActionOutcome.completed;
      },
      randomDouble: () => 0.5,
      createRetryTimer: (duration, callback) {
        final timer = _ManualRetryTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(attempts, 1);
    expect(platform.resolvedActions, isEmpty);
    expect(platform.notificationActions, hasLength(1));
    expect(timers, hasLength(1));

    timers.single.fire();
    await _waitUntil(() => platform.resolvedActions.isNotEmpty);

    expect(attempts, 2);
    expect(
      platform.resolvedActions.single.outcome,
      AndroidNotificationActionOutcome.completed,
    );
    expect(platform.notificationActions, isEmpty);
  });

  test('reports a deterministic action failure instead of dropping it', () async {
    final fixture = await _createAccounts(<String>['account-a']);
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..notificationActions.add(
        _replyAction(id: 'action-a', accountId: 'account-a', room: 'rooma'),
      );
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (_) async => AndroidPushActionOutcome.failed,
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(
      platform.resolvedActions.single.outcome,
      AndroidNotificationActionOutcome.failed,
    );
    expect(platform.notificationActions, isEmpty);
  });

  test('answers queued actions of an account without a credential', () async {
    final fixture = await _createAccounts(<String>['account-a']);
    fixture.credentials.values.remove('account-a');
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _FakeAndroidWebPushPlatform()
      ..notificationActions.add(
        _replyAction(id: 'action-a', accountId: 'account-a', room: 'rooma'),
      );
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (_) async => AndroidPushActionOutcome.failed,
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(
      platform.resolvedActions.single.outcome,
      AndroidNotificationActionOutcome.failed,
    );
  });

  test('rejects a stored action that names a foreign account', () async {
    final fixture = await _createAccounts(<String>['account-a']);
    final api = _capabilityApi();
    addTearDown(api.close);
    final platform = _ForeignActionPlatform()
      ..notificationActions.add(
        _replyAction(id: 'action-x', accountId: 'account-b', room: 'roomb'),
      );
    final handled = <AndroidNotificationAction>[];
    final coordinator = AndroidPushCoordinator(
      accounts: fixture.accounts,
      credentials: fixture.credentials,
      api: api,
      platform: platform,
      onWakeUp: (_) async {},
      onNotificationAction: (action) async {
        handled.add(action);
        return AndroidPushActionOutcome.completed;
      },
    );
    addTearDown(coordinator.close);

    await coordinator.drainAccount('account-a');

    expect(handled, isEmpty);
    expect(
      platform.resolvedActions.single.outcome,
      AndroidNotificationActionOutcome.failed,
    );
  });

  test('redacted action toString keeps the reply and room private', () {
    final action = _replyAction(
      id: 'action-a',
      accountId: 'account-a',
      room: 'rooma',
    );
    final text = action.toString();
    expect(text, contains('replyText: <redacted>'));
    expect(text, contains('roomToken: <redacted>'));
    expect(text, isNot(contains('notification reply')));
    expect(text, isNot(contains('rooma')));
    expect(text, isNot(contains('account-a')));
  });

  test('rejects a native action payload without reply text', () {
    expect(
      () => AndroidNotificationAction.fromMap(const <Object?, Object?>{
        'id': 'nksact1_x',
        'accountId': 'account-a',
        'kind': 'REPLY',
        'notificationId': 7,
        'roomToken': 'rooma',
        'replyText': '   ',
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => AndroidNotificationAction.fromMap(const <Object?, Object?>{
        'id': 'nksact1_x',
        'accountId': 'account-a',
        'kind': 'SEND_MONEY',
        'notificationId': 7,
        'roomToken': 'rooma',
        'replyText': null,
      }),
      throwsA(isA<FormatException>()),
    );
  });
}

HttpNextcloudApi _capabilityApi() {
  return HttpNextcloudApi(
    client: MockClient((request) async {
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
    }),
  );
}

AndroidNotificationAction _replyAction({
  required String id,
  required String accountId,
  required String room,
}) {
  return AndroidNotificationAction(
    id: id,
    accountId: accountId,
    kind: AndroidNotificationActionKind.reply,
    notificationId: 7,
    roomToken: room,
    replyText: 'notification reply',
  );
}

AndroidNotificationAction _markReadAction({
  required String id,
  required String accountId,
  required String room,
}) {
  return AndroidNotificationAction(
    id: id,
    accountId: accountId,
    kind: AndroidNotificationActionKind.markRead,
    notificationId: 8,
    roomToken: room,
    replyText: null,
  );
}

/// Hands out every stored action regardless of the requested account so the
/// coordinator's own scope guard is exercised.
final class _ForeignActionPlatform extends _FakeAndroidWebPushPlatform {
  @override
  Future<List<AndroidNotificationAction>> drainNotificationActions({
    required String accountId,
    int limit = 20,
  }) async => notificationActions.toList(growable: false);

  @override
  Future<bool> resolveNotificationAction({
    required String accountId,
    required String actionId,
    required AndroidNotificationActionOutcome outcome,
  }) async {
    notificationActions.removeWhere((action) => action.id == actionId);
    resolvedActions.add((actionId: actionId, outcome: outcome));
    return true;
  }
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

AndroidWebPushEvent _platformEvent({
  required String id,
  required AndroidWebPushEventType type,
  String accountId = 'account-a',
  int generation = 1,
}) {
  return AndroidWebPushEvent(
    id: id,
    accountId: accountId,
    generation: generation,
    type: type,
    createdAt: DateTime.utc(2026),
    coalescedCount: 1,
    stale: false,
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

class _FakeAndroidWebPushPlatform implements AndroidWebPushPlatform {
  final eventsController = StreamController<int>.broadcast();
  final openController = StreamController<AndroidNotificationOpen>.broadcast();
  final events = <AndroidWebPushEvent>[];
  final registrations = <({String accountId, int generation})>[];
  final committedEventIds = <String>[];
  final acknowledgedEventIds = <String>[];
  final notificationActions = <AndroidNotificationAction>[];
  final actionAttempts = <String, int>{};
  final exhaustedActionIds = <String>[];
  final resolvedActions =
      <({String actionId, AndroidNotificationActionOutcome outcome})>[];
  var maximumActionAttempts = 8;
  final endpointCommitted = Completer<void>();
  AndroidWebPushRegistrationPhase? phase;
  int? generation;
  Object? drainFailure;
  AndroidNotificationOpen? launchNotification;
  var emitEndpointOnRegister = true;
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
    if (emitEndpointOnRegister &&
        events
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
  Future<List<AndroidNotificationAction>> drainNotificationActions({
    required String accountId,
    int limit = 20,
  }) async {
    final claimed = notificationActions
        .where((action) => action.accountId == accountId)
        .take(limit)
        .toList(growable: false);
    for (final action in claimed) {
      final attempts = (actionAttempts[action.id] ?? 0) + 1;
      actionAttempts[action.id] = attempts;
      if (attempts > maximumActionAttempts) {
        notificationActions.remove(action);
        exhaustedActionIds.add(action.id);
      }
    }
    return claimed
        .where((action) => !exhaustedActionIds.contains(action.id))
        .toList(growable: false);
  }

  @override
  Future<bool> resolveNotificationAction({
    required String accountId,
    required String actionId,
    required AndroidNotificationActionOutcome outcome,
  }) async {
    final index = notificationActions.indexWhere(
      (action) => action.accountId == accountId && action.id == actionId,
    );
    if (index < 0) {
      return false;
    }
    notificationActions.removeAt(index);
    resolvedActions.add((actionId: actionId, outcome: outcome));
    return true;
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
