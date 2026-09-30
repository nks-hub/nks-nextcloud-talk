import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'update_check_service.dart';
import 'update_install_action.dart';

final class DesktopUpdateBanner extends ConsumerStatefulWidget {
  const DesktopUpdateBanner({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DesktopUpdateBanner> createState() =>
      _DesktopUpdateBannerState();
}

final class _DesktopUpdateBannerState
    extends ConsumerState<DesktopUpdateBanner> {
  int? _dismissedBuild;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopUpdateCheckPlatform) return widget.child;
    final release = ref.watch(latestBuildProvider).valueOrNull;
    if (release is! UpdateAvailable ||
        release.buildNumber == _dismissedBuild ||
        release.installerAssetUri == null ||
        release.sha256SumsAssetUri == null) {
      return widget.child;
    }
    final strings = AppLocalizations.of(context);
    final state = ref.watch(updateInstallStateProvider);
    final busy =
        state is UpdateInstallDownloading || state is UpdateInstallInstalling;
    return Column(
      children: [
        Material(
          child: SafeArea(
            bottom: false,
            child: MaterialBanner(
              key: const Key('desktop-update-banner'),
              content: Text(
                strings.settingsUpdateCheckAvailable(
                  release.buildNumber,
                  release.name,
                ),
              ),
              forceActionsBelow: true,
              actions: [
                UpdateInstallAction(release: release),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(
                          () => _dismissedBuild = release.buildNumber,
                        ),
                  child: Text(strings.settingsUpdateCheckDownloadDismiss),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
