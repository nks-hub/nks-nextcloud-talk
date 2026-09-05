import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../features/push/android_push_transport.dart';
import '../../features/push/android_web_push_bridge.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../platform/desktop_autostart.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../profile/profile_screen.dart';
import '../../core/desktop_metrics.dart';
import 'app_lock/app_lock_controller.dart';
import 'reply_layout_preference.dart';
import 'app_lock/app_lock_settings_tile.dart';

/// Accounts and appearance settings. Reached from the account menu in the
/// compact shell and from the account rail in the expanded one.
final class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final accounts = ref.watch(accountsProvider);
    final themeMode = ref.watch(themeModeProvider);
    final appLock = ref.watch(appLockControllerProvider);
    final androidPushPlatform = ref.watch(androidWebPushPlatformProvider);
    final notificationPermission = ref.watch(
      androidNotificationPermissionProvider(androidPushPlatform != null),
    );
    final desktopAutostart = ref.watch(desktopAutostartHostProvider)
        ? ref.watch(desktopAutostartStateProvider)
        : null;

    // Removing the last account leaves this screen with nothing to manage,
    // while the shell underneath has already switched to onboarding. Close
    // settings so the user lands there instead of on an empty list.
    ref.listen(accountsProvider, (previous, next) {
      final remaining = next.valueOrNull;
      if (remaining != null && remaining.isEmpty) {
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
        }
      }
    });

    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsTitle)),
      body: ContentColumn(
        child: ListView(
          children: [
            _SectionHeader(strings.settingsAccountsSection),
            accounts.when(
              data: (items) => Column(
                children: [for (final account in items) _AccountTile(account)],
              ),
              // Deliberately not an indeterminate spinner: an endless animation
              // keeps the frame scheduler busy forever, which makes any
              // pumpAndSettle hang. The account list resolves from local
              // storage, so a quiet placeholder is enough.
              loading: () => const SizedBox(height: 24),
              error: (error, stackTrace) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(strings.settingsAccountsLoadFailed),
              ),
            ),
            ListTile(
              key: const Key('settings-add-account'),
              leading: const Icon(Icons.add_rounded),
              title: Text(strings.settingsAddAccount),
              onTap: () => _addAccount(context),
            ),
            const Divider(height: 1),
            _SectionHeader(strings.settingsProfileSection),
            accounts.when(
              data: (items) {
                final selected = _selectedAccount(items);
                return ListTile(
                  key: const Key('settings-open-profile'),
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(strings.settingsOpenProfile),
                  subtitle: Text(strings.settingsOpenProfileSubtitle),
                  enabled: selected != null,
                  onTap: selected == null
                      ? null
                      : () => _openProfile(context, selected.id),
                );
              },
              loading: () => const SizedBox(height: 24),
              error: (_, _) => const SizedBox.shrink(),
            ),
            const Divider(height: 1),
            _SectionHeader(strings.settingsDiagnosticsSection),
            accounts.when(
              data: (items) {
                final selected = _selectedAccount(items);
                return ListTile(
                  key: const Key('settings-open-diagnostics'),
                  leading: const Icon(Icons.troubleshoot_rounded),
                  title: Text(strings.settingsOpenDiagnostics),
                  subtitle: Text(strings.settingsOpenDiagnosticsSubtitle),
                  enabled: selected != null,
                  onTap: selected == null
                      ? null
                      : () => _openDiagnostics(context, selected.id),
                );
              },
              loading: () => const SizedBox(height: 24),
              error: (_, _) => const SizedBox.shrink(),
            ),
            // Android is the only platform with two push paths to choose
            // between; the bridge is null everywhere else.
            if (androidPushPlatform != null) ...[
              const Divider(height: 1),
              _SectionHeader(strings.settingsPushSection),
              RadioGroup<AndroidPushTransport>(
                groupValue: ref.watch(androidPushTransportProvider),
                onChanged: (transport) =>
                    _setPushTransport(context, ref, transport),
                child: Column(
                  children: [
                    _PushTransportTile(
                      tileKey: const Key('push-transport-proxy'),
                      label: strings.settingsPushTransportProxy,
                      subtitle: strings.settingsPushTransportProxySubtitle,
                      transport: AndroidPushTransport.proxy,
                      enabled: !ref.watch(
                        androidPushTransportSwitchingProvider,
                      ),
                    ),
                    _PushTransportTile(
                      tileKey: const Key('push-transport-web-push'),
                      label: strings.settingsPushTransportWebPush,
                      subtitle: strings.settingsPushTransportWebPushSubtitle,
                      transport: AndroidPushTransport.webPush,
                      enabled: !ref.watch(
                        androidPushTransportSwitchingProvider,
                      ),
                    ),
                  ],
                ),
              ),
              if (ref.watch(androidPushTransportSwitchingProvider))
                const LinearProgressIndicator(
                  key: Key('push-transport-switch-progress'),
                ),
              ListTile(
                key: const Key('settings-notification-permission'),
                leading: const Icon(Icons.notifications_outlined),
                title: Text(strings.settingsNotificationPermission),
                subtitle: Text(
                  _notificationPermissionLabel(
                    strings,
                    notificationPermission.valueOrNull,
                  ),
                ),
                trailing: switch (notificationPermission.valueOrNull) {
                  AndroidNotificationPermission.notDetermined => TextButton(
                    key: const Key('request-notification-permission'),
                    onPressed: () => _requestNotificationPermission(
                      context,
                      ref,
                      androidPushPlatform,
                    ),
                    child: Text(strings.settingsNotificationPermissionRequest),
                  ),
                  AndroidNotificationPermission.denied => TextButton(
                    key: const Key('open-notification-settings'),
                    onPressed: () => _openNotificationSettings(context, ref),
                    child: Text(strings.openAppSettings),
                  ),
                  AndroidNotificationPermission.granted => const Icon(
                    Icons.check_circle_outline_rounded,
                  ),
                  null => const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                },
              ),
            ],
            if (desktopAutostart != null &&
                desktopAutostart.supported != false) ...[
              const Divider(height: 1),
              _SectionHeader(strings.settingsDesktopSection),
              _DesktopAutostartTile(
                state: desktopAutostart,
                onChanged: (enabled) =>
                    _setDesktopAutostart(context, ref, enabled),
                onRetry: () =>
                    ref.read(desktopAutostartStateProvider.notifier).refresh(),
              ),
            ],
            if (appLock.supported) ...[
              const Divider(height: 1),
              _SectionHeader(strings.settingsSecuritySection),
              const AppLockSettingsTile(),
            ],
            const Divider(height: 1),
            _SectionHeader(strings.settingsCallsSection),
            SwitchListTile(
              key: const Key('call-relay-only'),
              title: Text(strings.settingsCallRelayOnly),
              subtitle: Text(strings.settingsCallRelayOnlyDescription),
              value: ref.watch(callRelayOnlyProvider),
              onChanged: (relayOnly) => unawaited(
                ref
                    .read(callRelayOnlyProvider.notifier)
                    .setRelayOnly(relayOnly),
              ),
            ),
            const Divider(height: 1),
            _SectionHeader(strings.settingsRepliesSection),
            RadioGroup<ReplyLayout>(
              groupValue: ref.watch(replyLayoutProvider),
              onChanged: (layout) => _setReplyLayout(ref, layout),
              child: Column(
                children: [
                  RadioListTile<ReplyLayout>(
                    key: const Key('reply-layout-inline'),
                    title: Text(strings.settingsReplyLayoutInline),
                    subtitle: Text(
                      strings.settingsReplyLayoutInlineDescription,
                    ),
                    value: ReplyLayout.inline,
                  ),
                  RadioListTile<ReplyLayout>(
                    key: const Key('reply-layout-thread'),
                    title: Text(strings.settingsReplyLayoutThread),
                    subtitle: Text(
                      strings.settingsReplyLayoutThreadDescription,
                    ),
                    value: ReplyLayout.thread,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _SectionHeader(strings.settingsThemeSection),
            RadioGroup<ThemeMode>(
              groupValue: themeMode,
              onChanged: (mode) => _setTheme(ref, mode),
              child: Column(
                children: [
                  _ThemeModeTile(
                    tileKey: const Key('theme-mode-system'),
                    label: strings.settingsThemeSystem,
                    mode: ThemeMode.system,
                  ),
                  _ThemeModeTile(
                    tileKey: const Key('theme-mode-light'),
                    label: strings.settingsThemeLight,
                    mode: ThemeMode.light,
                  ),
                  _ThemeModeTile(
                    tileKey: const Key('theme-mode-dark'),
                    label: strings.settingsThemeDark,
                    mode: ThemeMode.dark,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _addAccount(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/onboarding'),
        builder: (_) => OnboardingScreen(
          onAccountAdded: (_) => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  /// Hands the device to the other push transport. The switch revokes the old
  /// registration first and rethrows if that fails, so a failure here means
  /// the device is still registered the way it was — which is what the
  /// message says.
  Future<void> _setPushTransport(
    BuildContext context,
    WidgetRef ref,
    AndroidPushTransport? transport,
  ) async {
    if (transport == null) {
      return;
    }
    if (ref.read(androidPushTransportSwitchingProvider)) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(androidPushTransportProvider.notifier)
          .select(
            transport,
            revoke: (live) => revokeAndroidPushTransport(ref, live),
            restore: (live) => restoreAndroidPushTransport(ref, live),
          );
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text(strings.settingsPushTransportSwitchFailed)),
      );
    }
  }

  Future<void> _requestNotificationPermission(
    BuildContext context,
    WidgetRef ref,
    AndroidWebPushPlatform platform,
  ) async {
    try {
      await platform.requestNotificationPermission();
      ref.invalidate(androidNotificationPermissionProvider);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).settingsNotificationPermissionFailed,
            ),
          ),
        );
      }
    }
  }

  Future<void> _openNotificationSettings(
    BuildContext context,
    WidgetRef ref,
  ) async {
    try {
      final opened = await ref.read(appSettingsOpenerProvider).open();
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).openAppSettingsFailed),
          ),
        );
      }
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).openAppSettingsFailed),
          ),
        );
      }
    }
  }

  void _setReplyLayout(WidgetRef ref, ReplyLayout? layout) {
    if (layout == null) {
      return;
    }
    ref.read(replyLayoutProvider.notifier).setReplyLayout(layout);
  }

  void _setTheme(WidgetRef ref, ThemeMode? mode) {
    if (mode == null) {
      return;
    }
    ref.read(themeModeProvider.notifier).setThemeMode(mode);
  }

  Future<void> _setDesktopAutostart(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    final applied = await ref
        .read(desktopAutostartStateProvider.notifier)
        .setEnabled(enabled);
    if (!applied && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).settingsDesktopAutostartFailed,
          ),
        ),
      );
    }
  }

  void _openProfile(BuildContext context, String accountId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/settings/profile'),
        builder: (_) => ProfileScreen(accountId: accountId),
      ),
    );
  }

  void _openDiagnostics(BuildContext context, String accountId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/settings/diagnostics'),
        builder: (_) => DiagnosticsScreen(accountId: accountId),
      ),
    );
  }
}

