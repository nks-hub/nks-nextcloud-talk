import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
        retryDelay: Duration.zero,
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
}) {
  return AndroidWebPushEvent(
    id: id,
    accountId: 'account-a',
    generation: 1,
    type: AndroidWebPushEventType.message,
    createdAt: DateTime.utc(2026),
    coalescedCount: 1,
    stale: false,
    content: Uint8List.fromList(utf8.encode(jsonEncode(content))),
    decrypted: true,
  );
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
  AndroidWebPushRegistrationPhase? phase;
  int? generation;
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
    registrations.add((accountId: accountId, generation: generation));
    this.generation = generation;
    phase = AndroidWebPushRegistrationPhase.registering;
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
