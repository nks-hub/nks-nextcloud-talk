import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_authenticator.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_controller.dart';
import 'package:nextcloudtalk/features/settings/app_lock/app_lock_store.dart';

void main() {
  test('a platform with no device to ask bypasses storage and the check', () {
    // This used to be named "desktop bypasses…" and that was the defect: the
    // gate listed Android and iOS and shortcut everything else to "not
    // supported" WITHOUT ASKING, so Windows Hello and Touch ID never got the
    // question even though `local_auth_windows` and `local_auth_darwin` are
    // bundled and registered in both runners. Only the web has no device to
    // ask; the gate says so now, and this test keeps that one exclusion.
    final store = _MemoryAppLockStore(readError: StateError('must not read'));
    final authenticator = _FakeAuthenticator(supported: true);
    final container = _container(
      mobile: false,
      store: store,
      authenticator: authenticator,
    );
    addTearDown(container.dispose);

    return container.read(appLockControllerProvider.notifier).ready.then((_) {
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.disabled,
      );
      expect(authenticator.supportChecks, 0);
    });
  });

  test('a desktop is asked whether it has a device lock', () async {
    // The behaviour the gate used to make impossible: the platform is asked,
    // and a desktop that answers yes gets the setting like a phone does.
    final authenticator = _FakeAuthenticator(supported: true);
    final container = _container(
      store: _MemoryAppLockStore(),
      authenticator: authenticator,
    );
    addTearDown(container.dispose);

    await container.read(appLockControllerProvider.notifier).ready;

    expect(authenticator.supportChecks, 1, reason: 'it was actually asked');
    expect(container.read(appLockControllerProvider).supported, isTrue);
  });

  test('a preference read error fails closed', () async {
    final container = _container(
      store: _MemoryAppLockStore(readError: StateError('unavailable')),
      authenticator: _FakeAuthenticator(supported: true),
    );
    addTearDown(container.dispose);

    await container.read(appLockControllerProvider.notifier).ready;

    expect(
      container.read(appLockControllerProvider).phase,
      AppLockPhase.failure,
    );
    expect(container.read(appLockControllerProvider).exposesApp, isFalse);
  });

  test(
    'a support-check error cannot lock an app with no enabled setting',
    () async {
      final container = _container(
        store: _MemoryAppLockStore(),
        authenticator: _FakeAuthenticator(
          supported: false,
          supportError: StateError('platform unavailable'),
        ),
      );
      addTearDown(container.dispose);

      await container.read(appLockControllerProvider.notifier).ready;

      final state = container.read(appLockControllerProvider);
      expect(state.phase, AppLockPhase.disabled);
      expect(state.supported, isFalse);
      expect(state.exposesApp, isTrue);
    },
  );

  test('an enabled lock starts locked without exposing app content', () async {
    final authenticator = _FakeAuthenticator(supported: true);
    final container = _container(
      store: _MemoryAppLockStore(enabled: true),
      authenticator: authenticator,
    );
    addTearDown(container.dispose);

    await container.read(appLockControllerProvider.notifier).ready;

    final state = container.read(appLockControllerProvider);
    expect(state.phase, AppLockPhase.locked);
    expect(state.exposesApp, isFalse);
    expect(authenticator.authenticationCalls, 0);
  });

  test(
    'unlock is single-flight and lifecycle callbacks during auth are ignored',
    () async {
      final result = Completer<bool>();
      final authenticator = _FakeAuthenticator(
        supported: true,
        authentication: () => result.future,
      );
      final container = _container(
        store: _MemoryAppLockStore(enabled: true),
        authenticator: authenticator,
      );
      addTearDown(container.dispose);
      final controller = container.read(appLockControllerProvider.notifier);
      await controller.ready;

      final first = controller.unlock('reason');
      final second = controller.unlock('reason');
      controller.lockForLifecycle();

      expect(identical(first, second), isTrue);
      expect(authenticator.authenticationCalls, 1);
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.unlocking,
      );

      result.complete(true);
      expect(await first, isTrue);
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.unlocked,
      );

      controller.lockForLifecycle();
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.locked,
      );
      expect(container.read(appLockControllerProvider).lockEpoch, 2);
    },
  );

  test(
    'cancel and authentication errors stay locked for an explicit retry',
    () async {
      final authenticator = _FakeAuthenticator(
        supported: true,
        authenticationResults: <Object>[
          false,
          StateError('system error'),
          true,
        ],
      );
      final container = _container(
        store: _MemoryAppLockStore(enabled: true),
        authenticator: authenticator,
      );
      addTearDown(container.dispose);
      final controller = container.read(appLockControllerProvider.notifier);
      await controller.ready;

      expect(await controller.unlock('reason'), isFalse);
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.locked,
      );
      expect(await controller.unlock('reason'), isFalse);
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.locked,
      );
      expect(await controller.unlock('reason'), isTrue);
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.unlocked,
      );
    },
  );

  test(
    'enabling authenticates first and disabling requires an unlocked session',
    () async {
      final store = _MemoryAppLockStore();
      final authenticator = _FakeAuthenticator(
        supported: true,
        authenticationResults: <Object>[false, true, true],
      );
      final container = _container(store: store, authenticator: authenticator);
      addTearDown(container.dispose);
      final controller = container.read(appLockControllerProvider.notifier);
      await controller.ready;

      expect(
        await controller.setEnabled(true, 'reason'),
        AppLockChangeResult.cancelled,
      );
      expect(store.writes, isEmpty);
      expect(
        await controller.setEnabled(true, 'reason'),
        AppLockChangeResult.changed,
      );
      expect(store.writes, <bool>[true]);
      expect(
        container.read(appLockControllerProvider).phase,
        AppLockPhase.unlocked,
      );

      controller.lockForLifecycle();
      expect(
        await controller.setEnabled(false, 'reason'),
        AppLockChangeResult.notAllowed,
      );
      expect(store.writes, <bool>[true]);
      expect(await controller.unlock('reason'), isTrue);
      expect(
        await controller.setEnabled(false, 'reason'),
        AppLockChangeResult.changed,
      );
      expect(store.writes, <bool>[true, false]);
    },
  );
}