String _notificationPermissionLabel(
  AppLocalizations strings,
  AndroidNotificationPermission? permission,
) => switch (permission) {
  AndroidNotificationPermission.granted =>
    strings.settingsNotificationPermissionGranted,
  AndroidNotificationPermission.denied =>
    strings.settingsNotificationPermissionDenied,
  AndroidNotificationPermission.notDetermined =>
    strings.settingsNotificationPermissionNotDetermined,
  null => strings.settingsNotificationPermissionChecking,
};

StoredAccount? _selectedAccount(List<StoredAccount> accounts) {
  for (final account in accounts) {
    if (account.selected) {
      return account;
    }
  }
  return null;
}

final class _AccountTile extends ConsumerStatefulWidget {
  const _AccountTile(this.account);

  final StoredAccount account;

  @override
  ConsumerState<_AccountTile> createState() => _AccountTileState();
}

final class _AccountTileState extends ConsumerState<_AccountTile> {
  /// Guards against a second tap arriving while the first removal is still
  /// running. Deliberately not rendered as a spinner: an indeterminate
  /// progress indicator animates forever and would wedge `pumpAndSettle`.
  var _removing = false;

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: Key('account-tile-${account.id}'),
      leading: Icon(
        account.selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        color: account.selected ? scheme.primary : scheme.outline,
      ),
      title: Text(account.loginName),
      subtitle: Text(account.serverUrl),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (account.selected)
            Text(
              strings.settingsAccountSelected,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.primary),
            ),
          IconButton(
            key: Key('account-remove-${account.id}'),
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: strings.settingsRemoveAccount,
            onPressed: _removing ? null : _confirmRemoval,
          ),
        ],
      ),
      onTap: account.selected || _removing
          ? null
          : () => ref.read(accountRepositoryProvider).selectAccount(account.id),
    );
  }

  Future<void> _confirmRemoval() async {
    final account = widget.account;
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final dialogStrings = AppLocalizations.of(dialogContext);
        return AlertDialog(
          key: const Key('account-remove-dialog'),
          title: Text(dialogStrings.settingsRemoveAccountDialogTitle),
          // Large text can make the body taller than the screen; without this
          // the actions are pushed off the bottom and the dialog cannot be
          // answered at all.
          scrollable: true,
          content: Text(
            dialogStrings.settingsRemoveAccountDialogMessage(
              account.loginName,
              account.serverUrl,
            ),
          ),
          actions: [
            TextButton(
              key: const Key('account-remove-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogStrings.cancel),
            ),
            TextButton(
              key: const Key('account-remove-confirm'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogStrings.settingsRemoveAccountDialogConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _removing = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final outcome = await ref
        .read(accountRemovalServiceProvider)
        .removeAccount(account.id);
    if (!mounted) {
      return;
    }
    setState(() => _removing = false);
    if (!outcome.accountExisted) {
      return;
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          outcome.appPasswordRevoked
              ? strings.settingsRemoveAccountDone
              : strings.settingsRemoveAccountDoneNotRevoked,
        ),
      ),
    );
  }
}

final class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile({
    required this.tileKey,
    required this.label,
    required this.mode,
  });

  final Key tileKey;
  final String label;
  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    return RadioListTile<ThemeMode>(
      key: tileKey,
      title: Text(label),
      value: mode,
    );
  }
}

