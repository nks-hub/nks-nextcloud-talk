import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/app_version.dart';
import '../../l10n/generated/app_localizations.dart';
import 'update_check_service.dart';
import 'update_installer_service.dart';

/// The desktop update section: a switch that decides whether GitHub is asked
/// at all, and — only once it is on — what the last answer was.
///
/// A newer build is always offered as a link to its release page. On Windows,
/// once the release carries an installer, it is also offered as a download —
/// but only after the person says so, and again before it is ever run; every
/// other platform only ever gets the link.
final class UpdateCheckSettingsTile extends ConsumerWidget {
  const UpdateCheckSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final enabled = ref.watch(updateCheckEnabledProvider);
    final answer = ref.watch(latestBuildProvider);
    final available = answer.valueOrNull;
    final installState = ref.watch(updateInstallStateProvider);
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
        if (available is UpdateAvailable &&
            canDownloadAndInstallUpdate &&
            available.windowsInstallerAssetUri != null)
          _InstallRow(
            release: available,
            state: installState,
            onDownload: () =>
                unawaited(_confirmDownload(context, ref, available)),
            onCancel: () =>
                ref.read(updateInstallStateProvider.notifier).cancelDownload(),
            onInstall: (ready) =>
                unawaited(_confirmInstall(context, ref, ready)),
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

  Future<void> _confirmDownload(
    BuildContext context,
    WidgetRef ref,
    UpdateAvailable release,
  ) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Large text makes the body taller than the window; without this the
        // actions are pushed off the bottom and the dialog cannot be answered.
        scrollable: true,
        title: Text(strings.settingsUpdateCheckDownloadConfirmTitle),
        content: Text(strings.settingsUpdateCheckDownloadConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.settingsUpdateCheckDownloadDismiss),
          ),
          TextButton(
            key: const Key('settings-update-check-download-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.settingsUpdateCheckDownloadConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await ref
        .read(updateInstallStateProvider.notifier)
        .download(release);
    final message = switch (result) {
      UpdateInstallReady() => null,
      UpdateInstallVerificationFailed() =>
        strings.settingsUpdateCheckVerificationFailed,
      UpdateInstallCancelled() => strings.settingsUpdateCheckDownloadCancelled,
      UpdateInstallUnavailable() => strings.settingsUpdateCheckDownloadFailed,
    };
    if (message != null) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _confirmInstall(
    BuildContext context,
    WidgetRef ref,
    UpdateInstallReadyState ready,
  ) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(strings.settingsUpdateCheckInstallConfirmTitle),
        content: Text(strings.settingsUpdateCheckInstallConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.settingsUpdateCheckInstallDismiss),
          ),
          TextButton(
            key: const Key('settings-update-check-install-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.settingsUpdateCheckInstallConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final started = await ref
        .read(updateInstallStateProvider.notifier)
        .runInstaller(ready);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          started
              ? strings.settingsUpdateCheckInstallStarted
              : strings.settingsUpdateCheckInstallStartFailed,
        ),
      ),
    );
  }
}

/// The Windows-only download/install row, shown under the check result once
/// a release carries an installer.
final class _InstallRow extends StatelessWidget {
  const _InstallRow({
    required this.release,
    required this.state,
    required this.onDownload,
    required this.onCancel,
    required this.onInstall,
  });

  final UpdateAvailable release;
  final UpdateInstallState state;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final void Function(UpdateInstallReadyState ready) onInstall;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return switch (state) {
      UpdateInstallDownloading(:final receivedBytes, :final totalBytes) =>
        ListTile(
          key: const Key('settings-update-check-downloading'),
          leading: const Icon(Icons.downloading_outlined),
          title: LinearProgressIndicator(
            value: totalBytes == null || totalBytes == 0
                ? null
                : receivedBytes / totalBytes,
          ),
          subtitle: Text(
            totalBytes == null || totalBytes == 0
                ? strings.settingsUpdateCheckDownloadingUnknown
                : strings.settingsUpdateCheckDownloadingProgress(
                    (receivedBytes * 100 / totalBytes).floor(),
                  ),
          ),
          trailing: TextButton(
            key: const Key('settings-update-check-download-cancel'),
            onPressed: onCancel,
            child: Text(strings.settingsUpdateCheckDownloadCancel),
          ),
        ),
      final UpdateInstallReadyState ready => ListTile(
        key: const Key('settings-update-check-ready'),
        leading: const Icon(Icons.verified_outlined),
        title: TextButton(
          key: const Key('settings-update-check-install'),
          onPressed: () => onInstall(ready),
          child: Text(strings.settingsUpdateCheckInstallNow),
        ),
      ),
      UpdateInstallIdle() => ListTile(
        key: const Key('settings-update-check-download-row'),
        leading: const Icon(Icons.download_outlined),
        title: TextButton(
          key: const Key('settings-update-check-download'),
          onPressed: onDownload,
          child: Text(strings.settingsUpdateCheckDownloadInstall),
        ),
      ),
    };
  }
}
