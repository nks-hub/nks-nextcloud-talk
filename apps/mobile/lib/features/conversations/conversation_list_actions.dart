import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/giphy_reference.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../rooms/room_settings_service.dart';
import 'conversation_avatar_widget.dart';
import 'conversation_presence.dart';
import 'conversation_sync_service.dart';

enum _ConversationAction { markUnread, toggleArchived }

/// Conversation list body used by the conversation shell.
///
/// Archived conversations are hidden from the main list behind a toggle, and
/// a long press on a row opens a menu with actions (mark unread,
/// archive/unarchive) that are applied through [RoomSettingsService] and
/// then reconciled by a forced conversation resync.
final class ConversationListView extends ConsumerStatefulWidget {
  const ConversationListView({
    super.key,
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
  ConsumerState<ConversationListView> createState() =>
      _ConversationListViewState();
}

final class _ConversationListViewState
    extends ConsumerState<ConversationListView> {
  var _showArchived = false;

  Future<void> _openActions(CachedConversation conversation) async {
    final strings = AppLocalizations.of(context);
    final action = await showModalBottomSheet<_ConversationAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (conversation.unreadMessages == 0)
              ListTile(
                key: const Key('conversation-action-mark-unread'),
                leading: const Icon(Icons.mark_chat_unread_outlined),
                title: Text(strings.conversationActionMarkUnread),
                onTap: () => Navigator.of(
                  sheetContext,
                ).pop(_ConversationAction.markUnread),
              ),
            ListTile(
              key: const Key('conversation-action-archive'),
              leading: Icon(
                conversation.isArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              title: Text(
                conversation.isArchived
                    ? strings.conversationActionUnarchive
                    : strings.conversationActionArchive,
              ),
              onTap: () => Navigator.of(
                sheetContext,
              ).pop(_ConversationAction.toggleArchived),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _ConversationAction.markUnread:
        await _runAction(
          () => ref
              .read(roomSettingsServiceProvider)
              .markConversationUnread(
                accountId: widget.account.id,
                roomToken: conversation.token,
              ),
        );
      case _ConversationAction.toggleArchived:
        await _runAction(
          () => ref
              .read(roomSettingsServiceProvider)
              .setArchived(
                accountId: widget.account.id,
                roomToken: conversation.token,
                archived: !conversation.isArchived,
              ),
        );
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
    } on RoomSettingsException catch (error) {
      if (mounted) {
        _showError(error.code);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    try {
      await ref
          .read(conversationSyncServiceProvider)
          .sync(widget.account.id, forceFull: true);
    } on ConversationSyncException {
      // The action already succeeded server-side; a later sync will catch up.
    }
  }

  void _showError(RoomSettingsError code) {
    final strings = AppLocalizations.of(context);
    final message = switch (code) {
      RoomSettingsError.reauthenticationRequired =>
        strings.conversationActionErrorReauth,
      _ => strings.conversationActionErrorGeneric,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('conversation-action-error'),
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading && widget.conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final visible = widget.conversations
        .where((conversation) => !conversation.isArchived)
        .toList(growable: false);
    final archived = widget.conversations
        .where((conversation) => conversation.isArchived)
        .toList(growable: false);
    final shown = _showArchived ? archived : visible;

    final items = <Widget>[
      if (archived.isNotEmpty)
        _ArchivedToggleTile(
          expanded: _showArchived,
          count: archived.length,
          onTap: () => setState(() => _showArchived = !_showArchived),
        ),
      for (final conversation in shown)
        _ConversationTile(
          account: widget.account,
          conversation: conversation,
          selected: conversation.token == widget.selectedToken,
          onTap: () => widget.onSelect(conversation),
          onLongPress: () => _openActions(conversation),
        ),
    ];

    if (shown.isEmpty) {
      return RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ...items,
            const SizedBox(height: 120),
            const _EmptyConversations(),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(indent: 84),
        itemBuilder: (context, index) => items[index],
      ),
    );
  }
}

final class _ArchivedToggleTile extends StatelessWidget {
  const _ArchivedToggleTile({
    required this.expanded,
    required this.count,
    required this.onTap,
  });

  final bool expanded;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: const Key('conversation-archived-toggle'),
      leading: Icon(
        expanded ? Icons.arrow_back_rounded : Icons.archive_outlined,
        color: scheme.onSurfaceVariant,
      ),
      title: Text(
        expanded
            ? strings.conversationArchivedSectionHide
            : strings.conversationArchivedSectionShow(count),
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      onTap: onTap,
    );
  }
}

final class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.account,
    required this.conversation,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

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
      onLongPress: onLongPress,
      child: ExcludeSemantics(
        child: Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
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
                              if (conversation.isArchived) ...[
                                Icon(
                                  Icons.archive_outlined,
                                  size: 18,
                                  color: scheme.onSurfaceVariant,
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
