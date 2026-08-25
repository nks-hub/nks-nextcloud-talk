import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/brand_mark.dart';
import '../../core/foreground_sync_loop.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../newconversation/new_conversation_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../push/android_web_push_bridge.dart';
import '../search/message_search_screen.dart';
import '../settings/settings_screen.dart';
import 'conversation_list_actions.dart';
import 'conversation_presence.dart';
import 'conversation_sync_service.dart';
import 'unread_badge.dart';

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
  StreamSubscription<void>? _deepLinkSubscription;
  var _liveSyncGeneration = 0;
  var _isForeground = true;
  var _handlingPushOpen = false;
  var _handlingDeepLink = false;

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
        _attachDeepLinkNavigation();
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
    await _openAccountConversation(open.accountId, roomToken);
  }

  void _attachDeepLinkNavigation() {
    final coordinator = ref.read(deepLinkCoordinatorProvider);
    if (coordinator == null || _deepLinkSubscription != null) {
      return;
    }
    _deepLinkSubscription = coordinator.linkAvailable.listen((_) {
      unawaited(_drainDeepLinks());
    });
    unawaited(_drainDeepLinks());
  }

  Future<void> _drainDeepLinks() async {
    if (_handlingDeepLink) {
      return;
    }
    final coordinator = ref.read(deepLinkCoordinatorProvider);
    if (coordinator == null) {
      return;
    }
    _handlingDeepLink = true;
    try {
      while (mounted) {
        final resolved = coordinator.takeNext();
        if (resolved == null) {
          return;
        }
        await _openAccountConversation(resolved.accountId, resolved.token.value);
      }
    } finally {
      _handlingDeepLink = false;
    }
  }

  /// Selects [accountId], resyncs it and opens [token] once it is cached.
  ///
  /// A missing account or a room that never lands in the cache leaves the
  /// app exactly where it was; this never navigates to a guess.
  Future<void> _openAccountConversation(String accountId, String token) async {
    final accounts = ref.read(accountRepositoryProvider);
    final account = await accounts.getAccount(accountId);
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
      token: token,
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
    unawaited(_deepLinkSubscription?.cancel());
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
    ref.watch(appIconBadgeSyncProvider);
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
          unreadByAccount: ref.watch(unreadSummaryProvider).byAccount,
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

void _openMessageSearch(BuildContext context, String accountId) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => Consumer(
        builder: (context, ref, _) => MessageSearchScreen(
          accountId: accountId,
          service: ref.watch(messageSearchServiceProvider),
          // Navigation into the found conversation is intentionally not
          // handled here; closing the search screen is all this entry
          // point does today.
          onResultSelected: (roomToken, messageId) =>
              Navigator.of(context).pop(),
        ),
      ),
    ),
  );
}

void _openSettings(BuildContext context) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (context) => const SettingsScreen()),
  );
}

/// Opens the new-conversation screen and, once the server has created the
/// room, refreshes the list so the caller's own conversation stream is the
/// single source of truth for what exists.
void _openNewConversation(
  BuildContext context,
  String accountId,
  Future<void> Function() onRefresh,
) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => NewConversationScreen(
        accountId: accountId,
        onConversationCreated: (_) {
          Navigator.of(context).pop();
          unawaited(onRefresh());
        },
      ),
    ),
  );
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
    this.unreadByAccount = const {},
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

  /// Unread message count per account id, used only to badge the account
  /// switcher. Defaults to empty so existing data-driven call sites (and
  /// tests) that don't care about badges keep working unchanged.
  final Map<String, int> unreadByAccount;
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
            unreadByAccount: unreadByAccount,
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
          unreadByAccount: unreadByAccount,
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
    this.unreadByAccount = const {},
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
  final Map<String, int> unreadByAccount;
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
            _SyncNotice(errorCode: account.lastSyncError!),
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
        onPressed: () => _openNewConversation(context, account.id, onRefresh),
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
    required this.onSelectAccount,
    required this.onAddAccount,
    required this.onSelectConversation,
  });

  final StoredAccount account;
  final List<StoredAccount> accounts;
  final Map<String, int> unreadByAccount;
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
              unreadByAccount: unreadByAccount,
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
                            key: const Key('open-new-conversation'),
                            onPressed: () => _openNewConversation(
                              context,
                              account.id,
                              onRefresh,
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
                    _SyncNotice(errorCode: account.lastSyncError!),
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
                                unreadCount:
                                    unreadByAccount[account.id] ?? 0,
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
