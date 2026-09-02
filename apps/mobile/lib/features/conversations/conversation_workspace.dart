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
    this.listCollapsed = false,
    this.onToggleList = _ignoreToggle,
  });

  static void _ignoreToggle() {}

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

  /// Whether the conversation list is folded away on a wide window.
  final bool listCollapsed;
  final VoidCallback onToggleList;

  @override
  Widget build(BuildContext context) {
    // The same search the toolbar button opens, on the shortcut every desktop
    // uses for it. Both chords are bound: a phone never produces either, so
    // the only thing worth gating on is whether the server can search at all.
    if (!talkFeaturesOf(account).contains('unified-search')) {
      return _buildLayout(context);
    }
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            openMessageSearch(context, account.id),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
            openMessageSearch(context, account.id),
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
          listCollapsed: listCollapsed,
          onToggleList: onToggleList,
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
    final conversationList = _buildConversationList(context, strings);
    final selected = selectedConversation;
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return _buildIosNavigator(conversationList, selected);
    }
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
        child: _EdgeSwipeBack(
          background: conversationList,
          onDismiss: onCloseConversation,
          child: _buildConversation(selected),
        ),
      );
    }
    return conversationList;
  }

  Widget _buildIosNavigator(
    Widget conversationList,
    CachedConversation? selected,
  ) {
    return _IosCompactNavigator(
      accountId: account.id,
      conversationToken: selected?.token,
      conversationList: conversationList,
      conversation: selected == null ? null : _buildConversation(selected),
      onCloseConversation: onCloseConversation,
    );
  }

  Widget _buildConversation(CachedConversation selected) {
    return Scaffold(
      key: const Key('conversation-shell-compact-conversation'),
      body: SafeArea(
        child: DesktopAttachmentDrop(
          child: PresenceChatRoomPane(
            account: account,
            conversation: selected,
            onClose: onCloseConversation,
          ),
        ),
      ),
    );
  }

  Widget _buildConversationList(
    BuildContext context,
    AppLocalizations strings,
  ) {
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
          // Without `unified-search` the server has no provider to ask, and
          // the screen would only ever reach a dead end.
          if (talkFeaturesOf(account).contains('unified-search'))
            IconButton(
              key: const Key('open-message-search'),
              onPressed: () => openMessageSearch(context, account.id),
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

final class _IosCompactNavigator extends StatefulWidget {
  const _IosCompactNavigator({
    required this.accountId,
    required this.conversationToken,
    required this.conversationList,
    required this.conversation,
    required this.onCloseConversation,
  });

  final String accountId;
  final String? conversationToken;
  final Widget conversationList;
  final Widget? conversation;
  final VoidCallback onCloseConversation;

  @override
  State<_IosCompactNavigator> createState() => _IosCompactNavigatorState();
}

final class _IosCompactNavigatorState extends State<_IosCompactNavigator> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final conversationPageKey = widget.conversationToken == null
        ? null
        : ValueKey<Object>((
            'conversation',
            widget.accountId,
            widget.conversationToken,
          ));
    return KeyedSubtree(
      key: const Key('conversation-shell-compact-navigator'),
      child: NavigatorPopHandler<void>(
        onPopWithResult: (result) =>
            _navigatorKey.currentState!.pop<void>(result),
        child: Navigator(
          key: _navigatorKey,
          pages: <Page<void>>[
            MaterialPage<void>(
              key: ValueKey<Object>(('conversation-list', widget.accountId)),
              name: '/conversations',
              allowSnapshotting: false,
              child: widget.conversationList,
            ),
            if (widget.conversation != null)
              MaterialPage<void>(
                key: conversationPageKey,
                name: '/conversation',
                allowSnapshotting: false,
                child: widget.conversation!,
              ),
          ],
          onDidRemovePage: (page) {
            if (page.key == conversationPageKey) {
              widget.onCloseConversation();
            }
          },
        ),
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
    required this.listCollapsed,
    required this.onToggleList,
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

  /// Whether the conversation list is folded away, leaving the window to the
  /// conversation. Held by the shell, not here: a resize rebuilds this widget
  /// and would lose it.
  final bool listCollapsed;
  final VoidCallback onToggleList;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('conversation-shell-expanded'),
      body: SafeArea(
        child: Row(
          children: [
            // Only drawn when it has something to switch between. With one
            // account the rail is 88 px of window height showing a logo, an
            // avatar whose own onTap is null, and two buttons that the
            // account menu in the header already carries. See
            // docs/architecture/desktop-chrome.md, D-041.
            if (accounts.length > 1) ...[
              _AccountRail(
                selected: account,
                accounts: accounts,
                unreadByAccount: unreadByAccount,
                onSelect: onSelectAccount,
                onAdd: onAddAccount,
              ),
              const VerticalDivider(),
            ],
            if (!listCollapsed)
              SizedBox(
                key: const Key('conversation-list-pane'),
                width: context.listPaneWidth,
                child: Column(
                  children: [
                    ConstrainedBox(
                      key: const Key('conversation-list-header'),
                      constraints: BoxConstraints(
                        minHeight: context.paneHeaderHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                        child: Row(
                          children: [
                            // Takes the rail's place when the rail is gone, so
                            // switching accounts, adding one and reaching
                            // settings never depend on a pane that is not drawn.
                            if (accounts.length <= 1) ...[
                              _AccountMenu(
                                selected: account,
                                accounts: accounts,
                                unreadByAccount: unreadByAccount,
                                onSelect: onSelectAccount,
                                onAdd: onAddAccount,
                              ),
                              const SizedBox(width: 8),
                            ],
                            // No visible title: the pane is 300 px wide and
                            // already carries the account avatar plus three
                            // actions, so the word wrapped mid-syllable
                            // ("Konverzac / e"). The pane needs no label to be
                            // recognised, but a screen reader still gets one.
                            Expanded(
                              child: Semantics(
                                header: true,
                                label: strings.conversations,
                                child: const SizedBox.shrink(),
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
                              icon: const Icon(
                                Icons.chat_bubble_outline_rounded,
                              ),
                            ),
                            if (talkFeaturesOf(
                              account,
                            ).contains('unified-search'))
                              IconButton(
                                key: const Key('open-message-search'),
                                onPressed: () =>
                                    openMessageSearch(context, account.id),
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
            if (!listCollapsed) const VerticalDivider(),
            Expanded(
              key: const Key('conversation-detail-pane'),
              child: selectedConversation == null
                  ? const _SelectConversationPlaceholder()
                  : DesktopAttachmentDrop(
                      child: PresenceChatRoomPane(
                        account: account,
                        conversation: selectedConversation!,
                        onOpenDetails: onOpenDetails,
                        onToggleList: onToggleList,
                        listCollapsed: listCollapsed,
                      ),
                    ),
            ),
            if (detailsOpen && selectedConversation != null) ...[
              const VerticalDivider(),
              SizedBox(
                // `clamp(300px, 27vw, 500px)`, which is what Nextcloud's own
                // sidebar uses.
                width:
                    MediaQuery.sizeOf(
                      context,
                    ).width.clamp(300 / 0.27, 500 / 0.27) *
                    0.27,
                child: RoomDetailsScreen(
                  key: ValueKey((
                    account.id,
                    selectedConversation!.token,
                    account.talkFeaturesJson,
                  )),
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
    final icon = Icon(Icons.cloud_off_rounded, color: scheme.onErrorContainer);
    final text = Text(
      message,
      style: TextStyle(color: scheme.onErrorContainer),
    );
    final action = canReauthenticate
        ? TextButton(
            key: const Key('reauthenticate-account'),
            style: TextButton.styleFrom(
              foregroundColor: scheme.onErrorContainer,
            ),
            onPressed: onReauthenticate,
            child: Text(strings.reauthenticateAccountAction),
          )
        : null;
    // The action keeps its own intrinsic width, so `Expanded` on the message
    // cannot squeeze it: on a narrow screen at large text the row overflowed
    // instead of wrapping. Above roughly 1.3x the two go under each other.
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 21;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: scheme.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      icon,
                      const SizedBox(width: 10),
                      Expanded(child: text),
                    ],
                  ),
                  if (action != null)
                    Align(alignment: Alignment.centerLeft, child: action),
                ],
              )
            : Row(
                children: [
                  icon,
                  const SizedBox(width: 10),
                  Expanded(child: text),
                  ?action,
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

/// Drag from the left edge to put the conversation list back.
///
/// The compact shell swaps the list for the conversation inside one Scaffold
/// rather than pushing a route, so the platform's own back-edge gesture has
/// nothing to pop and simply did nothing - reported against the original iOS
/// app, where the same drag returns to the list.
///
/// The gesture lives on a narrow strip instead of the whole pane on purpose:
/// a message bubble takes horizontal drags of its own to open a reply, and
/// those start anywhere but the edge. Twenty-four points matches the width
/// iOS itself treats as the screen edge.
final class _EdgeSwipeBack extends StatefulWidget {
  const _EdgeSwipeBack({
    required this.background,
    required this.onDismiss,
    required this.child,
  });

  final Widget background;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

const double _edgeSwipeStripWidth = 24;
const double _edgeSwipeThreshold = 96;
const double _edgeSwipeMaximum = 160;
const double _edgeSwipeFlickDistance = 48;
const double _edgeSwipeFlickVelocity = 400;

final class _EdgeSwipeBackState extends State<_EdgeSwipeBack> {
  double _offset = 0;

  void _release({required bool dismiss}) {
    if (_offset != 0) {
      setState(() => _offset = 0);
    }
    if (dismiss) {
      widget.onDismiss();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (_offset > 0)
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                key: const Key('conversation-edge-swipe-preview'),
                child: HeroMode(enabled: false, child: widget.background),
              ),
            ),
          ),
        Transform.translate(offset: Offset(_offset, 0), child: widget.child),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _edgeSwipeStripWidth,
          child: GestureDetector(
            key: const Key('conversation-edge-swipe-back'),
            // Translucent so a tap on whatever sits under the strip still
            // reaches it; only horizontal drags are claimed here.
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: (details) {
              final next = (_offset + details.delta.dx).clamp(
                0.0,
                _edgeSwipeMaximum,
              );
              if (next != _offset) {
                setState(() => _offset = next);
              }
            },
            // A flick counts short of the full distance, but not on any
            // movement at all: the velocity estimate at the end of a slow
            // 30 point tug still clears 300, so the flick path asks for a
            // deliberate distance of its own.
            onHorizontalDragEnd: (details) => _release(
              dismiss:
                  _offset >= _edgeSwipeThreshold ||
                  (_offset >= _edgeSwipeFlickDistance &&
                      (details.primaryVelocity ?? 0) > _edgeSwipeFlickVelocity),
            ),
            onHorizontalDragCancel: () => _release(dismiss: false),
          ),
        ),
      ],
    );
  }
}
