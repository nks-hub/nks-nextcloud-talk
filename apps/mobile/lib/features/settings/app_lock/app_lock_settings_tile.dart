import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'app_lock_controller.dart';

final class AppLockSettingsTile extends ConsumerWidget {
  const AppLockSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appLockControllerProvider);
    final strings = AppLocalizations.of(context);
    return SwitchListTile(
      key: const Key('settings-app-lock'),
      secondary: const Icon(Icons.lock_outline_rounded),
      title: Text(strings.settingsAppLock),
      subtitle: Text(strings.settingsAppLockSubtitle),
      value: state.enabled,
      onChanged: state.settingBusy
          ? null
          : (enabled) => _change(context, ref, enabled),
    );
  }

  Future<void> _change(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    final strings = AppLocalizations.of(context);
    final result = await ref
        .read(appLockControllerProvider.notifier)
        .setEnabled(enabled, strings.appLockAuthenticationReason);
    if (!context.mounted || result == AppLockChangeResult.changed) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == AppLockChangeResult.cancelled
              ? strings.appLockAuthenticationCancelled
              : strings.settingsAppLockChangeFailed,
        ),
      ),
    );
  }
}
