import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'app_lock_controller.dart';

final class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

final class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  int? _attemptedEpoch;
  var _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      setState(() => _foreground = false);
      ref.read(appLockControllerProvider.notifier).lockForLifecycle();
    } else if (state == AppLifecycleState.resumed) {
      setState(() => _foreground = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(appLockControllerProvider);
    if (lock.exposesApp) {
      return widget.child;
    }
    final strings = AppLocalizations.of(context);
    if (_foreground &&
        lock.phase == AppLockPhase.locked &&
        _attemptedEpoch != lock.lockEpoch) {
      _attemptedEpoch = lock.lockEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(appLockControllerProvider.notifier)
              .unlock(strings.appLockAuthenticationReason);
        }
      });
    }
    return _LockedScreen(
      state: lock,
      onRetry: () {
        if (lock.phase == AppLockPhase.failure) {
          ref.read(appLockControllerProvider.notifier).retryLoad();
        } else {
          ref
              .read(appLockControllerProvider.notifier)
              .unlock(strings.appLockAuthenticationReason);
        }
      },
    );
  }
}

final class _LockedScreen extends StatelessWidget {
  const _LockedScreen({required this.state, required this.onRetry});

  final AppLockState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final waiting =
        state.phase == AppLockPhase.loading ||
        state.phase == AppLockPhase.unlocking;
    return Scaffold(
      key: const Key('app-lock-screen'),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline_rounded, size: 64),
                  const SizedBox(height: 20),
                  Text(
                    strings.appLockLockedTitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.phase == AppLockPhase.failure
                        ? strings.appLockLoadFailed
                        : strings.appLockLockedMessage,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (waiting)
                    const SizedBox.square(
                      key: Key('app-lock-progress'),
                      dimension: 28,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  else
                    FilledButton.icon(
                      key: const Key('app-lock-retry'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.lock_open_rounded),
                      label: Text(strings.appLockUnlock),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