ProviderContainer _container({
  bool mobile = true,
  required _MemoryAppLockStore store,
  required _FakeAuthenticator authenticator,
}) {
  return ProviderContainer(
    overrides: [
      appLockMobilePlatformProvider.overrideWithValue(mobile),
      appLockStoreProvider.overrideWithValue(store),
      appLockAuthenticatorProvider.overrideWithValue(authenticator),
    ],
  );
}

final class _MemoryAppLockStore implements AppLockStore {
  _MemoryAppLockStore({this.enabled = false, this.readError});

  bool enabled;
  final Object? readError;
  final List<bool> writes = [];

  @override
  Future<bool> readEnabled() async {
    if (readError case final error?) {
      throw error;
    }
    return enabled;
  }

  @override
  Future<void> writeEnabled(bool value) async {
    writes.add(value);
    enabled = value;
  }
}

final class _FakeAuthenticator implements AppLockAuthenticator {
  _FakeAuthenticator({
    required this.supported,
    this.authentication,
    this.supportError,
    List<Object>? authenticationResults,
  }) : _authenticationResults = authenticationResults ?? <Object>[true];

  final bool supported;
  final Future<bool> Function()? authentication;
  final Object? supportError;
  final List<Object> _authenticationResults;
  var supportChecks = 0;
  var authenticationCalls = 0;

  @override
  Future<bool> isSupported() async {
    supportChecks++;
    if (supportError case final error?) {
      throw error;
    }
    return supported;
  }

  @override
  Future<bool> authenticate(String reason) async {
    authenticationCalls++;
    if (authentication != null) {
      return authentication!();
    }
    final result = _authenticationResults.removeAt(0);
    if (result is bool) {
      return result;
    }
    throw result;
  }
}
