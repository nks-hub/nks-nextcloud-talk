import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'update_check_service.dart';
import 'update_installer_service.dart';

final class UpdateInstallAction extends ConsumerStatefulWidget {
  const UpdateInstallAction({super.key, required this.release});

  final UpdateAvailable release;

  @override
  ConsumerState<UpdateInstallAction> createState() =>
      _UpdateInstallActionState();
}

final class _UpdateInstallActionState
    extends ConsumerState<UpdateInstallAction> {
  UpdateInstallResult? _failure;

  Future<void> _update() async {
    setState(() => _failure = null);
    final result = await ref
        .read(updateInstallStateProvider.notifier)
        .downloadAndInstall(widget.release);
    if (mounted && result != null && result is! UpdateInstallReady) {
      setState(() => _failure = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final state = ref.watch(updateInstallStateProvider);
    final error = switch (_failure) {
      UpdateInstallVerificationFailed() =>
        strings.settingsUpdateCheckVerificationFailed,
      UpdateInstallCancelled() => strings.settingsUpdateCheckDownloadCancelled,
      UpdateInstallStartFailed() =>
        strings.settingsUpdateCheckInstallStartFailed,
      UpdateInstallUnavailable() => strings.settingsUpdateCheckDownloadFailed,
      _ => null,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state is UpdateInstallInstalling)
          Text(strings.settingsUpdateCheckInstallStarted)
        else if (state is UpdateInstallDownloading)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              Text(
                state.totalBytes == null || state.totalBytes == 0
                    ? strings.settingsUpdateCheckDownloadingUnknown
                    : strings.settingsUpdateCheckDownloadingProgress(
                        (state.receivedBytes * 100 / state.totalBytes!).floor(),
                      ),
              ),
              TextButton(
                key: const Key('settings-update-check-download-cancel'),
                onPressed: () => ref
                    .read(updateInstallStateProvider.notifier)
                    .cancelDownload(),
                child: Text(strings.settingsUpdateCheckDownloadCancel),
              ),
            ],
          )
        else
          TextButton.icon(
            key: const Key('settings-update-check-download'),
            onPressed: () => unawaited(_update()),
            icon: const Icon(Icons.system_update_alt_rounded),
            label: Text(strings.settingsUpdateCheckDownloadInstall),
          ),
        if (error != null)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
