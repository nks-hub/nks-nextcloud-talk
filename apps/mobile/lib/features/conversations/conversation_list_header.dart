part of 'conversation_list_actions.dart';

final class _ConversationSearch extends StatelessWidget {
  const _ConversationSearch({
    required this.controller,
    required this.onChanged,
    required this.account,
    required this.shortcuts,
    required this.preferred,
    required this.onSelect,
    this.onMessageSearch,
    this.filterMenu,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onMessageSearch;
  final StoredAccount account;
  final List<CachedConversation> shortcuts;
  final CachedConversation? preferred;
  final ValueChanged<CachedConversation> onSelect;
  final Widget? filterMenu;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final desktop = filterMenu != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 4, 12, desktop ? 4 : 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final buttonWidth = actionExtentOf(context);
          final minimumFieldWidth =
              buttonWidth + MediaQuery.textScalerOf(context).scale(88);
          final showBoth =
              constraints.maxWidth >=
              minimumFieldWidth +
                  buttonWidth * (onMessageSearch == null ? 2 : 3);
          final direct = desktop || shortcuts.length == 1 || showBoth
              ? preferred
              : null;
          final otherRooms = shortcuts.where((room) => room != direct);
          return Row(
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: desktop ? 9 : 13,
                    ),
                    prefixIconConstraints: desktop
                        ? const BoxConstraints(minWidth: 36, minHeight: 36)
                        : null,
                    suffixIconConstraints: desktop
                        ? const BoxConstraints(minWidth: 36, minHeight: 36)
                        : null,
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
              if (direct != null)
                IconButton(
                  key: Key('favorite-room-${direct.token}'),
                  tooltip: direct.displayName,
                  icon: direct.roomType == ConversationRoomType.noteToSelf
                      ? Icon(
                          Icons.edit_note_rounded,
                          color: desktop ? scheme.primary : null,
                        )
                      : ConversationAvatar(
                          account: account,
                          conversation: direct,
                          radius: 16,
                        ),
                  onPressed: () => onSelect(direct),
                ),
              if (!desktop && otherRooms.isNotEmpty)
                PopupMenuButton<CachedConversation>(
                  key: const Key('favorite-conversations-menu'),
                  tooltip: strings.emojiCategoryFavorites,
                  icon: const Icon(Icons.star_outline_rounded),
                  onSelected: onSelect,
                  itemBuilder: (context) => [
                    for (final room in otherRooms)
                      PopupMenuItem(
                        key: Key('favorite-room-${room.token}'),
                        value: room,
                        child: Text(room.displayName),
                      ),
                  ],
                ),
              if (onMessageSearch != null)
                IconButton(
                  key: const Key('open-message-search'),
                  tooltip: strings.searchMessagesTooltip,
                  icon: const Icon(Icons.manage_search_rounded),
                  onPressed: onMessageSearch,
                ),
              ?filterMenu,
            ],
          );
        },
      ),
    );
  }
}

final class _ConversationFilters extends StatelessWidget {
  const _ConversationFilters({
    required this.selected,
    required this.showArchived,
    required this.onToggle,
    required this.onClear,
    required this.otherRooms,
    required this.onSelectRoom,
  });
  final Set<_ConversationListFilter> selected;
  final bool showArchived;
  final ValueChanged<_ConversationListFilter> onToggle;
  final VoidCallback onClear;
  final Iterable<CachedConversation> otherRooms;
  final ValueChanged<CachedConversation> onSelectRoom;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final labels = {
      _ConversationListFilter.unread: strings.conversationFilterUnread,
      _ConversationListFilter.mentions: strings.conversationFilterMentions,
      if (showArchived)
        _ConversationListFilter.archived: strings.conversationFilterArchived,
    };
    if (context.usesDesktopDensity) {
      final activeLabels = labels.entries
          .where((entry) => selected.contains(entry.key))
          .map((entry) => entry.value);
      final title = otherRooms.isEmpty
          ? strings.conversationFiltersLabel
          : '${strings.conversationFiltersLabel} · ${strings.emojiCategoryFavorites}';
      return MenuAnchor(
        builder: (context, controller, _) => IconButton(
          key: const Key('conversation-filter-menu'),
          tooltip: selected.isEmpty
              ? title
              : '$title (${activeLabels.join(', ')})',
          isSelected: selected.isNotEmpty,
          icon: const Icon(Icons.filter_list_rounded),
          selectedIcon: Badge(
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: const Icon(Icons.filter_list_rounded),
          ),
          onPressed: controller.isOpen ? controller.close : controller.open,
        ),
        menuChildren: [
          CheckboxMenuButton(
            key: const Key('conversation-filter-all'),
            value: selected.isEmpty,
            closeOnActivate: false,
            onChanged: (_) => onClear(),
            child: Text(strings.inboxAll),
          ),
          for (final entry in labels.entries)
            CheckboxMenuButton(
              key: Key('conversation-filter-${entry.key.name}'),
              value: selected.contains(entry.key),
              closeOnActivate: false,
              onChanged: (_) => onToggle(entry.key),
              child: Text(entry.value),
            ),
          if (otherRooms.isNotEmpty)
            SubmenuButton(
              key: const Key('favorite-conversations-menu'),
              leadingIcon: const Icon(Icons.star_outline_rounded),
              menuChildren: [
                for (final room in otherRooms)
                  MenuItemButton(
                    key: Key('favorite-room-${room.token}'),
                    onPressed: () => onSelectRoom(room),
                    child: Text(room.displayName),
                  ),
              ],
              child: Text(strings.emojiCategoryFavorites),
            ),
        ],
      );
    }
    return Semantics(
      container: true,
      label: strings.conversationFiltersLabel,
      child: Padding(
        key: const Key('conversation-filters'),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: 4,
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
