part of 'conversation_shell.dart';

/// Width of the account rail. The Material touch target inside it is 56 px and
/// the rail pads both sides; the layout needs this number to work out whether
/// the conversation still has room to breathe.
const double kAccountRailWidth = 88;

final class _AccountRail extends StatelessWidget {
  const _AccountRail({
    required this.selected,
    required this.accounts,
    this.unreadByAccount = const {},
    required this.onSelect,
    required this.onAdd,
  });

  final StoredAccount selected;
  final List<StoredAccount> accounts;
  final Map<String, int> unreadByAccount;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return SizedBox(
      key: const Key('account-rail'),
      width: 88,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: BrandMark(size: 44),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: accounts.length,
              itemBuilder: (context, index) {
                final account = accounts[index];
                final isSelected = account.id == selected.id;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Tooltip(
                    message:
                        '${account.loginName}\n${Uri.parse(account.serverUrl).host}',
                    child: Semantics(
                      selected: isSelected,
                      button: true,
                      label:
                          '${account.loginName}, ${Uri.parse(account.serverUrl).host}',
                      child: Material(
                        color: isSelected
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          onTap: isSelected ? null : () => onSelect(account.id),
                          borderRadius: BorderRadius.circular(18),
                          child: SizedBox.square(
                            dimension: 56,
                            child: Center(
                              child: _AccountAvatar(
                                account: account,
                                unreadCount: unreadByAccount[account.id] ?? 0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                IconButton.filledTonal(
                  onPressed: onAdd,
                  tooltip: strings.addAccount,
                  icon: const Icon(Icons.add_rounded),
                ),
                const SizedBox(height: 8),
                IconButton(
                  key: const Key('open-settings'),
                  onPressed: () => _openSettings(context),
                  tooltip: strings.settingsTitle,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _AccountMenu extends StatelessWidget {
  const _AccountMenu({
    required this.selected,
    required this.accounts,
    this.unreadByAccount = const {},
    required this.onSelect,
    required this.onAdd,
  });

  static const _addKey = '__add_account__';
  static const _settingsKey = '__settings__';

  final StoredAccount selected;
  final List<StoredAccount> accounts;
  final Map<String, int> unreadByAccount;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      tooltip: strings.switchAccount,
      icon: _AccountAvatar(
        account: selected,
        unreadCount: unreadByAccount[selected.id] ?? 0,
      ),
      onSelected: (value) => switch (value) {
        _addKey => onAdd(),
        _settingsKey => _openSettings(context),
        _ => onSelect(value),
      },
      itemBuilder: (context) => [
        for (final account in accounts)
          PopupMenuItem<String>(
            value: account.id,
            enabled: account.id != selected.id,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _AccountAvatar(
                account: account,
                unreadCount: unreadByAccount[account.id] ?? 0,
              ),
              title: Text(account.loginName),
              subtitle: Text(Uri.parse(account.serverUrl).host),
              trailing: account.id == selected.id
                  ? const Icon(Icons.check_rounded)
                  : null,
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: _addKey,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.add_rounded),
            title: Text(strings.addAccount),
          ),
        ),
        PopupMenuItem<String>(
          key: const Key('open-settings'),
          value: _settingsKey,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_outlined),
            title: Text(strings.settingsTitle),
          ),
        ),
      ],
    );
  }
}

final class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.account, this.unreadCount = 0});

  final StoredAccount account;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    final initial = account.loginName.trim().isEmpty
        ? '?'
        : String.fromCharCode(
            account.loginName.trim().runes.first,
          ).toUpperCase();
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          backgroundColor: scheme.tertiaryContainer,
          foregroundColor: scheme.onTertiaryContainer,
          child: Text(initial),
        ),
        Positioned(
          right: -4,
          top: -4,
          child: UnreadCountBadge(
            key: Key('account-unread-badge-${account.id}'),
            count: unreadCount,
          ),
        ),
      ],
    );
  }
}
