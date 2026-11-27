import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../core/desktop_metrics.dart';
import '../../core/giphy_reference.dart';
import '../../core/tonal_state_icon.dart';
import '../../data/app_database.dart';
import '../../data/composer_draft_focus.dart';
import '../../data/chat_repository.dart';
import '../../data/undelivered_messages.dart';
import '../../l10n/generated/app_localizations.dart';
import '../calls/call_state.dart';
import '../chat/outgoing_message_status.dart';
import '../chat/chat_room_pane.dart';
import '../rooms/room_settings_service.dart';
import 'conversation_avatar.dart' show ConversationRoomType;
import 'conversation_avatar_widget.dart';
import 'conversation_delivery.dart';
import 'conversation_header_actions.dart' show actionExtentOf;
import 'conversation_presence.dart';
import 'conversation_sync_service.dart';

part 'conversation_list_header.dart';
part 'conversation_list_drafts.dart';
part 'conversation_list_undelivered.dart';

enum _ConversationAction { markUnread, toggleArchived }

enum _ConversationListFilter { unread, mentions, archived, drafts, undelivered }

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
    this.bottomInset = 0,
    this.onMessageSearch,
  });

  final StoredAccount account;
  final List<CachedConversation> conversations;
  final bool loading;
  final Future<void> Function() onRefresh;
  final ValueChanged<CachedConversation> onSelect;
  final String? selectedToken;

  final VoidCallback? onMessageSearch;

  /// Room to leave under the last row for whatever floats over the list.
  final double bottomInset;

  @override
  ConsumerState<ConversationListView> createState() =>
      _ConversationListViewState();
}

