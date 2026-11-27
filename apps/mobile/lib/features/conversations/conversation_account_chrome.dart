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
    required this.navigation,
  });

  final StoredAccount selected;
  final List<StoredAccount> accounts;
  final Map<String, int> unreadByAccount;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;
  final Widget navigation;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return SizedBox(
      key: const Key('account-rail'),
      width: kAccountRailWidth,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: BrandMark(size: 44),
          ),
          navigation,
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
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              children: [
                IconButton.filledTonal(
                  onPressed: onAdd,
                  tooltip: strings.addAccount,
                  icon: const Icon(Icons.add_rounded),
                ),
                const SizedBox(height: 8),
                // The rail replaces the account menu once there is more than
                // one account, so anything the menu carries has to be here
                // too - and the reminder inbox is at its most useful exactly
                // when several accounts are signed in.
                IconButton(
                  key: const Key('open-reminder-inbox'),
                  onPressed: () => openReminderInbox(context),
                  tooltip: strings.reminderInboxTitle,
                  icon: const Icon(Icons.alarm_outlined),
                ),
                IconButton(
                  key: const Key('open-message-collections'),
                  tooltip: strings.messageCollections,
                  icon: const Icon(Icons.bookmarks_outlined),
                  onPressed: () => _openSavedCollections(context, selected),
                ),
                _RailFooter(
                  touchPadding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: IconButton(
                    key: const Key('open-settings'),
                    onPressed: () => _openSettings(context),
                    tooltip: strings.settingsTitle,
                    icon: const SettingsIconWithUpdateMark(),
                  ),
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
  static const _collectionsKey = '__message_collections__';
  static const _remindersKey = '__reminders__';

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
        _remindersKey => openReminderInbox(context),
        _collectionsKey => _openSavedCollections(context, selected),
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
          key: const Key('open-message-collections'),
          value: _collectionsKey,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bookmarks_outlined),
            title: Text(strings.messageCollections),
          ),
        ),
        PopupMenuItem<String>(
          key: const Key('open-reminder-inbox'),
          value: _remindersKey,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.alarm_outlined),
            title: Text(strings.reminderInboxTitle),
          ),
        ),
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
            leading: const SettingsIconWithUpdateMark(),
            title: Text(strings.settingsTitle),
          ),
        ),
      ],
    );
  }
}

Future<void> _openSavedCollections(
  BuildContext context,
  StoredAccount account,
) async {
  final scope = ProviderScope.containerOf(context, listen: false);
  final route = ModalRoute.of(context);
  bool current() =>
      context.mounted &&
      (route == null || route.isCurrent) &&
      scope.read(selectedAccountProvider).valueOrNull?.id == account.id;
  final link = await showMessageCollections(
    context,
    account: AccountId.parse(account.id),
    store: scope.read(messageCollectionStoreProvider),
  );
  if (link == null || !current()) return;
  try {
    final conversation = await scope
        .read(accountRepositoryProvider)
        .getConversation(accountId: account.id, token: link.roomToken);
    if (!current()) return;
    if (conversation == null) {
      throw const MessageSearchThreadException(
        MessageSearchThreadError.unavailable,
      );
    }
    final target = MessageDestinationTarget(
      roomToken: ConversationToken.parse(
        link.roomToken,
        path: 'collection.room',
      ),
      messageId: link.messageId,
      threadId: link.threadId,
    );
    final thread =
        target.threadId != null && target.threadId != target.messageId
        ? await resolveMessageThread(
            repository: scope.read(chatRepositoryProvider),
            accountId: account.id,
            target: target,
            synchronizeThread: () => scope
                .read(chatServiceProvider)
                .syncRoom(
                  accountId: account.id,
                  roomToken: link.roomToken,
                  threadId: target.threadId,
                  readerIsActive: () =>
                      current() && scope.read(windowActiveProvider),
                ),
          )
        : null;
    if (!context.mounted || !current()) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => buildMessageDestination(
          account: account,
          conversation: conversation,
          target: target,
          threadContext: thread,
        ),
      ),
    );
  } catch (_) {
    if (context.mounted && current()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).jumpToMessageConversationMissing,
          ),
        ),
      );
    }
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
