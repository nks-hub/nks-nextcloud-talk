import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../onboarding/onboarding_screen.dart';

/// Standalone accounts and appearance settings screen. Not wired into any
/// navigation entry point yet — the caller decides how to reach it.
final class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final accounts = ref.watch(accountsProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsTitle)),
      body: ListView(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              strings.settingsRemoveAccountUnavailable,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
                  key: const Key('theme-mode-system'),
                  label: strings.settingsThemeSystem,
                  mode: ThemeMode.system,
                ),
                _ThemeModeTile(
                  key: const Key('theme-mode-light'),
                  label: strings.settingsThemeLight,
                  mode: ThemeMode.light,
                ),
                _ThemeModeTile(
                  key: const Key('theme-mode-dark'),
                  label: strings.settingsThemeDark,
                  mode: ThemeMode.dark,
                ),
              ],
            ),
          ),
        ],
      ),
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
}

final class _AccountTile extends ConsumerWidget {
  const _AccountTile(this.account);

  final StoredAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      trailing: account.selected
          ? Text(
              strings.settingsAccountSelected,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.primary),
            )
          : null,
      onTap: account.selected
          ? null
          : () =>
                ref.read(accountRepositoryProvider).selectAccount(account.id),
    );
  }
}

final class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile({required super.key, required this.label, required this.mode});

  final String label;
  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    return RadioListTile<ThemeMode>(title: Text(label), value: mode);
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
