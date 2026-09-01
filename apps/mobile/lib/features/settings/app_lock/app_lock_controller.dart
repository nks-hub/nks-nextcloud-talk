import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_lock_authenticator.dart';
import 'app_lock_store.dart';

enum AppLockPhase { loading, disabled, locked, unlocking, unlocked, failure }

enum AppLockChangeResult { changed, cancelled, failed, notAllowed }

final class AppLockState {
  const AppLockState({
    required this.phase,
    this.supported = false,
    this.lockEpoch = 0,
    this.settingBusy = false,
  });

  const AppLockState.loading() : this(phase: AppLockPhase.loading);

  final AppLockPhase phase;
  final bool supported;
  final int lockEpoch;
  final bool settingBusy;

  bool get enabled => switch (phase) {
    AppLockPhase.locked ||
    AppLockPhase.unlocking ||
    AppLockPhase.unlocked => true,
    _ => false,
  };

  bool get exposesApp =>
      phase == AppLockPhase.disabled || phase == AppLockPhase.unlocked;

  AppLockState copyWith({
    AppLockPhase? phase,
    bool? supported,
    int? lockEpoch,
    bool? settingBusy,
  }) {
    return AppLockState(
      phase: phase ?? this.phase,
      supported: supported ?? this.supported,
      lockEpoch: lockEpoch ?? this.lockEpoch,
      settingBusy: settingBusy ?? this.settingBusy,
    );
  }
}

final appLockMobilePlatformProvider = Provider<bool>((ref) {
  if (kIsWeb) {
    return false;
  }
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
});

final appLockStoreProvider = Provider<AppLockStore>((ref) {
  return SecureAppLockStore();
});

final appLockAuthenticatorProvider = Provider<AppLockAuthenticator>((ref) {
  return SystemAppLockAuthenticator();
});

final appLockControllerProvider =
    NotifierProvider<AppLockController, AppLockState>(AppLockController.new);

final class AppLockController extends Notifier<AppLockState> {
  final Completer<void> _ready = Completer<void>();
  Future<bool>? _unlockFuture;
  Future<AppLockChangeResult>? _settingFuture;
  var _authenticationActive = false;
  var _disposed = false;

  Future<void> get ready => _ready.future;

  @override
  AppLockState build() {
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(_load);
    return const AppLockState.loading();
  }

  Future<void> _load() async {
    try {
      if (!ref.read(appLockMobilePlatformProvider)) {
        _setState(
          const AppLockState(phase: AppLockPhase.disabled, supported: false),
        );
        return;
      }
      final enabled = await ref.read(appLockStoreProvider).readEnabled();
      if (!enabled) {
        var supported = false;
        try {
          supported = await ref
              .read(appLockAuthenticatorProvider)
              .isSupported();
        } on Object {
          // Availability only controls whether the disabled setting is shown.
        }
        _setState(
          AppLockState(phase: AppLockPhase.disabled, supported: supported),
        );
        return;
      }
      final supported = await ref
          .read(appLockAuthenticatorProvider)
          .isSupported();
      if (!supported) {
        _setState(const AppLockState(phase: AppLockPhase.failure));
      } else {
        _setState(
          const AppLockState(
            phase: AppLockPhase.locked,
            supported: true,
            lockEpoch: 1,
          ),
        );
      }
    } on Object {
      _setState(const AppLockState(phase: AppLockPhase.failure));
    } finally {
      if (!_ready.isCompleted) {
        _ready.complete();
      }
    }
  }

  Future<void> retryLoad() async {
    if (state.phase != AppLockPhase.failure) {
      return;
    }
    state = const AppLockState.loading();
    await _load();
  }

  Future<bool> unlock(String reason) {
    final pending = _unlockFuture;
    if (pending != null) {
      return pending;
    }
    if (state.phase != AppLockPhase.locked) {
      return Future<bool>.value(state.phase == AppLockPhase.unlocked);
    }
    final completion = Completer<bool>();
    final attempt = completion.future;
    _unlockFuture = attempt;
    unawaited(
      _authenticateLocked(reason).then(completion.complete).whenComplete(() {
        if (identical(_unlockFuture, attempt)) {
          _unlockFuture = null;
        }
      }),
    );
    return attempt;
  }

  Future<bool> _authenticateLocked(String reason) async {
    final epoch = state.lockEpoch;
    state = state.copyWith(phase: AppLockPhase.unlocking);
    _authenticationActive = true;
    try {
      final authenticated = await ref
          .read(appLockAuthenticatorProvider)
          .authenticate(reason);
      _authenticationActive = false;
      if (!_disposed && state.lockEpoch == epoch) {
        state = state.copyWith(
          phase: authenticated ? AppLockPhase.unlocked : AppLockPhase.locked,
        );
      }
      return authenticated;
    } on Object {
      if (!_disposed && state.lockEpoch == epoch) {
        state = state.copyWith(phase: AppLockPhase.locked);
      }
      return false;
    } finally {
      _authenticationActive = false;
    }
  }

  void lockForLifecycle() {
    if (_authenticationActive || state.phase != AppLockPhase.unlocked) {
      return;
    }
    state = state.copyWith(
      phase: AppLockPhase.locked,
      lockEpoch: state.lockEpoch + 1,
      settingBusy: false,
    );
  }

  Future<AppLockChangeResult> setEnabled(bool enabled, String reason) {
    final pending = _settingFuture;
    if (pending != null) {
      return pending;
    }
    final completion = Completer<AppLockChangeResult>();
    final operation = completion.future;
    _settingFuture = operation;
    unawaited(
      _setEnabled(enabled, reason).then(completion.complete).whenComplete(() {
        if (identical(_settingFuture, operation)) {
          _settingFuture = null;
        }
      }),
    );
    return operation;
  }

  Future<AppLockChangeResult> _setEnabled(bool enabled, String reason) async {
    try {
      if (enabled) {
        if (state.phase != AppLockPhase.disabled || !state.supported) {
          return AppLockChangeResult.notAllowed;
        }
        state = state.copyWith(settingBusy: true);
        _authenticationActive = true;
        final authenticated = await ref
            .read(appLockAuthenticatorProvider)
            .authenticate(reason);
        if (!authenticated) {
          _authenticationActive = false;
          state = state.copyWith(settingBusy: false);
          return AppLockChangeResult.cancelled;
        }
        await ref.read(appLockStoreProvider).writeEnabled(true);
        _authenticationActive = false;
        state = AppLockState(
          phase: AppLockPhase.unlocked,
          supported: true,
          lockEpoch: state.lockEpoch + 1,
        );
        return AppLockChangeResult.changed;
      }

      if (state.phase != AppLockPhase.unlocked) {
        return AppLockChangeResult.notAllowed;
      }
      state = state.copyWith(settingBusy: true);
      await ref.read(appLockStoreProvider).writeEnabled(false);
      state = const AppLockState(phase: AppLockPhase.disabled, supported: true);
      return AppLockChangeResult.changed;
    } on Object {
      if (!_disposed) {
        state = state.copyWith(settingBusy: false);
      }
      return AppLockChangeResult.failed;
    } finally {
      _authenticationActive = false;
    }
  }

  void _setState(AppLockState next) {
    if (!_disposed) {
      state = next;
    }
  }
}
