part of 'conversation_shell.dart';

/// Below this the list and the conversation cannot sit side by side, so the
/// conversation moves onto the navigator instead.
const double kExpandedShellBreakpoint = 720;

final class ConversationWorkspace extends StatefulWidget {
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
    this.onOpenCreatedConversation,
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

  /// Opens a room the new-conversation screen just created or resolved.
  final ValueChanged<String>? onOpenCreatedConversation;

  @override
  State<ConversationWorkspace> createState() => _ConversationWorkspaceState();
}

final class _ConversationWorkspaceState extends State<ConversationWorkspace> {
  /// Token already handed over to the compact shell as a pushed route. The
  /// expanded shell keeps a selected conversation beside the list, but the
  /// compact shell has no second pane, so narrowing the window would drop the
  /// open conversation off screen. Handing it to the navigator keeps it
  /// reachable and matches the official client, where the route is the source
  /// of truth.
  String? _handedOverToken;

  void _handOverToCompact(CachedConversation conversation) {
    if (_handedOverToken == conversation.token) {
      return;
    }
    _handedOverToken = conversation.token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onOpenConversation(conversation);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final accounts = widget.accounts;
    final unreadByAccount = widget.unreadByAccount;
    final conversations = widget.conversations;
    final selectedConversationToken = widget.selectedConversationToken;
    final loading = widget.loading;
    final syncing = widget.syncing;
    final onRefresh = widget.onRefresh;
    final onReauthenticate = widget.onReauthenticate;
    final onSelectAccount = widget.onSelectAccount;
    final onOpenCreatedConversation = widget.onOpenCreatedConversation;
    final onAddAccount = widget.onAddAccount;
    final onOpenConversation = widget.onOpenConversation;
    final onSelectConversation = widget.onSelectConversation;
    return LayoutBuilder(
      builder: (context, constraints) {
        final selectedConversation = conversations
            .where(
              (conversation) => conversation.token == selectedConversationToken,
            )
            .firstOrNull;
        if (constraints.maxWidth < kExpandedShellBreakpoint) {
          if (selectedConversation != null) {
            _handOverToCompact(selectedConversation);
          }
          return _CompactShell(
            account: account,
            accounts: accounts,
            unreadByAccount: unreadByAccount,
            conversations: conversations,
            loading: loading,
            syncing: syncing,
            onRefresh: onRefresh,
            onReauthenticate: onReauthenticate,
            onSelectAccount: onSelectAccount,
            onAddAccount: onAddAccount,
            onOpenConversation: onOpenConversation,
            onOpenCreatedConversation: onOpenCreatedConversation,
          );
        }
        _handedOverToken = null;
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
    required this.onOpenCreatedConversation,
  });

  final StoredAccount account;
  final List<StoredAccount> accounts;
  final Map<String, int> unreadByAccount;
  final List<CachedConversation> conversations;
  final bool loading;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final Future<void> Function()? onReauthenticate;
  final ValueChanged<String> onSelectAccount;
  final VoidCallback onAddAccount;
  final ValueChanged<CachedConversation> onOpenConversation;
  final ValueChanged<String>? onOpenCreatedConversation;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
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
                    ),
            ),
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
