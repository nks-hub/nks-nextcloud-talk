import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/desktop_metrics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../calls/call_banner.dart';
import '../calls/call_start_button.dart';
import '../chat/chat_room_pane.dart';
import '../chat/chat_background_surface.dart';
import '../rooms/room_details_screen.dart';
import 'conversation_shell.dart';
import '../threads/thread_management_screen.dart';
import 'conversation_avatar_widget.dart';
import 'conversation_header_actions.dart';
import 'conversation_absence.dart';
import 'conversation_upcoming_event.dart';

const int _oneToOneConversationType = 1;

enum ConversationPresenceKind { online, away, busy, doNotDisturb }

final class ConversationPresence {
  const ConversationPresence({
    required this.kind,
    required this.icon,
    required this.message,
  });

  static ConversationPresence? fromConversation(
    CachedConversation conversation, {
    DateTime? now,
  }) {
    if (conversation.roomType != _oneToOneConversationType) {
      return null;
    }
    final kind = switch (conversation.peerStatus?.trim().toLowerCase()) {
      'online' => ConversationPresenceKind.online,
      'away' => ConversationPresenceKind.away,
      'busy' => ConversationPresenceKind.busy,
      'dnd' => ConversationPresenceKind.doNotDisturb,
      _ => null,
    };
    if (kind == null) {
      return null;
    }

    final clearAt = conversation.peerStatusClearAt;
    final observedNow = (now ?? DateTime.now()).toUtc();
    final customStatusActive =
        clearAt == null || observedNow.millisecondsSinceEpoch ~/ 1000 < clearAt;
    return ConversationPresence(
      kind: kind,
      icon: customStatusActive ? _nonEmpty(conversation.peerStatusIcon) : null,
      message: customStatusActive
          ? _nonEmpty(conversation.peerStatusMessage)
          : null,
    );
  }

  final ConversationPresenceKind kind;
  final String? icon;
  final String? message;

  String description(AppLocalizations strings) {
    final custom = <String>[?icon, ?message].join(' ');
    if (custom.isNotEmpty) {
      return custom;
    }
    return switch (kind) {
      ConversationPresenceKind.online => strings.presenceOnline,
      ConversationPresenceKind.away => strings.presenceAway,
      ConversationPresenceKind.busy => strings.presenceBusy,
      ConversationPresenceKind.doNotDisturb => strings.presenceDoNotDisturb,
    };
  }
}

final class ConversationPresenceBadge extends StatelessWidget {
  const ConversationPresenceBadge({
    super.key,
    required this.conversation,
    this.size = 12,
  });

  final CachedConversation conversation;
  final double size;

  @override
  Widget build(BuildContext context) {
    final presence = ConversationPresence.fromConversation(conversation);
    if (presence == null) {
      return const SizedBox.shrink();
    }
    final key = Key('conversation-presence-badge-${conversation.token}');
    final label = presence.description(AppLocalizations.of(context));
    if (presence.icon != null) {
      return Semantics(
        label: label,
        child: Text(
          presence.icon!,
          key: key,
          semanticsLabel: label,
          style: TextStyle(fontSize: size),
        ),
      );
    }
    return Semantics(
      label: label,
      child: Icon(
        _presenceIcon(presence.kind),
        key: key,
        size: size,
        color: presenceColor(presence.kind, Theme.of(context).brightness),
      ),
    );
  }
}

final class ConversationPresenceTitle extends StatelessWidget {
  const ConversationPresenceTitle({
    super.key,
    required this.conversation,
    this.titleStyle,
    this.fallbackSubtitle,
  });

  final CachedConversation conversation;
  final TextStyle? titleStyle;
  final String? fallbackSubtitle;