final class _PushTransportTile extends StatelessWidget {
  const _PushTransportTile({
    required this.tileKey,
    required this.label,
    required this.subtitle,
    required this.transport,
    this.enabled = true,
  });

  final Key tileKey;
  final String label;
  final String subtitle;
  final AndroidPushTransport transport;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return RadioListTile<AndroidPushTransport>(
      key: tileKey,
      title: Text(label),
      subtitle: Text(subtitle),
      value: transport,
      enabled: enabled,
    );
  }
}

final class _DesktopAutostartTile extends StatelessWidget {
  const _DesktopAutostartTile({
    required this.state,
    required this.onChanged,
    required this.onRetry,
  });

  final DesktopAutostartState state;
  final ValueChanged<bool> onChanged;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final enabled = state.enabled ?? false;
    final subtitle = state.failed
        ? strings.settingsDesktopAutostartFailed
        : state.busy
        ? strings.settingsDesktopAutostartChecking
        : enabled
        ? strings.settingsDesktopAutostartOnSubtitle
        : strings.settingsDesktopAutostartOffSubtitle;
    return ListTile(
      key: const Key('settings-desktop-autostart'),
      leading: const Icon(Icons.power_settings_new_rounded),
      title: Text(strings.settingsDesktopAutostart),
      subtitle: Text(subtitle),
      trailing: state.supported == null && state.failed
          ? IconButton(
              key: const Key('settings-desktop-autostart-retry'),
              tooltip: strings.retry,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
            )
          : Switch(
              key: const Key('settings-desktop-autostart-switch'),
              value: enabled,
              onChanged: state.supported == true && !state.busy
                  ? onChanged
                  : null,
            ),
    );
  }
}

final class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
