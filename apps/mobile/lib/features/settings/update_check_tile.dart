import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/app_version.dart';
import '../../l10n/generated/app_localizations.dart';
import 'update_check_service.dart';

/// The desktop update section: a switch that decides whether GitHub is asked
/// at all, and — only once it is on — what the last answer was.
///
/// A newer build is offered as a link to its release page. Nothing is
/// downloaded and nothing is run; installing stays the person's own step.
final class UpdateCheckSettingsTile extends ConsumerWidget {
  const UpdateCheckSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final enabled = ref.watch(updateCheckEnabledProvider);
    final answer = ref.watch(latestBuildProvider);
    final available = answer.valueOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          key: const Key('settings-update-check'),
          secondary: const Icon(Icons.system_update_alt_rounded),
          title: Text(strings.settingsUpdateCheck),
          subtitle: Text(strings.settingsUpdateCheckSubtitle),
          value: enabled,
          onChanged: (value) => unawaited(
            ref.read(updateCheckEnabledProvider.notifier).setEnabled(value),
          ),
        ),
        if (enabled)
          ListTile(
            key: const Key('settings-update-check-result'),
            leading: const Icon(Icons.new_releases_outlined),
            title: Text(
              strings.settingsUpdateCheckCurrentBuild(appBuildNumber),
            ),
            // Deliberately text and not a spinner: an indeterminate indicator
            // animates forever and would wedge any pumpAndSettle on this
            // screen, the same reason the account list uses a quiet
            // placeholder.
            subtitle: Text(_subtitle(strings, answer)),
            trailing: available is UpdateAvailable
                ? TextButton(
                    key: const Key('settings-update-check-open'),
                    onPressed: () =>
                        unawaited(_open(context, ref, available.releaseUri)),
                    child: Text(strings.settingsUpdateCheckOpen),
                  )
                : null,
          ),
      ],
    );
  }

  String _subtitle(
    AppLocalizations strings,
    AsyncValue<UpdateCheckResult?> answer,
  ) {
    if (answer.isLoading) {
      return strings.settingsUpdateCheckChecking;
    }
    return switch (answer.valueOrNull) {
      UpdateUpToDate() => strings.settingsUpdateCheckUpToDate,
      UpdateAvailable(:final buildNumber, :final name) =>
        strings.settingsUpdateCheckAvailable(buildNumber, name),
      // Null is the switch having just been turned on, before the first
      // answer; an error out of the provider is a check that never ran.
      UpdateCheckUnavailable() || null => strings.settingsUpdateCheckFailed,
    };
  }

  Future<void> _open(BuildContext context, WidgetRef ref, Uri uri) async {
    final strings = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var opened = false;
    try {
      opened = await ref.read(referenceUriLauncherProvider)(uri);
    } on Object {
      opened = false;
    }
    if (!opened) {
      messenger?.showSnackBar(
        SnackBar(content: Text(strings.settingsUpdateCheckOpenFailed)),
      );
    }
  }
}
