import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/push/android_push_transport.dart';
import 'package:nextcloudtalk/features/push/android_web_push_bridge.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';

import 'test_support.dart';

/// A bridge that exists but reports no Web Push on this device, which is what
/// makes the settings screen show the transport choice while keeping the Web
/// Push coordinator idle. Its `revokeAllRegistrations` still runs on a switch
/// away — against an empty account list, so it asks the platform nothing.
final class _PresentPushPlatform implements AndroidWebPushPlatform {
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

Widget _wrap(AppDatabase database, AndroidPushTransportStore store) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      accountRepositoryProvider.overrideWithValue(AccountRepository(database)),
      accountsProvider.overrideWith(
        (ref) => Stream<List<StoredAccount>>.value(const <StoredAccount>[]),
      ),
      androidWebPushPlatformProvider.overrideWithValue(_PresentPushPlatform()),
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

  testWidgets('an untouched device shows the Web Push transport selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(database, _MemoryTransportStore(AndroidPushTransport.webPush)),
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
      AndroidPushTransport.webPush,
    );
  });

  testWidgets('the stored proxy choice is what the screen shows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(database, _MemoryTransportStore(AndroidPushTransport.proxy)),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<RadioGroup<AndroidPushTransport>>(
            find.byType(RadioGroup<AndroidPushTransport>),
          )
          .groupValue,
      AndroidPushTransport.proxy,
    );
  });

  testWidgets('choosing the proxy persists it without a rebuild', (
    tester,
  ) async {
    final store = _MemoryTransportStore(AndroidPushTransport.webPush);
    await tester.pumpWidget(_wrap(database, store));
    await tester.pump();

    await tester.tap(find.byKey(const Key('push-transport-proxy')));
    await _settleRealAsync(tester);

    expect(store.stored, AndroidPushTransport.proxy);
    expect(store.writes, 1);
  });

  testWidgets('a failed switch says so instead of pretending', (tester) async {
    final store = _MemoryTransportStore(AndroidPushTransport.webPush)
      ..writeFailure = StateError('disk full');
    await tester.pumpWidget(_wrap(database, store));
    await tester.pump();

    await tester.tap(find.byKey(const Key('push-transport-proxy')));
    await _settleRealAsync(tester);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(store.stored, AndroidPushTransport.webPush);
  });

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
