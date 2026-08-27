import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/desktop_metrics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../calls/call_banner.dart';
import '../chat/chat_room_pane.dart';
import '../rooms/room_details_screen.dart';
import '../threads/thread_management_screen.dart';
import 'conversation_avatar_widget.dart';

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
    return Scaffold(
      key: const Key('chat-room-screen'),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            ExcludeSemantics(
              child: ConversationAvatar(
                account: account,
                conversation: current,
                radius: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: ConversationPresenceTitle(conversation: current)),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('open-thread-management'),
            tooltip: AppLocalizations.of(context).threadManagementOpenTooltip,
            icon: const Icon(Icons.forum_outlined),
            onPressed: () => unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/threads'),
                  builder: (context) => ThreadManagementScreen(
                    account: account,
                    conversation: current,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: const Key('open-room-details'),
            tooltip: AppLocalizations.of(context).roomDetailsOpenTooltip,
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/conversation/details'),
                  builder: (context) => RoomDetailsScreen(
                    account: account,
                    conversation: current,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            OngoingCallBanner(account: account, conversation: current),
            Expanded(
              child: ChatRoomPane(
                account: account,
                conversation: current,
                jumpToMessageId: jumpToMessageId,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class PresenceChatRoomPane extends StatelessWidget {
  const PresenceChatRoomPane({
    super.key,
    required this.account,
    required this.conversation,
    this.onClose,
    this.onOpenDetails,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// Shows a back affordance in the header. The narrow layout renders this
  /// pane in place of the list, where there is no route to pop.
  final VoidCallback? onClose;

  /// Hands the details to the caller instead of pushing them over everything.
  /// Only a caller with room for a third column supplies this.
  final VoidCallback? onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
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
          child: Row(
            children: [
              if (onClose != null) ...[
                IconButton(
                  key: const Key('close-conversation'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
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
              const SizedBox(width: 14),
              Expanded(
                child: ConversationPresenceTitle(
                  conversation: conversation,
                  titleStyle: Theme.of(context).textTheme.titleMedium,
                  fallbackSubtitle: conversation.description,
                ),
              ),
              IconButton(
                key: const Key('open-thread-management'),
                tooltip: strings.threadManagementOpenTooltip,
                icon: const Icon(Icons.forum_outlined),
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
              IconButton(
                key: const Key('open-room-details'),
                tooltip: strings.roomDetailsOpenTooltip,
                icon: const Icon(Icons.info_outline_rounded),
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
            ],
          ),
        ),
        OngoingCallBanner(account: account, conversation: conversation),
        Expanded(
          child: ChatRoomPane(account: account, conversation: conversation),
        ),
      ],
    );
  }
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
