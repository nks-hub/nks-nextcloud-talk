part of 'conversation_shell.dart';

/// Below this the list and the conversation cannot sit side by side, so the
/// conversation moves onto the navigator instead.
const double kExpandedShellBreakpoint = 720;

final class ConversationWorkspace extends StatelessWidget {
  const ConversationWorkspace({
    super.key,
    required this.account,
    required this.accounts,
    this.unreadByAccount = const {},
    required this.conversations,
    required this.selectedConversationToken,
    required this.loading,
    required this.syncing,
    required this.onRefresh,
    this.onReauthenticate,
    required this.onSelectAccount,
    required this.onAddAccount,
    required this.onOpenConversation,
    required this.onSelectConversation,
    required this.onCloseConversation,
    this.onOpenCreatedConversation,
    this.detailsOpen = false,
    this.onOpenDetails,
    this.onCloseDetails,
  });

  final StoredAccount account;
  final List<StoredAccount> accounts;

  /// Unread message count per account id, used only to badge the account
  /// switcher. Defaults to empty so existing data-driven call sites (and
  /// tests) that don't care about badges keep working unchanged.
  final Map<String, int> unreadByAccount;
  final List<CachedConversation> conversations;
  final String? selectedConversationToken;
  final bool loading;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final Future<void> Function()? onReauthenticate;
  final ValueChanged<String> onSelectAccount;
  final VoidCallback onAddAccount;
  final ValueChanged<CachedConversation> onOpenConversation;
  final ValueChanged<CachedConversation> onSelectConversation;

  /// Clears the selection, returning the narrow layout to the list.
  final VoidCallback onCloseConversation;

  /// Opens a room the new-conversation screen just created or resolved.
  final ValueChanged<String>? onOpenCreatedConversation;

  /// Whether the conversation's details are showing beside it.
  ///
  /// Held by the shell for the same reason the selected token is: it has to
  /// survive a resize, and the layout is the wrong place to keep state that
  /// the layout itself destroys.
  final bool detailsOpen;
  final VoidCallback? onOpenDetails;
  final VoidCallback? onCloseDetails;

  @override
  Widget build(BuildContext context) {
    // The same search the toolbar button opens, on the shortcut every desktop
    // uses for it. Both chords are bound unconditionally: a phone never
    // produces either, so there is nothing to gate on.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _openMessageSearch(context, account.id),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
            _openMessageSearch(context, account.id),
      },
      child: _buildLayout(context),
    );
  }

  Widget _buildLayout(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final selectedConversation = conversations
            .where(
              (conversation) => conversation.token == selectedConversationToken,
            )
            .firstOrNull;
        if (constraints.maxWidth < kExpandedShellBreakpoint) {
          return _CompactShell(
            account: account,
            accounts: accounts,
            unreadByAccount: unreadByAccount,
            conversations: conversations,
            selectedConversation: selectedConversation,
            loading: loading,
            syncing: syncing,
            onRefresh: onRefresh,
            onReauthenticate: onReauthenticate,
            onSelectAccount: onSelectAccount,
            onAddAccount: onAddAccount,
            onOpenConversation: onOpenConversation,
            onCloseConversation: onCloseConversation,
            onOpenCreatedConversation: onOpenCreatedConversation,
          );
        }
        return _ExpandedShell(
          account: account,
          accounts: accounts,
          unreadByAccount: unreadByAccount,
          conversations: conversations,
          selectedConversation: selectedConversation,
          loading: loading,
          syncing: syncing,
          onRefresh: onRefresh,
          onReauthenticate: onReauthenticate,
          onSelectAccount: onSelectAccount,
          onAddAccount: onAddAccount,
          onSelectConversation: onSelectConversation,
          onOpenCreatedConversation: onOpenCreatedConversation,
          detailsOpen: detailsOpen,
          onOpenDetails: onOpenDetails,
          onCloseDetails: onCloseDetails,
        );
      },
    );
  }
}

