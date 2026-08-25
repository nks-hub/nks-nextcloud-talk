import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/brand_mark.dart';
import '../../core/foreground_sync_loop.dart';
import '../../core/giphy_reference.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../onboarding/onboarding_screen.dart';
import '../push/android_web_push_bridge.dart';
import 'conversation_avatar_widget.dart';
import 'conversation_presence.dart';
import 'conversation_sync_service.dart';

final class ConversationShell extends ConsumerStatefulWidget {
  const ConversationShell({super.key});

  @override
  ConsumerState<ConversationShell> createState() => _ConversationShellState();
}

final class _ConversationShellState extends ConsumerState<ConversationShell>
    with WidgetsBindingObserver {
  String? _scheduledAccountId;
  String? _syncingAccountId;
  String? _selectedConversationToken;
  String? _selectedAccountId;
  ForegroundSyncLoop? _liveSyncLoop;
  StreamSubscription<void>? _pushOpenSubscription;
  var _liveSyncGeneration = 0;
  var _isForeground = true;
  var _handlingPushOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _isForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _attachPushNavigation();
      }
    });
  }

  void _attachPushNavigation() {
    final coordinator = ref.read(androidPushCoordinatorProvider);
    if (coordinator == null || _pushOpenSubscription != null) {
      return;
    }
    _pushOpenSubscription = coordinator.notificationOpened.listen((_) {
      unawaited(_drainPushNavigation());
    });
    unawaited(_drainPushNavigation());
  }

  Future<void> _drainPushNavigation() async {
    if (_handlingPushOpen) {
      return;
    }
    final coordinator = ref.read(androidPushCoordinatorProvider);
    if (coordinator == null) {
      return;
    }
    _handlingPushOpen = true;
    try {
      while (mounted) {
        final open = coordinator.takeNextNotificationOpen();
        if (open == null) {
          return;
        }
        await _openPushNotification(open);
      }
    } finally {
      _handlingPushOpen = false;
    }
  }

  Future<void> _openPushNotification(AndroidNotificationOpen open) async {
    final roomToken = open.objectId;
    if (open.app != 'spreed' || roomToken == null || roomToken.isEmpty) {
      return;
    }
    final accounts = ref.read(accountRepositoryProvider);
    final account = await accounts.getAccount(open.accountId);
    if (account == null) {
      return;
    }
    await accounts.selectAccount(account.id);
    try {
      await ref
          .read(conversationSyncServiceProvider)
          .sync(account.id, forceFull: true);
    } on ConversationSyncException {
      // A cached room can still be opened while the account retries its sync.
    }
    final conversation = await accounts.getConversation(
      accountId: account.id,
      token: roomToken,
    );
    if (!mounted || conversation == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => PresenceChatRoomScreen(
          account: account,
          conversation: conversation,
        ),
      ),
    );
  }

  void _scheduleInitialSync(StoredAccount account) {
    _selectedAccountId = account.id;
    if (!_isForeground || _scheduledAccountId == account.id) {
      return;
    }
    _scheduledAccountId = account.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isForeground && _selectedAccountId == account.id) {
        unawaited(_replaceLiveSync(account.id));
      }
    });
  }

  void _clearSelectedAccount() {
    final needsStop =
        _selectedAccountId != null ||
        _scheduledAccountId != null ||
        _liveSyncLoop != null;
    _selectedAccountId = null;
    _scheduledAccountId = null;
    if (needsStop) {
      unawaited(_stopLiveSync());
    }
  }

  Future<void> _replaceLiveSync(String accountId) async {
    final generation = ++_liveSyncGeneration;
    final previous = _liveSyncLoop;
    _liveSyncLoop = null;
    if (previous != null) {
      await previous.stop();
    }
    if (!mounted ||
        !_isForeground ||
        _selectedAccountId != accountId ||
        generation != _liveSyncGeneration) {
      return;
    }

    var showProgress = true;
    void finishCycle() {
      if (!mounted || _syncingAccountId != accountId) {
        return;
      }
      setState(() => _syncingAccountId = null);
      showProgress = false;
    }

    final loop = ForegroundSyncLoop(
      task: (cancellation) async {
        try {
          await ref
              .read(conversationSyncServiceProvider)
              .sync(accountId, abortTrigger: cancellation);
        } on ConversationSyncException catch (error) {
          if (_isPermanentConversationSyncError(error.code)) {
            finishCycle();
            await cancellation;
            return;
          }
          rethrow;
        }
      },
      successInterval: const Duration(seconds: 15),
      retryBaseDelay: const Duration(seconds: 2),
      retryMaximumDelay: const Duration(seconds: 30),
      onCycleStarted: () {
        if (showProgress && mounted && _syncingAccountId != accountId) {
          setState(() => _syncingAccountId = accountId);
        }
      },
      onSuccess: finishCycle,
      onError: (_) => finishCycle(),
    );
    _liveSyncLoop = loop;
    loop.start();
  }

  Future<void> _stopLiveSync() async {
    ++_liveSyncGeneration;
    final loop = _liveSyncLoop;
    _liveSyncLoop = null;
    if (loop != null) {
      await loop.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_isForeground == resumed) {
      return;
    }
    _isForeground = resumed;
    _scheduledAccountId = null;
    if (!resumed) {
      unawaited(_stopLiveSync());
      return;
    }
    final accountId = _selectedAccountId;
    if (accountId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isForeground && _selectedAccountId == accountId) {
          _scheduledAccountId = accountId;
          unawaited(_replaceLiveSync(accountId));
        }
      });
    }
    final pushCoordinator = ref.read(androidPushCoordinatorProvider);
    if (pushCoordinator != null) {
      unawaited(pushCoordinator.reconcileAll());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_pushOpenSubscription?.cancel());
    unawaited(_stopLiveSync());
    super.dispose();
  }

  Future<void> _refresh(String accountId) async {
    setState(() => _syncingAccountId = accountId);
    try {
      await ref
          .read(conversationSyncServiceProvider)
          .sync(accountId, forceFull: true);
    } on ConversationSyncException {
      // The account-scoped error code is persisted and rendered from Drift.
    } finally {
      if (mounted && _syncingAccountId == accountId) {
        setState(() => _syncingAccountId = null);
      }
    }
  }

  Future<void> _selectAccount(String accountId) async {
    if (_scheduledAccountId == accountId) {
      return;
    }
    _selectedConversationToken = null;
    await ref.read(accountRepositoryProvider).selectAccount(accountId);
  }

  Future<void> _addAccount() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => OnboardingScreen(
          onAccountAdded: (_) => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accountsValue = ref.watch(accountsProvider);
    final selectedValue = ref.watch(selectedAccountProvider);
    return selectedValue.when(
      loading: () => const _LoadingShell(),
      error: (_, _) => const _LoadingShell(),
      data: (selected) {
        if (selected == null) {
          _clearSelectedAccount();
          return const OnboardingScreen();
        }
        _scheduleInitialSync(selected);
        final accounts = accountsValue.valueOrNull ?? [selected];
        final conversationsValue = ref.watch(
          conversationsProvider(selected.id),
        );
        final conversations = conversationsValue.valueOrNull ?? const [];
        return ConversationWorkspace(
          account: selected,
          accounts: accounts,
          conversations: conversations,
          selectedConversationToken: _selectedConversationToken,
          loading: conversationsValue.isLoading,
          syncing: _syncingAccountId == selected.id,
          onRefresh: () => _refresh(selected.id),
          onSelectAccount: _selectAccount,
          onAddAccount: _addAccount,
          onOpenConversation: (conversation) {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (context) => PresenceChatRoomScreen(
                  account: selected,
                  conversation: conversation,
                ),
              ),
            );
          },
          onSelectConversation: (conversation) {
            setState(() => _selectedConversationToken = conversation.token);
          },
        );
      },
    );
  }
}