final class _ConversationListViewState
    extends ConsumerState<ConversationListView> {
  final Set<_ConversationListFilter> _filters = {};
  final _search = TextEditingController();
  String _query = '';
  int _openGeneration = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  final ConversationUnreadMentionCache _unreadMentions =
      ConversationUnreadMentionCache();

  @override
  void didUpdateWidget(covariant ConversationListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id) {
      _filters.clear();
      _search.clear();
      _query = '';
      _unreadMentions.clear();
      return;
    }
    if (!_canViewArchived(widget.account)) {
      _filters.remove(_ConversationListFilter.archived);
    }
  }

  void _toggleFilter(_ConversationListFilter filter) {
    setState(() {
      if (_filters.remove(filter)) {
        if (filter == _ConversationListFilter.mentions) {
          _unreadMentions.clear();
        }
      } else {
        if (filter == _ConversationListFilter.drafts) {
          _filters.remove(_ConversationListFilter.undelivered);
        } else if (filter == _ConversationListFilter.undelivered) {
          _filters.remove(_ConversationListFilter.drafts);
        }
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
    final canViewArchived = _canViewArchived(widget.account);
    final filters = Set<_ConversationListFilter>.of(_filters);
    if (!canViewArchived) {
      filters.remove(_ConversationListFilter.archived);
    }
    if (filters.contains(_ConversationListFilter.mentions)) {
      _unreadMentions.retainConversations(widget.conversations);
    }
    final showDrafts = filters.contains(_ConversationListFilter.drafts);
    final showUndelivered = filters.contains(
      _ConversationListFilter.undelivered,
    );
    final shown = widget.conversations
        .where(
          (conversation) =>
              conversation.accountId == widget.account.id &&
              (showDrafts ||
                  showUndelivered ||
                  conversation.displayName.toLowerCase().contains(_query)) &&
              _matchesFilters(
                conversation,
                filters,
                unreadMentions: _unreadMentions,
              ),
        )
        .toList(growable: false);

    final drafts = showDrafts
        ? ref.watch(_accountDrafts(widget.account.id))
        : null;
    final matchingDrafts = showDrafts
        ? _matchDrafts(
            widget.account.id,
            drafts?.valueOrNull ?? [],
            shown,
            _query,
          )
        : const <_ListedDraft>[];
    final issues = showUndelivered
        ? ref.watch(undeliveredMessagesProvider(widget.account.id))
        : null;
    final groups = _undeliveredRooms(issues?.valueOrNull ?? [], shown, _query);
    final count = showUndelivered
        ? groups.length
        : showDrafts
        ? matchingDrafts.length
        : shown.length;
    final desktop = context.usesDesktopDensity;
    final shortcuts = desktop || (filters.isEmpty && _query.isEmpty)
        ? widget.conversations
              .where((room) => room.favorite && !room.isArchived)
              .toList(growable: false)
        : const <CachedConversation>[];
    final preferred =
        shortcuts
            .where((room) => room.roomType == ConversationRoomType.noteToSelf)
            .firstOrNull ??
        (shortcuts.length == 1 ? shortcuts.first : null);

    return RefreshIndicator(
      key: ValueKey<String>('conversation-list-${widget.account.id}'),
      onRefresh: widget.onRefresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: widget.bottomInset),
        itemCount: count == 0 ? 2 : count + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            final filterControls = _ConversationFilters(
              selected: filters,
              showArchived: canViewArchived,
              onToggle: _toggleFilter,
              onClear: () => setState(() {
                _filters.clear();
                _unreadMentions.clear();
              }),
              otherRooms: shortcuts.where((room) => room != preferred),
              onSelectRoom: widget.onSelect,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ConversationSearch(
                  account: widget.account,
                  shortcuts: shortcuts,
                  preferred: preferred,
                  onSelect: widget.onSelect,
                  filterMenu: desktop ? filterControls : null,
                  controller: _search,
                  onChanged: (value) => setState(() {
                    _query = value.trim().toLowerCase();
                  }),
                  onMessageSearch: widget.onMessageSearch,
                ),
                if (!desktop) filterControls,
              ],
            );
          }
          if (drafts?.hasError == true || issues?.hasError == true) {
            return TextButton.icon(
              onPressed: () => showUndelivered
                  ? ref.invalidate(storedUndeliveredProvider(widget.account.id))
                  : ref.invalidate(_accountDrafts(widget.account.id)),
              icon: const Icon(Icons.refresh),
              label: Text(AppLocalizations.of(context).retry),
            );
          }
          if (count == 0) {
            if ((issues?.isLoading ?? false) ||
                (drafts?.isLoading ?? false) ||
                (widget.loading && widget.conversations.isEmpty)) {
              return const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(top: 40),
              child: _EmptyConversations(
                filtered: filters.isNotEmpty || _query.isNotEmpty,
              ),
            );
          }
          if (showUndelivered) {
            final group = groups[index - 1];
            return _UndeliveredTile(
              group: group,
              onOpen: (message) => _openEditor(
                group.room,
                message.thread,
                onValidated: () {
                  ref.read(undeliveredSelectionProvider.notifier).state =
                      message;
                },
              ),
            );
          }
          if (showDrafts) {
            final entry = matchingDrafts[index - 1];
            return _DraftTile(entry: entry, onTap: () => _openDraft(entry));
          }
          final conversation = shown[index - 1];
          return _ConversationTile(
            account: widget.account,
            conversation: conversation,
            selected: conversation.token == widget.selectedToken,
            onTap: () => widget.onSelect(conversation),
            onLongPress: () => _openActions(conversation),
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
    final delivery = lastMessageDelivery(conversation);
    final read = delivery == OutgoingMessageDeliveryState.read;
    final unread = conversation.unreadMessages > 0;
    final tileColor = selected
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.08),
            scheme.surfaceContainerHigh,
          )
        : unread
        ? scheme.primary.withValues(alpha: 0.045)
        : Colors.transparent;
    final titleColor = scheme.onSurface;
    final supportingColor = scheme.onSurfaceVariant;
    final semanticsValue = [
      if (hasCall) strings.callBannerTitle,
      if (presence != null) presence.description(strings),
      if (delivery != null) read ? strings.messageRead : strings.messageSent,
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
          child: Material(
            color: tileColor,
            borderRadius: BorderRadius.circular(selected ? 10 : 0),
            clipBehavior: Clip.antiAlias,
            // Right-click reaches the same sheet as a long press: holding a
            // mouse button down is the wrong gesture on a desktop, and the two
            // never collide because no pointer produces both.
            child: GestureDetector(
              onSecondaryTap: onLongPress,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                child: Container(
                  constraints: BoxConstraints(
                    minHeight: context.listRowHeight.clamp(48.0, 64.0),
                  ),
                  padding: const EdgeInsetsDirectional.fromSTEB(9, 6, 6, 6),
                  foregroundDecoration: BoxDecoration(
                    border: BorderDirectional(
                      start: selected
                          ? BorderSide(color: scheme.primary, width: 3)
                          : BorderSide.none,
                      bottom: selected
                          ? BorderSide.none
                          : BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: 0.5,
                              ),
                              width: 0.5,
                            ),
                    ),
                  ),
                  child: Row(
                    children: [
                      // The presence mark sits on the avatar's corner, ringed
                      // in the row colour so it reads against any picture.
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          ConversationAvatar(
                            account: account,
                            conversation: conversation,
                            radius: context.listAvatarRadius.clamp(20.0, 24.0),
                          ),
                          if (presence != null)
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Color.alphaBlend(
                                    tileColor,
                                    scheme.surfaceContainerLow,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  // An emoji status grows with the text size; capped so
                                  // it stays a dot on the corner at 200 %.
                                  child: MediaQuery.withClampedTextScaling(
                                    maxScaleFactor: 1.2,
                                    child: ConversationPresenceBadge(
                                      conversation: conversation,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LayoutBuilder(
                              builder: (context, box) {
                                return Row(
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
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              color: titleColor,
                                              fontWeight: unread || selected
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // At 200 % text an absolute date is wider
                                    // than the 240 dp the list may be dragged
                                    // to (it once overflowed by 65 px), so it
                                    // is capped at half the row.
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: box.maxWidth / 2,
                                      ),
                                      child: Text(
                                        _formatActivity(
                                          context,
                                          conversation.lastActivity,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(color: supportingColor),
                                      ),
                                    ),
                                  ],
                                );
                              },
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
                                    ?.copyWith(color: supportingColor),
                              ),
                            ],
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                if (delivery != null) ...[
                                  // The marks of the chat bubbles: one tick
                                  // once stored, two once everyone read it.
                                  Icon(
                                    read
                                        ? Icons.done_all_rounded
                                        : Icons.done_rounded,
                                    key: Key(
                                      'conversation-delivery-'
                                      '${conversation.token}',
                                    ),
                                    size: 16,
                                    color: read
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: Text(
                                    preview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: supportingColor,
                                          fontWeight: unread
                                              ? FontWeight.w600
                                              : null,
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
            borderRadius: BorderRadius.circular(8),
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
          const TonalStateIcon(icon: Icons.chat_bubble_outline_rounded),
          const SizedBox(height: 20),
          Text(
            filtered
                ? strings.conversationFilterNoResults
                : strings.noConversations,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
  Set<_ConversationListFilter> filters, {
  required ConversationUnreadMentionCache unreadMentions,
}) {
  final showArchived = filters.contains(_ConversationListFilter.archived);
  if (conversation.isArchived != showArchived) {
    return false;
  }
  if (filters.contains(_ConversationListFilter.unread) &&
      conversation.unreadMessages <= 0) {
    return false;
  }
  return !filters.contains(_ConversationListFilter.mentions) ||
      unreadMentions.hasUnreadMention(conversation);
}

typedef ConversationUnreadMentionParser =
    bool Function(CachedConversation conversation);

typedef _ConversationMentionKey = ({String accountId, String token});

typedef _UnreadMentionEntry = ({
  String rawJson,
  int unreadMessages,
  bool hasUnreadMention,
});

/// Reuses mention parsing across Drift emissions, which create new row objects.
///
/// Entries are scoped to the current list and capped as a second guard. Once
/// full, unknown rooms are parsed without displacing residents. This avoids a
/// sequential scan above the cap evicting every entry needed by the next scan.
@visibleForTesting
final class ConversationUnreadMentionCache {
  ConversationUnreadMentionCache({
    this.maximumEntries = 4096,
    this.parser = _parseUnreadMention,
  }) {
    if (maximumEntries < 1) {
      throw ArgumentError.value(
        maximumEntries,
        'maximumEntries',
        'must be positive',
      );
    }
  }

  final int maximumEntries;
  final ConversationUnreadMentionParser parser;
  final LinkedHashMap<_ConversationMentionKey, _UnreadMentionEntry> _entries =
      LinkedHashMap<_ConversationMentionKey, _UnreadMentionEntry>();

  @visibleForTesting
  int get entryCount => _entries.length;

  bool hasUnreadMention(CachedConversation conversation) {
    final key = (accountId: conversation.accountId, token: conversation.token);
    final cached = _entries[key];
    if (cached != null &&
        cached.rawJson == conversation.rawJson &&
        cached.unreadMessages == conversation.unreadMessages) {
      return cached.hasUnreadMention;
    }
    final result = parser(conversation);
    if (cached != null || _entries.length < maximumEntries) {
      _entries[key] = (
        rawJson: conversation.rawJson,
        unreadMessages: conversation.unreadMessages,
        hasUnreadMention: result,
      );
    }
    return result;
  }

  void retainConversations(Iterable<CachedConversation> conversations) {
    final retained = <_ConversationMentionKey>{
      for (final conversation in conversations)
        (accountId: conversation.accountId, token: conversation.token),
    };
    _entries.removeWhere((key, _) => !retained.contains(key));
  }

  void clear() => _entries.clear();
}

bool _parseUnreadMention(CachedConversation conversation) {
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
