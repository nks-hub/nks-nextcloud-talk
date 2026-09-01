import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_authenticator.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_controller.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_store.dart';
import 'package:nextcloudtalk/features/settings/settings_screen.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'app lock setting is hidden when device authentication is unsupported',
    (tester) async {
      await tester.pumpWidget(_settings(supported: false));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('settings-app-lock')), findsNothing);
    },
  );

  testWidgets('enabling app lock requires successful device authentication', (
    tester,
  ) async {
    final store = _Store();
    final authenticator = _Authenticator(results: <bool>[false, true]);
    await tester.pumpWidget(
      _settings(supported: true, store: store, authenticator: authenticator),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(store.writes, isEmpty);

    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(store.writes, <bool>[true]);
    expect(authenticator.calls, 2);
  });
}

Widget _settings({
  required bool supported,
  _Store? store,
  _Authenticator? authenticator,
}) {
  return ProviderScope(
    overrides: [
      accountsProvider.overrideWith((ref) => Stream.value(const [])),
      appLockMobilePlatformProvider.overrideWithValue(true),
      appLockStoreProvider.overrideWithValue(store ?? _Store()),
      appLockAuthenticatorProvider.overrideWithValue(
        authenticator ?? _Authenticator(supported: supported),
      ),
    ],
    child: localizedTestApp(home: const SettingsScreen()),
  );
}

final class _Store implements AppLockStore {
  final List<bool> writes = [];

  @override
  Future<bool> readEnabled() async => false;

  @override
  Future<void> writeEnabled(bool enabled) async => writes.add(enabled);
}

final class _Authenticator implements AppLockAuthenticator {
  _Authenticator({this.supported = true, List<bool>? results})
    : _results = results ?? <bool>[true];

  final bool supported;
  final List<bool> _results;
  var calls = 0;

  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    return _results.removeAt(0);
  }

  @override
  Future<bool> isSupported() async => supported;
}