bool _isPermanentConversationSyncError(ConversationSyncError error) {
  return switch (error) {
    ConversationSyncError.rateLimited ||
    ConversationSyncError.serviceUnavailable ||
    ConversationSyncError.network => false,
    ConversationSyncError.accountMissing ||
    ConversationSyncError.credentialMissing ||
    ConversationSyncError.talkUnavailable ||
    ConversationSyncError.conversationProfileUnsupported ||
    ConversationSyncError.reauthenticationRequired ||
    ConversationSyncError.upgradeRequired ||
    ConversationSyncError.invalidResponse => true,
  };
}

final class ConversationWorkspace extends StatelessWidget {
  const ConversationWorkspace({
    super.key,
    required this.account,
    required this.accounts,
    required this.conversations,
    required this.selectedConversationToken,
    required this.loading,
    required this.syncing,
    required this.onRefresh,
    required this.onSelectAccount,
    required this.onAddAccount,
    required this.onOpenConversation,
    required this.onSelectConversation,
  });

  final StoredAccount account;
  final List<StoredAccount> accounts;
  final List<CachedConversation> conversations;
  final String? selectedConversationToken;
  final bool loading;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onSelectAccount;
  final VoidCallback onAddAccount;
  final ValueChanged<CachedConversation> onOpenConversation;
  final ValueChanged<CachedConversation> onSelectConversation;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return _CompactShell(
            account: account,
            accounts: accounts,
            conversations: conversations,
            loading: loading,
            syncing: syncing,
            onRefresh: onRefresh,
            onSelectAccount: onSelectAccount,
            onAddAccount: onAddAccount,
            onOpenConversation: onOpenConversation,
          );
        }
        final selectedConversation = conversations
            .where(
              (conversation) => conversation.token == selectedConversationToken,
            )
            .firstOrNull;
        return _ExpandedShell(
          account: account,
          accounts: accounts,
          conversations: conversations,
          selectedConversation: selectedConversation,
          loading: loading,
          syncing: syncing,
          onRefresh: onRefresh,
          onSelectAccount: onSelectAccount,
          onAddAccount: onAddAccount,
          onSelectConversation: onSelectConversation,
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
    required this.conversations,
    required this.loading,
    required this.syncing,
    required this.onRefresh,
    required this.onSelectAccount,
    required this.onAddAccount,
    required this.onOpenConversation,
  });

  final StoredAccount account;
  final List<StoredAccount> accounts;
  final List<CachedConversation> conversations;
  final bool loading;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onSelectAccount;
  final VoidCallback onAddAccount;
  final ValueChanged<CachedConversation> onOpenConversation;

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
            onPressed: syncing ? null : onRefresh,
            tooltip: strings.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          _AccountMenu(
            selected: account,
            accounts: accounts,
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
            _SyncNotice(errorCode: account.lastSyncError!),
          Expanded(
            child: _ConversationList(
              account: account,
              conversations: conversations,
              loading: loading,
              onRefresh: onRefresh,
              onSelect: onOpenConversation,
            ),
          ),
        ],
      ),
    );
  }
}

