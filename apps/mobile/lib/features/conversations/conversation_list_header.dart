part of 'conversation_list_actions.dart';

final class _ConversationSearch extends StatelessWidget {
  const _ConversationSearch({
    required this.controller,
    required this.onChanged,
    this.onMessageSearch,
    this.favorites,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onMessageSearch;
  final Widget? favorites;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('conversation-name-search'),
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              maxLines: 1,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: strings.incomingShareSearch,
                hintMaxLines: 1,
                isDense: true,
                filled: true,
                fillColor: scheme.surfaceContainerHigh,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
                prefixIcon: const Icon(Icons.search_rounded, size: 21),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: strings.searchMessagesClear,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
              ),
            ),
          ),
          ?favorites,
          if (onMessageSearch != null)
            IconButton(
              key: const Key('open-message-search'),
              tooltip: strings.searchMessagesTooltip,
              icon: const Icon(Icons.manage_search_rounded),
              onPressed: onMessageSearch,
            ),
        ],
      ),
    );
  }
}

final class _InlineFavorites extends StatelessWidget {
  const _InlineFavorites({
    required this.account,
    required this.rooms,
    required this.onSelect,
  });

  final StoredAccount account;
  final List<CachedConversation> rooms;
  final ValueChanged<CachedConversation> onSelect;

  @override
  Widget build(BuildContext context) {
    final note = rooms
        .where((room) => room.roomType == ConversationRoomType.noteToSelf)
        .firstOrNull;
    // Reserve the search icons, outside padding and editable text before
    // adding a second favourite shortcut beside the message-search button.
    final hasSpace =
        MediaQuery.sizeOf(context).width >=
        264 + MediaQuery.textScalerOf(context).scale(88);
    final direct = rooms.length == 1
        ? rooms.first
        : hasSpace
        ? note
        : null;
    final others = rooms.where((room) => room != direct);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (direct != null)
          IconButton(
            key: Key('favorite-room-${direct.token}'),
            tooltip: direct.displayName,
            icon: direct == note
                ? const Icon(Icons.edit_note_rounded)
                : ConversationAvatar(
                    account: account,
                    conversation: direct,
                    radius: 16,
                  ),
            onPressed: () => onSelect(direct),
          ),
        if (others.isNotEmpty)
          PopupMenuButton<CachedConversation>(
            key: const Key('favorite-conversations-menu'),
            tooltip: AppLocalizations.of(context).emojiCategoryFavorites,
            icon: const Icon(Icons.star_outline_rounded),
            onSelected: onSelect,
            itemBuilder: (context) => [
              for (final room in others)
                PopupMenuItem(
                  key: Key('favorite-room-${room.token}'),
                  value: room,
                  child: Text(room.displayName),
                ),
            ],
          ),
      ],
    );
  }
}

final class _FavoriteConversations extends StatelessWidget {
  const _FavoriteConversations({
    required this.account,
    required this.rooms,
    required this.onSelect,
    required this.compact,
  });
  final StoredAccount account;
  final List<CachedConversation> rooms;
  final ValueChanged<CachedConversation> onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textSize = MediaQuery.textScalerOf(context).scale(12);
    return Semantics(
      container: true,
      label: AppLocalizations.of(context).emojiCategoryFavorites,
      child: SizedBox(
        height: compact ? 56 : 62 + textSize * 1.5,
        child: ListView.separated(
          key: const Key('favorite-conversations'),
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
          scrollDirection: Axis.horizontal,
          itemCount: rooms.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            final room = rooms[index];
            final label = Text(
              room.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            );
            final avatar = ConversationAvatar(
              account: account,
              conversation: room,
              radius: compact ? 18 : 22,
            );
            return Semantics(
              button: true,
              label: room.displayName,
              child: Material(
                color: compact
                    ? theme.colorScheme.surfaceContainerHigh
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  key: Key('favorite-room-${room.token}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelect(room),
                  child: ExcludeSemantics(
                    child: compact
                        ? Padding(
                            padding: const EdgeInsetsDirectional.fromSTEB(
                              6,
                              3,
                              10,
                              3,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                avatar,
                                const SizedBox(width: 7),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 125,
                                  ),
                                  child: label,
                                ),
                              ],
                            ),
                          )
                        : SizedBox(
                            width: 70,
                            child: Column(
                              children: [
                                avatar,
                                const SizedBox(height: 5),
                                label,
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _ConversationFilterBar extends StatelessWidget {
  const _ConversationFilterBar({
    required this.selected,
    required this.showArchived,
    required this.onToggle,
    required this.onClear,
  });
  final Set<_ConversationListFilter> selected;
  final bool showArchived;
  final ValueChanged<_ConversationListFilter> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final labels = {
      _ConversationListFilter.unread: strings.conversationFilterUnread,
      _ConversationListFilter.mentions: strings.conversationFilterMentions,
      if (showArchived)
        _ConversationListFilter.archived: strings.conversationFilterArchived,
    };
    return Semantics(
      container: true,
      label: strings.conversationFiltersLabel,
      child: Padding(
        key: const Key('conversation-filters'),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Wrap(
          spacing: 4,
          runSpacing: 2,
          children: [
            _tab(context, 'all', strings.inboxAll, selected.isEmpty, onClear),
            for (final entry in labels.entries)
              _tab(
                context,
                entry.key.name,
                entry.value,
                selected.contains(entry.key),
                () => onToggle(entry.key),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tab(
    BuildContext context,
    String name,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 2,
            color: active ? scheme.primary : Colors.transparent,
          ),
        ),
      ),
      child: FilterChip(
        key: Key('conversation-filter-$name'),
        label: Text(label),
        selected: active,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        padding: EdgeInsets.zero,
        labelPadding: const EdgeInsets.symmetric(horizontal: 8),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        selectedColor: Colors.transparent,
        backgroundColor: Colors.transparent,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          color: active ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}
