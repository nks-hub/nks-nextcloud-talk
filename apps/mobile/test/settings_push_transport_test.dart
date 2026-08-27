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

/// Only its presence matters here: the settings screen shows the transport
/// choice when the Android bridge exists. Nothing on it is called, because
/// neither push coordinator is built in a widget test.
final class _PresentPushPlatform implements AndroidWebPushPlatform {
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
    ],
    child: localizedTestApp(home: const SettingsScreen()),
  );
}

void main() {
  late AppDatabase database;

  setUp(() => database = openTestDatabase());
  tearDown(() => database.close());

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
    await tester.pump();

    expect(store.stored, AndroidPushTransport.webPush);
    expect(store.writes, 1);
  });

  testWidgets('a failed switch says so instead of pretending', (tester) async {
    final store = _MemoryTransportStore(AndroidPushTransport.proxy)
      ..writeFailure = StateError('disk full');
    await tester.pumpWidget(_wrap(database, store));
    await tester.pump();

    await tester.tap(find.byKey(const Key('push-transport-web-push')));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(store.stored, AndroidPushTransport.proxy);
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
