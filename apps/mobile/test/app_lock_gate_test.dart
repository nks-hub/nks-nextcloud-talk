import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_authenticator.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_controller.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_gate.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_store.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'locked app never builds protected content before authentication',
    (tester) async {
      final authentication = Completer<bool>();
      var protectedBuilds = 0;
      await tester.pumpWidget(
        _testApp(
          store: _Store(enabled: true),
          authenticator: _Authenticator(authentication.future),
          child: _BuildProbe(onBuild: () => protectedBuilds++),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('app-lock-screen')), findsOneWidget);
      expect(protectedBuilds, 0);

      authentication.complete(true);
      await tester.pump();

      expect(find.byKey(const Key('protected-content')), findsOneWidget);
      expect(protectedBuilds, 1);
    },
  );

  testWidgets('cancel stays locked and retry starts one new attempt', (
    tester,
  ) async {
    final authenticator = _QueuedAuthenticator(<Future<bool>>[
      Future<bool>.value(false),
      Future<bool>.value(true),
    ]);
    await tester.pumpWidget(
      _testApp(
        store: _Store(enabled: true),
        authenticator: authenticator,
        child: const SizedBox(key: Key('protected-content')),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('app-lock-retry')), findsOneWidget);
    expect(authenticator.calls, 1);

    await tester.tap(find.byKey(const Key('app-lock-retry')));
    await tester.pump();

    expect(authenticator.calls, 2);
    expect(find.byKey(const Key('protected-content')), findsOneWidget);
  });

  testWidgets(
    'paused unlocked app hides content until it authenticates again',
    (tester) async {
      final secondAuthentication = Completer<bool>();
      final authenticator = _QueuedAuthenticator(<Future<bool>>[
        Future<bool>.value(true),
        secondAuthentication.future,
      ]);
      await tester.pumpWidget(
        _testApp(
          store: _Store(enabled: true),
          authenticator: authenticator,
          child: const SizedBox(key: Key('protected-content')),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('protected-content')), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppLockGate)),
      );
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.locked,
      );
      expect(authenticator.calls, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(authenticator.calls, 2);
      expect(find.byKey(const Key('protected-content')), findsNothing);
      secondAuthentication.complete(true);
      await tester.pump();
      expect(find.byKey(const Key('protected-content')), findsOneWidget);
    },
  );
}

Widget _testApp({
  required AppLockStore store,
  required AppLockAuthenticator authenticator,
  required Widget child,
}) {
  return ProviderScope(
    overrides: [
      appLockMobilePlatformProvider.overrideWithValue(true),
      appLockStoreProvider.overrideWithValue(store),
      appLockAuthenticatorProvider.overrideWithValue(authenticator),
    ],
    child: localizedTestApp(home: AppLockGate(child: child)),
  );
}

final class _BuildProbe extends StatelessWidget {
  const _BuildProbe({required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(key: Key('protected-content'));
  }
}

final class _Store implements AppLockStore {
  _Store({required this.enabled});

  bool enabled;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;
}

final class _Authenticator implements AppLockAuthenticator {
  _Authenticator(this.result);

  final Future<bool> result;

  @override
  Future<bool> authenticate(String reason) => result;

  @override
  Future<bool> isSupported() async => true;
}

final class _QueuedAuthenticator implements AppLockAuthenticator {
  _QueuedAuthenticator(this.results);

  final List<Future<bool>> results;
  var calls = 0;

  @override
  Future<bool> authenticate(String reason) {
    calls++;
    return results.removeAt(0);
  }

  @override
  Future<bool> isSupported() async => true;
}
