import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/push/android_push_transport.dart';
import 'package:nextcloudtalk/features/push/android_web_push_bridge.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/app_settings.dart';

import 'test_support.dart';

/// A bridge that exists but reports no Web Push on this device, which is what
/// makes the settings screen show the transport choice while keeping the Web
/// Push coordinator idle. Its `revokeAllRegistrations` still runs on a switch
/// away — against an empty account list, so it asks the platform nothing.
final class _PresentPushPlatform implements AndroidWebPushPlatform {
  _PresentPushPlatform({
    this.permission = AndroidNotificationPermission.granted,
  });

  AndroidNotificationPermission permission;
  var permissionRequests = 0;

  @override
  Future<AndroidNotificationPermission> getNotificationPermission() async =>
      permission;

  @override
  Future<AndroidNotificationPermission> requestNotificationPermission() async {
    permissionRequests++;
    return permission = AndroidNotificationPermission.granted;
  }

  @override
  Future<AndroidWebPushAvailability> getAvailability() async =>
      const AndroidWebPushAvailability(
        available: false,
        playServicesAvailable: false,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Not used by the settings screen');
}

final class _SettingsOpener implements AppSettingsOpener {
  var calls = 0;

  @override
  Future<bool> open() async {
    calls++;
    return true;
  }
}

final class _ReconcilePushPlatform implements AndroidWebPushPlatform {
  final _events = StreamController<int>.broadcast();
  final _opens = StreamController<AndroidNotificationOpen>.broadcast();

  @override
  Stream<int> get eventsAvailable => _events.stream;

  @override
  Stream<AndroidNotificationOpen> get notificationOpened => _opens.stream;

  @override
  Future<AndroidWebPushAvailability> getAvailability() async =>
      const AndroidWebPushAvailability(
        available: true,
        playServicesAvailable: true,
      );

  @override
  Future<AndroidNotificationOpen?> getLaunchNotification() async => null;

  @override
  Future<List<AndroidWebPushEvent>> drainEvents({
    required String accountId,
    int limit = 50,
  }) async => const <AndroidWebPushEvent>[];

  @override
  Future<List<AndroidNotificationAction>> drainNotificationActions({
    required String accountId,
    int limit = 20,
  }) async => const <AndroidNotificationAction>[];

  @override
  Future<void> dispose() async {
    await _events.close();
    await _opens.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Web Push platform call');
}

final class _MemoryTransportStore implements AndroidPushTransportStore {
  _MemoryTransportStore(this.stored);

  AndroidPushTransport stored;
  var writes = 0;
  Object? writeFailure;

  @override
  Future<AndroidPushTransport> read() async => stored;

  @override
  Future<void> write(AndroidPushTransport transport) async {
    writes++;
    final failure = writeFailure;
    if (failure != null) {
      throw failure;
    }
    stored = transport;
  }
}

final class _DelayedReadTransportStore implements AndroidPushTransportStore {
  _DelayedReadTransportStore(this.stored);

  AndroidPushTransport stored;
  final readResult = Completer<AndroidPushTransport>();
  final events = <String>[];

  @override
  Future<AndroidPushTransport> read() => readResult.future;

  @override
  Future<void> write(AndroidPushTransport transport) async {
    events.add('write:${transport.name}');
    stored = transport;
  }
}

Widget _wrap(
  AppDatabase database,
  AndroidPushTransportStore store, {
  _PresentPushPlatform? platform,
  AppSettingsOpener? settingsOpener,
}) {
  final pushPlatform = platform ?? _PresentPushPlatform();
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      accountRepositoryProvider.overrideWithValue(AccountRepository(database)),
      accountsProvider.overrideWith(
        (ref) => Stream<List<StoredAccount>>.value(const <StoredAccount>[]),
      ),
      androidWebPushPlatformProvider.overrideWithValue(pushPlatform),
      if (settingsOpener != null)
        appSettingsOpenerProvider.overrideWithValue(settingsOpener),
      androidPushTransportStoreProvider.overrideWithValue(store),
      // The Web Push coordinator is built for real here, so that switching
      // away from it actually runs its revocation. Its credential vault is
      // the only part that reaches for a platform plugin.
      credentialVaultProvider.overrideWithValue(MemoryCredentialVault()),
    ],
    child: localizedTestApp(home: const SettingsScreen()),
  );
}

