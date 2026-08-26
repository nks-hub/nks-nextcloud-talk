import 'dart:convert';

import 'package:flutter/material.dart';
import '../../core/desktop_metrics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../core/giphy_reference.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../calls/call_state.dart';
import '../rooms/room_settings_service.dart';
import 'conversation_avatar_widget.dart';
import 'conversation_presence.dart';
import 'conversation_sync_service.dart';

enum _ConversationAction { markUnread, toggleArchived }

enum _ConversationListFilter { unread, mentions, archived }

/// Conversation list body used by the conversation shell.
///
/// Unread, mention and archived filters mirror the official Android client's
/// account-local AND semantics. A long press on a row opens a menu with
/// actions (mark unread, archive/unarchive) that are applied through
/// [RoomSettingsService] and then reconciled by a forced conversation resync.
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
  final Set<_ConversationListFilter> _filters = {};

  @override
  void didUpdateWidget(covariant ConversationListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id) {
      _filters.clear();
      return;
    }
    if (!_canViewArchived(widget.account)) {
      _filters.remove(_ConversationListFilter.archived);
    }
  }

  void _toggleFilter(_ConversationListFilter filter) {
    setState(() {
      if (!_filters.remove(filter)) {
        _filters.add(filter);
      }
    });
  }

  Future<void> _openActions(CachedConversation conversation) async {
    final account = widget.account;
    final accountId = account.id;
    final canMarkUnread =
        _canMarkUnread(account, conversation) &&
        conversation.unreadMessages == 0;
    final canToggleArchived = _talkFeatures(
      account,
    ).contains('archived-conversations-v2');
    if (!canMarkUnread && !canToggleArchived) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final action = await showModalBottomSheet<_ConversationAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canMarkUnread)
              ListTile(
                key: const Key('conversation-action-mark-unread'),
                leading: const Icon(Icons.mark_chat_unread_outlined),
                title: Text(strings.conversationActionMarkUnread),
                onTap: () => Navigator.of(
                  sheetContext,
                ).pop(_ConversationAction.markUnread),
              ),
            if (canToggleArchived)
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
                accountId: accountId,
                roomToken: conversation.token,
              ),
          accountId: accountId,
        );
      case _ConversationAction.toggleArchived:
        await _runAction(
          () => ref
              .read(roomSettingsServiceProvider)
              .setArchived(
                accountId: accountId,
                roomToken: conversation.token,
                archived: !conversation.isArchived,
              ),
          accountId: accountId,
        );
    }
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    required String accountId,
  }) async {
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
          .sync(accountId, forceFull: true);
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

    final canViewArchived = _canViewArchived(widget.account);
    final filters = Set<_ConversationListFilter>.of(_filters);
    if (!canViewArchived) {
      filters.remove(_ConversationListFilter.archived);
    }
    final shown = widget.conversations
        .where((conversation) => _matchesFilters(conversation, filters))
        .toList(growable: false);

    final items = <Widget>[
      _ConversationFilterBar(
        selected: filters,
        showArchived: canViewArchived,
        onToggle: _toggleFilter,
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
            _EmptyConversations(filtered: filters.isNotEmpty),
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

final class _ConversationFilterBar extends StatelessWidget {
  const _ConversationFilterBar({
    required this.selected,
    required this.showArchived,
    required this.onToggle,
  });

  final Set<_ConversationListFilter> selected;
  final bool showArchived;
  final ValueChanged<_ConversationListFilter> onToggle;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: strings.conversationFiltersLabel,
      child: SingleChildScrollView(
        key: const Key('conversation-filters'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(
          children: [
            FilterChip(
              key: const Key('conversation-filter-unread'),
              selected: selected.contains(_ConversationListFilter.unread),
              label: Text(strings.conversationFilterUnread),
              onSelected: (_) => onToggle(_ConversationListFilter.unread),
            ),
            const SizedBox(width: 8),
            FilterChip(
              key: const Key('conversation-filter-mentions'),
              selected: selected.contains(_ConversationListFilter.mentions),
              label: Text(strings.conversationFilterMentions),
              onSelected: (_) => onToggle(_ConversationListFilter.mentions),
            ),
            if (showArchived) ...[
              const SizedBox(width: 8),
              FilterChip(
                key: const Key('conversation-filter-archived'),
                selected: selected.contains(_ConversationListFilter.archived),
                label: Text(strings.conversationFilterArchived),
                onSelected: (_) => onToggle(_ConversationListFilter.archived),
              ),
            ],
          ],
        ),
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
    final presence = ConversationPresence.fromConversation(conversation);
    final statusMessage = presence?.message;
    final hasCall =
        ConversationCallState.fromConversation(conversation) != null;
    final semanticsValue = [
      if (hasCall) strings.callBannerTitle,
      if (presence != null) presence.description(strings),
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
              constraints: BoxConstraints(minHeight: context.listRowHeight),
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
                              if (hasCall) ...[
                                // Announced through the tile's semantics
                                // value, which this subtree is excluded from.
                                Icon(
                                  Icons.videocam_rounded,
                                  key: Key(
                                    'conversation-call-'
                                    '${conversation.token}',
                                  ),
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
                              if (presence != null) ...[
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
                          if (statusMessage != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              statusMessage,
                              key: Key(
                                'conversation-presence-message-'
                                '${conversation.token}',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
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
  const _EmptyConversations({required this.filtered});

  final bool filtered;

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
            filtered
                ? strings.conversationFilterNoResults
                : strings.noConversations,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            filtered
                ? strings.conversationFilterNoResultsBody
                : strings.noConversationsBody,
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

bool _matchesFilters(
  CachedConversation conversation,
  Set<_ConversationListFilter> filters,
) {
  final showArchived = filters.contains(_ConversationListFilter.archived);
  if (conversation.isArchived != showArchived) {
    return false;
  }
  if (filters.contains(_ConversationListFilter.unread) &&
      conversation.unreadMessages <= 0) {
    return false;
  }
  return !filters.contains(_ConversationListFilter.mentions) ||
      _hasUnreadMention(conversation);
}

bool _hasUnreadMention(CachedConversation conversation) {
  try {
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    final directConversation = room.type == 1 || room.type == 5;
    return room.unreadMention ||
        (directConversation && conversation.unreadMessages > 0);
  } on FormatException {
    return false;
  } on TalkProtocolException {
    return false;
  }
}

bool _canViewArchived(StoredAccount account) =>
    _talkFeatures(account).contains('archived-conversations-v2');

bool _canMarkUnread(StoredAccount account, CachedConversation conversation) {
  try {
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    final profile = ChatCapabilityProfile.fromTalkFeatures(
      _talkFeatures(account),
      federated: room.isFederated,
    );
    return profile.markUnread;
  } on FormatException {
    return false;
  } on TalkProtocolException {
    return false;
  }
}

List<String> _talkFeatures(StoredAccount account) {
  try {
    final decoded = jsonDecode(account.talkFeaturesJson);
    if (decoded is List<Object?> && decoded.every((value) => value is String)) {
      final features = decoded.cast<String>();
      if (features.toSet().length == features.length) {
        return features;
      }
    }
  } on FormatException {
    // A corrupt local snapshot must hide gated actions instead of guessing.
  }
  return const [];
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