  @override
  Widget build(BuildContext context) {
    final presence = ConversationPresence.fromConversation(conversation);
    final subtitle =
        presence?.description(AppLocalizations.of(context)) ??
        _nonEmpty(fallbackSubtitle);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                conversation.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            if (presence != null) ...[
              const SizedBox(width: 7),
              // The subtitle below already announces the same state.
              ExcludeSemantics(
                child: ConversationPresenceBadge(conversation: conversation),
              ),
            ],
          ],
        ),
        if (subtitle != null)
          Text(
            subtitle,
            key: Key('conversation-presence-text-${conversation.token}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

final class PresenceChatRoomScreen extends ConsumerWidget {
  const PresenceChatRoomScreen({
    super.key,
    required this.account,
    required this.conversation,
    this.jumpToMessageId,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// Opens the room on a specific message instead of on the newest one.
  final int? jumpToMessageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = _currentConversation(
      ref.watch(conversationsProvider(account.id)).valueOrNull,
      conversation,
    );
    const avatarRadius = 18.0;
    const avatarGap = 10.0;
    return Scaffold(
      key: const Key('chat-room-screen'),
      appBar: AppBar(
        titleSpacing: 0,
        // Everything lives in the title, actions included, because only there
        // is the width known: `AppBar` hands its actions whatever they ask for
        // and gives the title the leftovers, which on a phone is nothing.
        title: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              ExcludeSemantics(
                child: ConversationAvatar(
                  account: account,
                  conversation: current,
                  radius: avatarRadius,
                ),
              ),
              const SizedBox(width: avatarGap),
              Expanded(child: ConversationPresenceTitle(conversation: current)),
              ...conversationHeaderActions(
                _headerActions(context, ref, account, current),
                width: box.maxWidth,
                titleFloor: conversationTitleFloor(
                  context,
                  avatarExtent: avatarRadius * 2,
                  gap: avatarGap,
                ),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            ConversationUpcomingEventBanner(
              account: account,
              conversation: current,
            ),
            ConversationAbsenceBanner(account: account, conversation: current),
            OngoingCallBanner(account: account, conversation: current),
            Expanded(
              child: ChatBackgroundSurface(
                accountId: account.id,
                roomToken: current.token,
                child: ChatRoomPane(
                  account: account,
                  conversation: current,
                  jumpToMessageId: jumpToMessageId,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class PresenceChatRoomPane extends ConsumerWidget {
  const PresenceChatRoomPane({
    super.key,
    required this.account,
    required this.conversation,
    this.onClose,
    this.onOpenDetails,
    this.onToggleList,
    this.listCollapsed = false,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// Shows a back affordance in the header. The narrow layout renders this
  /// pane in place of the list, where there is no route to pop.
  final VoidCallback? onClose;

  /// Hands the details to the caller instead of pushing them over everything.
  /// Only a caller with room for a third column supplies this.
  final VoidCallback? onOpenDetails;

  /// Folds the conversation list away and back. Supplied only by a layout
  /// that draws the list beside this pane; a narrow window has nowhere to
  /// fold it to.
  final VoidCallback? onToggleList;
  final bool listCollapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    const avatarExtent = 40.0;
    const avatarGap = 14.0;
    // Each leading button and its gap come off the width before the name and
    // the actions divide what is left.
    final leadingExtent =
        (onToggleList == null ? 0.0 : kMinInteractiveDimension + 4) +
        (onClose == null ? 0.0 : kMinInteractiveDimension + 4);
    return Column(
      children: [
        Container(
          key: const Key('chat-room-header'),
          constraints: BoxConstraints(minHeight: context.paneHeaderHeight),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                if (onToggleList != null) ...[
                  IconButton(
                    key: const Key('toggle-conversation-list'),
                    tooltip: listCollapsed
                        ? strings.showConversationList
                        : strings.hideConversationList,
                    icon: Icon(
                      listCollapsed
                          ? Icons.menu_open_rounded
                          : Icons.menu_rounded,
                    ),
                    onPressed: onToggleList,
                  ),
                  const SizedBox(width: 4),
                ],
                if (onClose != null) ...[
                  IconButton(
                    key: const Key('close-conversation'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const BackButtonIcon(),
                    onPressed: onClose,
                  ),
                  const SizedBox(width: 4),
                ],
                ExcludeSemantics(
                  child: ConversationAvatar(
                    account: account,
                    conversation: conversation,
                  ),
                ),
                const SizedBox(width: avatarGap),
                Expanded(
                  child: ConversationPresenceTitle(
                    conversation: conversation,
                    titleStyle: Theme.of(context).textTheme.titleMedium,
                    fallbackSubtitle: conversation.description,
                  ),
                ),
                ...conversationHeaderActions(
                  _headerActions(
                    context,
                    ref,
                    account,
                    conversation,
                    onOpenDetails: onOpenDetails,
                  ),
                  width: box.maxWidth - leadingExtent,
                  titleFloor: conversationTitleFloor(
                    context,
                    avatarExtent: avatarExtent,
                    gap: avatarGap,
                  ),
                ),
              ],
            ),
          ),
        ),
        ConversationUpcomingEventBanner(
          account: account,
          conversation: conversation,
        ),
        ConversationAbsenceBanner(account: account, conversation: conversation),
        OngoingCallBanner(account: account, conversation: conversation),
        Expanded(
          child: ChatBackgroundSurface(
            accountId: account.id,
            roomToken: conversation.token,
            child: ChatRoomPane(account: account, conversation: conversation),
          ),
        ),
      ],
    );
  }
}

/// The header's actions, most important first — that order is also the order
/// in which a narrow header stops showing them as icons.
List<ConversationHeaderAction> _headerActions(
  BuildContext context,
  WidgetRef ref,
  StoredAccount account,
  CachedConversation conversation, {
  VoidCallback? onOpenDetails,
}) {
  final strings = AppLocalizations.of(context);
  return [
    ...callStartActions(
      context,
      ref,
      accountId: account.id,
      conversation: conversation,
    ),
    ConversationHeaderAction(
      id: const Key('open-room-search'),
      icon: Icons.search_rounded,
      label: strings.searchInConversation,
      onPressed: () => openMessageSearch(
        context,
        account.id,
        roomToken: conversation.token,
        roomName: conversation.displayName,
      ),
    ),
    ConversationHeaderAction(
      id: const Key('open-thread-management'),
      icon: Icons.forum_outlined,
      label: strings.threadManagementOpenTooltip,
      onPressed: () => unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: '/threads'),
            builder: (context) => ThreadManagementScreen(
              account: account,
              conversation: conversation,
            ),
          ),
        ),
      ),
    ),
    ConversationHeaderAction(
      id: const Key('open-room-details'),
      icon: Icons.info_outline_rounded,
      label: strings.roomDetailsOpenTooltip,
      onPressed:
          onOpenDetails ??
          () => unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: '/conversation/details'),
                builder: (context) => RoomDetailsScreen(
                  account: account,
                  conversation: conversation,
                ),
              ),
            ),
          ),
    ),
  ];
}

CachedConversation _currentConversation(
  List<CachedConversation>? conversations,
  CachedConversation fallback,
) {
  if (conversations == null) {
    return fallback;
  }
  for (final conversation in conversations) {
    if (conversation.token == fallback.token) {
      return conversation;
    }
  }
  return fallback;
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

/// Presence colors are picked per brightness so every badge keeps at least a
/// 3:1 contrast against the lightest light and the darkest dark app surface.
Color presenceColor(ConversationPresenceKind kind, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return switch (kind) {
    ConversationPresenceKind.online =>
      isDark ? const Color(0xFF66BB6A) : const Color(0xFF2E7D32),
    ConversationPresenceKind.away =>
      isDark ? const Color(0xFFFFB74D) : const Color(0xFFA15C00),
    ConversationPresenceKind.busy =>
      isDark ? const Color(0xFFFF8A65) : const Color(0xFFB3400F),
    ConversationPresenceKind.doNotDisturb =>
      isDark ? const Color(0xFFEF5350) : const Color(0xFFC62828),
  };
}

/// Each presence state also carries a distinct glyph so the badge never
/// depends on color alone.
IconData _presenceIcon(ConversationPresenceKind kind) {
  return switch (kind) {
    ConversationPresenceKind.online => Icons.circle,
    ConversationPresenceKind.away => Icons.schedule,
    ConversationPresenceKind.busy => Icons.remove_circle,
    ConversationPresenceKind.doNotDisturb => Icons.do_not_disturb_on,
  };
}