/// Switching away from Web Push revokes the old registration first, and that
/// reads the account list through Drift. Real I/O needs a genuine event-loop
/// turn, which the fake clock in testWidgets never gives it.
Future<void> _settleRealAsync(WidgetTester tester) async {
  for (var round = 0; round < 8; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  late AppDatabase database;

  setUp(() => database = openTestDatabase());
  tearDown(() => database.close());

  testWidgets('denied notifications link to system app settings', (
    tester,
  ) async {
    final platform = _PresentPushPlatform(
      permission: AndroidNotificationPermission.denied,
    );
    final opener = _SettingsOpener();
    await tester.pumpWidget(
      _wrap(
        database,
        _MemoryTransportStore(AndroidPushTransport.proxy),
        platform: platform,
        settingsOpener: opener,
      ),
    );
    await _settleRealAsync(tester);

    expect(find.text('Denied'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('open-notification-settings')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('open-notification-settings')));
    await tester.pump();
    expect(opener.calls, 1);
  });

  testWidgets('unrequested notifications can be granted in place', (
    tester,
  ) async {
    final platform = _PresentPushPlatform(
      permission: AndroidNotificationPermission.notDetermined,
    );
    await tester.pumpWidget(
      _wrap(
        database,
        _MemoryTransportStore(AndroidPushTransport.proxy),
        platform: platform,
      ),
    );
    await _settleRealAsync(tester);

    expect(find.text('Not requested yet'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('request-notification-permission')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('request-notification-permission')));
    await _settleRealAsync(tester);
    expect(platform.permissionRequests, 1);
    expect(find.text('Granted'), findsOneWidget);
    expect(
      find.byKey(const Key('request-notification-permission')),
      findsNothing,
    );
  });

  testWidgets('an untouched device shows the proxy transport selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(database, _MemoryTransportStore(AndroidPushTransport.proxy)),
    );
    await tester.pump();

    final proxy = tester.widget<RadioListTile<AndroidPushTransport>>(
      find.byKey(const Key('push-transport-proxy')),
    );
    expect(proxy.value, AndroidPushTransport.proxy);
    expect(find.byKey(const Key('push-transport-web-push')), findsOneWidget);
    expect(
      tester
          .widget<RadioGroup<AndroidPushTransport>>(
            find.byType(RadioGroup<AndroidPushTransport>),
          )
          .groupValue,
      AndroidPushTransport.proxy,
    );
  });

  testWidgets('the stored fallback choice is what the screen shows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(database, _MemoryTransportStore(AndroidPushTransport.webPush)),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<RadioGroup<AndroidPushTransport>>(
            find.byType(RadioGroup<AndroidPushTransport>),
          )
          .groupValue,
      AndroidPushTransport.webPush,
    );
  });

  testWidgets('choosing the fallback persists it without a rebuild', (
    tester,
  ) async {
    final store = _MemoryTransportStore(AndroidPushTransport.proxy);
    await tester.pumpWidget(_wrap(database, store));
    await tester.pump();

    await tester.tap(find.byKey(const Key('push-transport-web-push')));
    await _settleRealAsync(tester);

    expect(store.stored, AndroidPushTransport.webPush);
    expect(store.writes, 1);
  });

  test('choosing Web Push starts reconciliation immediately', () async {
    const accountId = 'account-a';
    final accounts = AccountRepository(database);
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
        return http.Response('{}', 401);
      }),
    );
    final platform = _ReconcilePushPlatform();
    final store = _MemoryTransportStore(AndroidPushTransport.proxy);
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        accountRepositoryProvider.overrideWithValue(accounts),
        credentialVaultProvider.overrideWithValue(credentials),
        nextcloudApiProvider.overrideWithValue(api),
        androidWebPushPlatformProvider.overrideWithValue(platform),
        androidPushTransportStoreProvider.overrideWithValue(store),
        connectivityWakeEventsProvider.overrideWithValue(
          const Stream<void>.empty(),
        ),
        appLifecycleResumeEventsProvider.overrideWithValue(
          const Stream<void>.empty(),
        ),
      ],
    );
    final coordinator = container.read(androidPushCoordinatorProvider)!;
    addTearDown(() async {
      await coordinator.close();
      container.dispose();
      api.close();
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(requests, isEmpty);

    await container
        .read(androidPushTransportProvider.notifier)
        .select(
          AndroidPushTransport.webPush,
          revoke: (_) async {},
          restore: (_) async {},
        );
    for (var attempt = 0; attempt < 20 && requests.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(
      requests.where(
        (request) => request.url.path.endsWith('/cloud/capabilities'),
      ),
      hasLength(1),
    );

    await container
        .read(androidPushTransportProvider.notifier)
        .select(
          AndroidPushTransport.webPush,
          revoke: (_) async {},
          restore: (_) async {},
        );
    await container
        .read(androidPushTransportProvider.notifier)
        .select(
          AndroidPushTransport.proxy,
          revoke: (_) async {},
          restore: (_) async {},
        );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      requests.where(
        (request) => request.url.path.endsWith('/cloud/capabilities'),
      ),
      hasLength(1),
    );
  });

  testWidgets('a failed switch says so instead of pretending', (tester) async {
    final store = _MemoryTransportStore(AndroidPushTransport.proxy)
      ..writeFailure = StateError('disk full');
    await tester.pumpWidget(_wrap(database, store));
    await tester.pump();

    await tester.tap(find.byKey(const Key('push-transport-web-push')));
    await _settleRealAsync(tester);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(store.stored, AndroidPushTransport.proxy);
  });

  test('late hydration cannot overwrite a user selection', () async {
    final store = _DelayedReadTransportStore(AndroidPushTransport.proxy);
    final container = ProviderContainer(
      overrides: [androidPushTransportStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    expect(
      container.read(androidPushTransportProvider),
      AndroidPushTransport.proxy,
    );

    await container
        .read(androidPushTransportProvider.notifier)
        .select(
          AndroidPushTransport.webPush,
          revoke: (live) async => store.events.add('revoke:${live.name}'),
          restore: (live) async => store.events.add('restore:${live.name}'),
        );
    store.readResult.complete(AndroidPushTransport.proxy);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(androidPushTransportProvider),
      AndroidPushTransport.webPush,
    );
    expect(store.events, ['revoke:proxy', 'write:webPush']);
  });

  test(
    'rapid selections are serialized and preserve the last intent',
    () async {
      final store = _MemoryTransportStore(AndroidPushTransport.proxy);
      final firstRevocation = Completer<void>();
      final events = <String>[];
      final container = ProviderContainer(
        overrides: [androidPushTransportStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(androidPushTransportProvider.notifier);

      final first = notifier.select(
        AndroidPushTransport.webPush,
        revoke: (live) async {
          events.add('revoke:${live.name}');
          await firstRevocation.future;
        },
        restore: (_) async {},
      );
      final last = notifier.select(
        AndroidPushTransport.proxy,
        revoke: (live) async => events.add('revoke:${live.name}'),
        restore: (_) async {},
      );
      await Future<void>.delayed(Duration.zero);
      firstRevocation.complete();
      await Future.wait([first, last]);

      expect(
        container.read(androidPushTransportProvider),
        AndroidPushTransport.proxy,
      );
      expect(events, ['revoke:proxy', 'revoke:webPush']);
      expect(store.writes, 2);
    },
  );

  testWidgets('a device without the Android bridge is offered no choice', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          accountRepositoryProvider.overrideWithValue(
            AccountRepository(database),
          ),
          accountsProvider.overrideWith(
            (ref) => Stream<List<StoredAccount>>.value(const <StoredAccount>[]),
          ),
          androidWebPushPlatformProvider.overrideWithValue(null),
        ],
        child: localizedTestApp(home: const SettingsScreen()),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('push-transport-proxy')), findsNothing);
  });
}