final class _ExpandedShell extends StatelessWidget {
  const _ExpandedShell({
    required this.account,
    required this.accounts,
    required this.conversations,
    required this.selectedConversation,
    required this.loading,
    required this.syncing,
    required this.onRefresh,
    required this.onSelectAccount,
    required this.onAddAccount,
    required this.onSelectConversation,
  });

  final StoredAccount account;
  final List<StoredAccount> accounts;
  final List<CachedConversation> conversations;
  final CachedConversation? selectedConversation;
  final bool loading;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onSelectAccount;
  final VoidCallback onAddAccount;
  final ValueChanged<CachedConversation> onSelectConversation;

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
              onSelect: onSelectAccount,
              onAdd: onAddAccount,
            ),
            const VerticalDivider(),
            SizedBox(
              key: const Key('conversation-list-pane'),
              width: MediaQuery.sizeOf(context).width >= 1100 ? 390 : 330,
              child: Column(
                children: [
                  ConstrainedBox(
                    key: const Key('conversation-list-header'),
                    constraints: const BoxConstraints(minHeight: 72),
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
                    _SyncNotice(errorCode: account.lastSyncError!),
                  const Divider(),
                  Expanded(
                    child: _ConversationList(
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

final class _AccountRail extends StatelessWidget {
  const _AccountRail({
    required this.selected,
    required this.accounts,
    required this.onSelect,
    required this.onAdd,
  });

  final StoredAccount selected;
  final List<StoredAccount> accounts;
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
                              child: _AccountAvatar(account: account),
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
            child: IconButton.filledTonal(
              onPressed: onAdd,
              tooltip: strings.addAccount,
              icon: const Icon(Icons.add_rounded),
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
    required this.onSelect,
    required this.onAdd,
  });

  static const _addKey = '__add_account__';

  final StoredAccount selected;
  final List<StoredAccount> accounts;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      tooltip: strings.switchAccount,
      icon: _AccountAvatar(account: selected),
      onSelected: (value) => value == _addKey ? onAdd() : onSelect(value),
      itemBuilder: (context) => [
        for (final account in accounts)
          PopupMenuItem<String>(
            value: account.id,
            enabled: account.id != selected.id,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _AccountAvatar(account: account),
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
      ],
    );
  }
}

final class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.account});

  final StoredAccount account;

  @override
  Widget build(BuildContext context) {
    final initial = account.loginName.trim().isEmpty
        ? '?'
        : String.fromCharCode(
            account.loginName.trim().runes.first,
          ).toUpperCase();
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      backgroundColor: scheme.tertiaryContainer,
      foregroundColor: scheme.onTertiaryContainer,
      child: Text(initial),
    );
  }
}

