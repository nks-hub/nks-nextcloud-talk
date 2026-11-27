part of 'conversation_shell.dart';

const double _inboxRailWidth = 56;

Color _inboxSurface(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return scheme.brightness == Brightness.dark
      ? scheme.surface
      : scheme.surfaceContainerLow;
}

enum _InboxDestination {
  messages(Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded),
  threads(Icons.forum_outlined, Icons.forum_rounded),
  calls(Icons.phone_outlined, Icons.phone_rounded);

  const _InboxDestination(this.icon, this.selectedIcon);
  final IconData icon;
  final IconData selectedIcon;

  String label(AppLocalizations strings) => switch (this) {
    messages => strings.inboxMessages,
    threads => strings.threadManagementTitle,
    calls => strings.settingsCallsSection,
  };
}

final class _InboxNavigationHost extends StatefulWidget {
  const _InboxNavigationHost({super.key, required this.child});
  final Widget child;

  @override
  State<_InboxNavigationHost> createState() => _InboxNavigationHostState();
}

final class _InboxNavigationHostState extends State<_InboxNavigationHost> {
  final selection = ValueNotifier(_InboxDestination.messages);

  @override
  void dispose() {
    selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _InboxScope(selection: selection, child: widget.child);
}

final class _InboxScope
    extends InheritedNotifier<ValueNotifier<_InboxDestination>> {
  const _InboxScope({
    required ValueNotifier<_InboxDestination> selection,
    required super.child,
  }) : super(notifier: selection);

  static ValueNotifier<_InboxDestination> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InboxScope>()!.notifier!;
}

final class _InboxNavigationBar extends StatelessWidget {
  const _InboxNavigationBar();

  @override
  Widget build(BuildContext context) {
    final selection = _InboxScope.of(context);
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return NavigationBar(
      key: const Key('inbox-bottom-navigation'),
      height: 64,
      elevation: 0,
      backgroundColor: colors.surface,
      indicatorColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
      ),
      selectedIndex: selection.value.index,
      onDestinationSelected: (index) =>
          selection.value = _InboxDestination.values[index],
      destinations: [
        for (final destination in _InboxDestination.values)
          NavigationDestination(
            key: Key('inbox-nav-${destination.name}'),
            icon: Icon(destination.icon, size: 22),
            selectedIcon: Icon(
              destination.selectedIcon,
              size: 22,
              color: colors.primary,
            ),
            label: destination.label(strings),
          ),
      ],
    );
  }
}

final class _InboxRailButtons extends StatelessWidget {
  const _InboxRailButtons({this.onReveal});
  final VoidCallback? onReveal;

  @override
  Widget build(BuildContext context) {
    final selection = _InboxScope.of(context);
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final destination in _InboxDestination.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Semantics(
              selected: selection.value == destination,
              child: IconButton(
                key: Key('inbox-nav-${destination.name}'),
                tooltip: destination.label(strings),
                isSelected: selection.value == destination,
                selectedIcon: Icon(destination.selectedIcon),
                icon: Icon(destination.icon),
                style: IconButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  backgroundColor: selection.value == destination
                      ? Color.alphaBlend(
                          scheme.primary.withValues(alpha: 0.12),
                          scheme.surfaceContainerHigh,
                        )
                      : null,
                  foregroundColor: selection.value == destination
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                onPressed: () {
                  selection.value = destination;
                  onReveal?.call();
                },
              ),
            ),
          ),
      ],
    );
  }
}

final class _InboxRail extends StatelessWidget {
  const _InboxRail({required this.accountMenu, this.onReveal});
  final Widget accountMenu;
  final VoidCallback? onReveal;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('inbox-rail'),
    width: _inboxRailWidth,
    child: CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: BrandMark(size: 34),
              ),
              _InboxRailButtons(onReveal: onReveal),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: accountMenu,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

final class _InboxDesktopHeader extends StatelessWidget {
  const _InboxDesktopHeader({required this.onCompose, required this.onRefresh});
  final VoidCallback onCompose;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return ConstrainedBox(
      key: const Key('conversation-list-header'),
      constraints: BoxConstraints(minHeight: context.paneHeaderHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    strings.appTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('open-new-conversation'),
                  icon: const Icon(Icons.edit_square),
                  tooltip: strings.newConversationTitle,
                  onPressed: onCompose,
                ),
                IconButton(
                  key: const Key('refresh-conversations'),
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: strings.refresh,
                  onPressed: onRefresh,
                ),
              ],
            ),
            _InboxHeading(_InboxScope.of(context).value.label(strings)),
          ],
        ),
      ),
    );
  }
}

final class _InboxHeading extends StatelessWidget {
  const _InboxHeading(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(
      title,
      key: const Key('inbox-heading'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
      ),
    ),
  );
}

final class _InboxBody extends StatelessWidget {
  const _InboxBody({
    required this.account,
    required this.conversations,
    required this.loading,
    required this.onRefresh,
    required this.onSelect,
    this.selectedToken,
    this.showHeading = false,
  });
  final StoredAccount account;
  final List<CachedConversation> conversations;
  final bool loading;
  final Future<void> Function() onRefresh;
  final ValueChanged<CachedConversation> onSelect;
  final String? selectedToken;
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    final destination = _InboxScope.of(context).value;
    final strings = AppLocalizations.of(context);
    final heading = showHeading
        ? _InboxHeading(destination.label(strings))
        : null;
    if (destination == _InboxDestination.messages) {
      return ConversationListView(
        account: account,
        conversations: conversations,
        loading: loading,
        onRefresh: onRefresh,
        onSelect: onSelect,
        selectedToken: selectedToken,
        heading: heading,
        onMessageSearch: _hasUnifiedSearch(account)
            ? () => openMessageSearch(context, account.id)
            : null,
      );
    }
    if (loading && conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final threads = destination == _InboxDestination.threads;
    final features = talkFeaturesOf(account);
    final unsupported =
        threads &&
        !(features.contains('threads') && features.contains('chat-v2'));
    final rooms = unsupported
        ? const <CachedConversation>[]
        : conversations
              .where(
                (room) =>
                    !room.isArchived &&
                    (threads ||
                        ConversationCallState.fromConversation(room) != null),
              )
              .toList();
    return Material(
      type: MaterialType.transparency,
      child: RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView.builder(
          key: ValueKey(destination),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          itemCount: rooms.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (heading != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: heading,
                    ),
                  if (threads || rooms.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 14,
                      ),
                      child: Text(
                        unsupported
                            ? strings.threadManagementUnsupported
                            : rooms.isEmpty
                            ? (threads
                                  ? strings.noConversations
                                  : strings.inboxNoActiveCalls)
                            : strings.inboxThreadRooms,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              );
            }
            final room = rooms[index - 1];
            return ListTile(
              key: Key('inbox-${destination.name}-${room.token}'),
              leading: ConversationAvatar(
                account: account,
                conversation: room,
                radius: 22,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text(
                room.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: threads ? null : Text(strings.callBannerTitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: threads
                  ? () => openConversationThreads(context, account, room)
                  : () => onSelect(room),
            );
          },
        ),
      ),
    );
  }
}
