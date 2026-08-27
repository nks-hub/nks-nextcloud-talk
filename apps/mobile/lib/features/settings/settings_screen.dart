import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../profile/profile_screen.dart';
import '../../core/desktop_metrics.dart';

/// Accounts and appearance settings. Reached from the account menu in the
/// compact shell and from the account rail in the expanded one.
final class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final accounts = ref.watch(accountsProvider);
    final themeMode = ref.watch(themeModeProvider);

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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
        )),
    );
  }

  void _addAccount(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OnboardingScreen(
          onAccountAdded: (_) => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _setTheme(WidgetRef ref, ThemeMode? mode) {
    if (mode == null) {
      return;
    }
    ref.read(themeModeProvider.notifier).setThemeMode(mode);
  }

  void _openProfile(BuildContext context, String accountId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(accountId: accountId),
      ),
    );
  }

  void _openDiagnostics(BuildContext context, String accountId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DiagnosticsScreen(accountId: accountId),
      ),
    );
  }
}

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