final class _ConversationList extends StatelessWidget {
  const _ConversationList({
    required this.account,
    required this.conversations,
    required this.loading,
    required this.onRefresh,
    required this.onSelect,
    this.selectedToken,
  });

  final StoredAccount account;
  final List<CachedConversation> conversations;
  final bool loading;
  final Future<void> Function() onRefresh;
  final ValueChanged<CachedConversation> onSelect;
  final String? selectedToken;

  @override
  Widget build(BuildContext context) {
    if (loading && conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (conversations.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [SizedBox(height: 120), _EmptyConversations()],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: conversations.length,
        separatorBuilder: (_, _) => const Divider(indent: 84),
        itemBuilder: (context, index) {
          final conversation = conversations[index];
          return _ConversationTile(
            account: account,
            conversation: conversation,
            selected: conversation.token == selectedToken,
            onTap: () => onSelect(conversation),
          );
        },
      ),
    );
  }
}

final class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.account,
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final preview = normalizeGiphyReferencePreview(
      conversation.lastMessageText ?? strings.lastMessageUnavailable,
    );
    final semanticsValue = [
      preview,
      _formatActivity(context, conversation.lastActivity),
      strings.unreadMessages(conversation.unreadMessages),
    ].join(', ');
    return Semantics(
      key: Key('conversation-tile-${conversation.token}'),
      container: true,
      button: true,
      selected: selected,
      label: conversation.displayName,
      value: semanticsValue,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 80),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    ConversationAvatar(
                      account: account,
                      conversation: conversation,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (conversation.favorite) ...[
                                Icon(
                                  Icons.star_rounded,
                                  size: 18,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(
                                  conversation.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              if (ConversationPresence.fromConversation(
                                    conversation,
                                  ) !=
                                  null) ...[
                                const SizedBox(width: 7),
                                ConversationPresenceBadge(
                                  conversation: conversation,
                                ),
                              ],
                              const SizedBox(width: 8),
                              Text(
                                _formatActivity(
                                  context,
                                  conversation.lastActivity,
                                ),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  preview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                              ),
                              if (conversation.unreadMessages > 0) ...[
                                const SizedBox(width: 8),
                                _UnreadBadge(
                                  count: conversation.unreadMessages,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: AppLocalizations.of(context).unreadMessages(count),
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            count > 99 ? '99+' : '$count',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

final class _EmptyConversations extends StatelessWidget {
  const _EmptyConversations();

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 52,
            color: scheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            strings.noConversations,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            strings.noConversationsBody,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

final class _SyncNotice extends StatelessWidget {
  const _SyncNotice({required this.errorCode});

  final String errorCode;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final message = _syncErrorMessage(strings, errorCode);
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
          ],
        ),
      ),
    );
  }
}

final class ConversationDetailsScreen extends StatelessWidget {
  const ConversationDetailsScreen({
    super.key,
    required this.account,
    required this.conversation,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(conversation.displayName)),
      body: SafeArea(
        child: ConversationDetailsPane(
          account: account,
          conversation: conversation,
        ),
      ),
    );
  }
}

final class ConversationDetailsPane extends StatelessWidget {
  const ConversationDetailsPane({
    super.key,
    required this.account,
    required this.conversation,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 34,
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: const Icon(Icons.forum_rounded, size: 34),
              ),
              const SizedBox(height: 20),
              Text(
                conversation.displayName,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              if (conversation.description.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  conversation.description,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 28),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      _DetailRow(
                        icon: Icons.dns_outlined,
                        label: strings.server,
                        value: Uri.parse(account.serverUrl).host,
                      ),
                      const Divider(height: 28),
                      _DetailRow(
                        icon: Icons.person_outline_rounded,
                        label: strings.signedInAs,
                        value: account.loginName,
                      ),
                      const Divider(height: 28),
                      _DetailRow(
                        icon: Icons.mark_chat_unread_outlined,
                        label: strings.conversations,
                        value: strings.unreadMessages(
                          conversation.unreadMessages,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: scheme.primary),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 3),
              SelectableText(
                value,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ],
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

String _formatActivity(BuildContext context, int unixSeconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
  ).toLocal();
  final now = DateTime.now();
  final localizations = MaterialLocalizations.of(context);
  if (date.year == now.year && date.month == now.month && date.day == now.day) {
    return localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date));
  }
  return localizations.formatCompactDate(date);
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