final class _LoadingShell extends StatelessWidget {
  const _LoadingShell();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

final class _CompactShell extends StatelessWidget {
  const _CompactShell({
    required this.account,
    required this.accounts,
    this.unreadByAccount = const {},
    required this.conversations,
    required this.loading,
    required this.syncing,
    required this.onRefresh,
    this.onReauthenticate,
    required this.onSelectAccount,
    required this.onAddAccount,
    required this.onOpenConversation,
    required this.onCloseConversation,
    required this.onOpenCreatedConversation,
    this.selectedConversation,
  });

  final StoredAccount account;
  final List<StoredAccount> accounts;
  final Map<String, int> unreadByAccount;
  final List<CachedConversation> conversations;
  final CachedConversation? selectedConversation;
  final bool loading;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final Future<void> Function()? onReauthenticate;
  final ValueChanged<String> onSelectAccount;
  final VoidCallback onAddAccount;
  final ValueChanged<CachedConversation> onOpenConversation;
  final VoidCallback onCloseConversation;
  final ValueChanged<String>? onOpenCreatedConversation;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final selected = selectedConversation;
    if (selected != null) {
      // One pane, so the conversation takes the list's place instead of being
      // pushed. Selection stays the only record of what is open, which is what
      // lets a widened window put it back beside the list.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            onCloseConversation();
          }
        },
        child: Scaffold(
          key: const Key('conversation-shell-compact-conversation'),
          body: SafeArea(
            child: PresenceChatRoomPane(
              account: account,
              conversation: selected,
              onClose: onCloseConversation,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      key: const Key('conversation-shell-compact'),
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const BrandMark(size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(strings.conversations),
                  Text(
                    Uri.parse(account.serverUrl).host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('open-message-search'),
            onPressed: () => _openMessageSearch(context, account.id),
            tooltip: strings.searchMessagesTooltip,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            onPressed: syncing ? null : onRefresh,
            tooltip: strings.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          _AccountMenu(
            selected: account,
            accounts: accounts,
            unreadByAccount: unreadByAccount,
            onSelect: onSelectAccount,
            onAdd: onAddAccount,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (syncing) const LinearProgressIndicator(minHeight: 3),
          if (account.lastSyncError != null)
            _SyncNotice(
              errorCode: account.lastSyncError!,
              onReauthenticate: onReauthenticate,
            ),
          Expanded(
            child: ConversationListView(
              account: account,
              conversations: conversations,
              loading: loading,
              onRefresh: onRefresh,
              onSelect: onOpenConversation,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('open-new-conversation'),
        onPressed: () => _openNewConversation(
          context,
          account.id,
          onRefresh,
          onCreated: onOpenCreatedConversation,
        ),
        tooltip: strings.newConversationTitle,
        child: const Icon(Icons.chat_bubble_outline_rounded),
      ),
    );
  }
}

final class _ExpandedShell extends StatelessWidget {
  const _ExpandedShell({
    required this.account,
    required this.accounts,
    this.unreadByAccount = const {},
    required this.conversations,
    required this.selectedConversation,
    required this.loading,
    required this.syncing,
    required this.onRefresh,
    this.onReauthenticate,
    required this.onSelectAccount,
    required this.onAddAccount,
    required this.onSelectConversation,
    required this.onOpenCreatedConversation,
    required this.detailsOpen,
    required this.onOpenDetails,
    required this.onCloseDetails,
  });

  final StoredAccount account;
  final List<StoredAccount> accounts;
  final Map<String, int> unreadByAccount;
  final List<CachedConversation> conversations;
  final CachedConversation? selectedConversation;
  final bool loading;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final Future<void> Function()? onReauthenticate;
  final ValueChanged<String> onSelectAccount;
  final VoidCallback onAddAccount;
  final ValueChanged<CachedConversation> onSelectConversation;
  final ValueChanged<String>? onOpenCreatedConversation;
  final bool detailsOpen;
  final VoidCallback? onOpenDetails;
  final VoidCallback? onCloseDetails;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('conversation-shell-expanded'),
      body: SafeArea(
        child: Row(
          children: [
            _AccountRail(
              selected: account,
              accounts: accounts,
              unreadByAccount: unreadByAccount,
              onSelect: onSelectAccount,
              onAdd: onAddAccount,
            ),
            const VerticalDivider(),
            SizedBox(
              key: const Key('conversation-list-pane'),
              width: context.listPaneWidth,
              child: Column(
                children: [
                  ConstrainedBox(
                    key: const Key('conversation-list-header'),
                    constraints: BoxConstraints(minHeight: context.paneHeaderHeight),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              strings.conversations,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            key: const Key('open-new-conversation'),
                            onPressed: () => _openNewConversation(
                              context,
                              account.id,
                              onRefresh,
                              onCreated: onOpenCreatedConversation,
                            ),
                            tooltip: strings.newConversationTitle,
                            icon: const Icon(Icons.chat_bubble_outline_rounded),
                          ),
                          IconButton(
                            key: const Key('open-message-search'),
                            onPressed: () =>
                                _openMessageSearch(context, account.id),
                            tooltip: strings.searchMessagesTooltip,
                            icon: const Icon(Icons.search),
                          ),
                          IconButton(
                            onPressed: syncing ? null : onRefresh,
                            tooltip: strings.refresh,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (syncing) const LinearProgressIndicator(minHeight: 3),
                  if (account.lastSyncError != null)
                    _SyncNotice(
                      errorCode: account.lastSyncError!,
                      onReauthenticate: onReauthenticate,
                    ),
                  const Divider(),
                  Expanded(
                    child: ConversationListView(
                      account: account,
                      conversations: conversations,
                      loading: loading,
                      onRefresh: onRefresh,
                      onSelect: onSelectConversation,
                      selectedToken: selectedConversation?.token,
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(),
            Expanded(
              key: const Key('conversation-detail-pane'),
              child: selectedConversation == null
                  ? const _SelectConversationPlaceholder()
                  : PresenceChatRoomPane(
                      account: account,
                      conversation: selectedConversation!,
                      onOpenDetails: onOpenDetails,
                    ),
            ),
            if (detailsOpen && selectedConversation != null) ...[
              const VerticalDivider(),
              SizedBox(
                // `clamp(300px, 27vw, 500px)`, which is what Nextcloud's own
                // sidebar uses.
                width: MediaQuery.sizeOf(
                  context,
                ).width.clamp(300 / 0.27, 500 / 0.27) * 0.27,
                child: RoomDetailsScreen(
                  account: account,
                  conversation: selectedConversation!,
                  onClose: onCloseDetails,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _SyncNotice extends StatelessWidget {
  const _SyncNotice({required this.errorCode, this.onReauthenticate});

  final String errorCode;
  final Future<void> Function()? onReauthenticate;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final message = _syncErrorMessage(strings, errorCode);
    final error = ConversationSyncError.values
        .where((value) => value.name == errorCode)
        .firstOrNull;
    final canReauthenticate =
        onReauthenticate != null &&
        (error == ConversationSyncError.credentialMissing ||
            error == ConversationSyncError.reauthenticationRequired);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: scheme.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            if (canReauthenticate)
              TextButton(
                key: const Key('reauthenticate-account'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onErrorContainer,
                ),
                onPressed: onReauthenticate,
                child: Text(strings.reauthenticateAccountAction),
              ),
          ],
        ),
      ),
    );
  }
}

final class _SelectConversationPlaceholder extends StatelessWidget {
  const _SelectConversationPlaceholder();

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_outlined, size: 58, color: scheme.primary),
              const SizedBox(height: 18),
              Text(
                strings.selectConversation,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                strings.selectConversationBody,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _syncErrorMessage(AppLocalizations strings, String errorCode) {
  return switch (ConversationSyncError.values
      .where((value) => value.name == errorCode)
      .firstOrNull) {
    ConversationSyncError.credentialMissing ||
    ConversationSyncError.reauthenticationRequired =>
      strings.syncCredentialMissing,
    ConversationSyncError.talkUnavailable => strings.syncTalkUnavailable,
    ConversationSyncError.conversationProfileUnsupported =>
      strings.syncUnsupported,
    ConversationSyncError.rateLimited => strings.syncRateLimited,
    ConversationSyncError.serviceUnavailable => strings.syncUnavailable,
    ConversationSyncError.upgradeRequired => strings.syncUpgradeRequired,
    ConversationSyncError.invalidResponse => strings.syncInvalidResponse,
    ConversationSyncError.network => strings.syncNetwork,
    ConversationSyncError.accountMissing || null => strings.syncInvalidResponse,
  };
}
