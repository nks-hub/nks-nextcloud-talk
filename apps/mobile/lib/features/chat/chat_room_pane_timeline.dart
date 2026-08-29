part of 'chat_room_pane.dart';

final class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.account, required this.conversation});

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  Widget build(BuildContext context) {
    return Container(
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
          ExcludeSemantics(
            child: ConversationAvatar(
              account: account,
              conversation: conversation,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (conversation.description.trim().isNotEmpty)
                  Text(
                    conversation.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Identifies the sliver that stays put while messages arrive.
final GlobalKey _centreSliverKey = GlobalKey();

final class _ChatTimeline extends StatelessWidget {
  const _ChatTimeline({
    required this.account,
    required this.conversation,
    required this.threadId,
    required this.messages,
    required this.blocks,
    required this.pending,
    required this.hasOlder,
    required this.loadingOlder,
    required this.controller,
    required this.onLoadOlder,
    required this.onRetry,
    required this.onResend,
    required this.onCancel,
    required this.onOpenThread,
    required this.onMessageActions,
    required this.onReplySwipe,
    required this.onReactionTap,
    required this.onJumpToMessage,
    required this.jumpTargetId,
    required this.jumpTargetKey,
    required this.highlightedMessageId,
    required this.deliveryStates,
    required this.lastCommonRead,
    required this.anchorMessageId,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final int? threadId;
  final List<CachedChatMessage> messages;

  /// The scope's confirmed message-id ranges, `null` when the scope itself
  /// hasn't loaded yet. More than one entry means the client knows about a
  /// gap between two cached ranges (see [_gapBeforeContentIndex]).
  final List<ChatBlock>? blocks;
  final List<StoredTextSendOperation> pending;
  final bool hasOlder;
  final bool loadingOlder;
  final ScrollController controller;
  final VoidCallback onLoadOlder;
  final VoidCallback onRetry;
  final ValueChanged<StoredTextSendOperation> onResend;
  final ValueChanged<StoredTextSendOperation> onCancel;
  final ValueChanged<CachedChatMessage> onOpenThread;
  final void Function(CachedChatMessage message, ChatMessage? parsed)
  onMessageActions;

  /// Swipe-to-reply, or null where replying is not on offer at all — inside
  /// a thread, in a read-only room, or without the `chat-replies` capability.
  /// The gesture must never reach further than the action sheet does.
  final ValueChanged<CachedChatMessage>? onReplySwipe;
  final void Function(
    CachedChatMessage message,
    ChatMessage? parsed,
    String emoji,
  )
  onReactionTap;
  final ValueChanged<int> onJumpToMessage;

  /// The message a jump is currently resolving. It carries [jumpTargetKey]
  /// so the pane can measure it once the list has built it.
  final int? jumpTargetId;
  final GlobalKey jumpTargetKey;
  final int? highlightedMessageId;
  final Map<int, OutgoingMessageDeliveryState> deliveryStates;
  final int? lastCommonRead;

  /// Newest message the reader had seen before they scrolled away, or null
  /// while they are still at the newest end. Splits the timeline so arrivals
  /// cannot push what they are reading; see the centre sliver in `build`.
  final int? anchorMessageId;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && pending.isEmpty && !hasOlder) {
      return const _EmptyChat();
    }
    final itemCount = messages.length + pending.length + (hasOlder ? 1 : 0);
    Widget buildAt(BuildContext context, int chronologicalIndex) {
        if (hasOlder && chronologicalIndex == 0) {
          return Center(
            key: const Key('chat-load-older'),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextButton.icon(
                onPressed: loadingOlder ? null : onLoadOlder,
                icon: loadingOlder
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.history_rounded),
                label: Text(
                  loadingOlder
                      ? AppLocalizations.of(context).loadingOlderMessages
                      : AppLocalizations.of(context).loadOlderMessages,
                ),
              ),
            ),
          );
        }
        final contentIndex = chronologicalIndex - (hasOlder ? 1 : 0);
        if (contentIndex < messages.length) {
          final message = messages[contentIndex];
          final parsed = _parseCachedMessage(message);
          final previous = contentIndex == 0
              ? null
              : messages[contentIndex - 1];
          final next = contentIndex + 1 >= messages.length
              ? null
              : messages[contentIndex + 1];
          final gapBeforeThis = _gapBeforeContentIndex(contentIndex);
          final groupedWithPrevious =
              !gapBeforeThis &&
              previous != null &&
              _messagesShareGroup(previous, message);
          final groupedWithNext =
              next != null && _messagesShareGroup(message, next);
          final startsDay =
              gapBeforeThis ||
              previous == null ||
              !_sameLocalDay(previous.timestamp, message.timestamp);
          return KeyedSubtree(
            key: ValueKey(
              'chat-message-${account.id}-${conversation.token}-${message.messageId}',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (gapBeforeThis)
                  const _ChatHistoryGapNotice(key: Key('chat-history-gap')),
                if (startsDay) _DaySeparator(timestamp: message.timestamp),
                _MessageBubble(
                  key: message.messageId == jumpTargetId ? jumpTargetKey : null,
                  account: account,
                  message: message,
                  parsed: parsed,
                  highlighted: message.messageId == highlightedMessageId,
                  onJumpToMessage: onJumpToMessage,
                  showAuthor: !groupedWithPrevious,
                  showAvatar: !groupedWithNext,
                  groupedWithPrevious: groupedWithPrevious,
                  groupEnd: !groupedWithNext,
                  showReplyPreview: _shouldShowReplyPreview(parsed, threadId),
                  onOpenThread: threadId == null ? onOpenThread : null,
                  onMessageActions: onMessageActions,
                  onReplySwipe: onReplySwipe,
                  onReactionTap: onReactionTap,
                  deliveryState:
                      deliveryStates[message.messageId] ??
                      _serverDeliveryState(message.messageId, lastCommonRead),
                ),
              ],
            ),
          );
        }
      final operation = pending[contentIndex - messages.length];
      return _PendingMessageBubble(
        key: ValueKey('chat-pending-${operation.operationId}'),
        account: account,
        operation: operation,
        onRetry: onRetry,
        onResend: () => onResend(operation),
        onCancel: () => onCancel(operation),
      );
    }

    // Everything newer than the anchor is laid out BEFORE the centre sliver,
    // which is what stops an arriving message from moving the history the
    // reader is looking at. A reversed `ListView` puts the newest item at
    // scroll offset zero, so every arrival re-indexed the whole list and
    // pushed the read position along the axis by that bubble's height. Slivers
    // before `center` grow away from offset zero instead, so the centre and
    // everything after it keep their positions.
    //
    // With no anchor the newer sliver is empty and this behaves exactly like
    // the reversed list did: the view stays pinned to the newest message,
    // which is what a reader sitting at the bottom wants.
    final anchorIndex = _anchorChronologicalIndex(itemCount);
    final newerCount = itemCount - 1 - anchorIndex;
    return CustomScrollView(
      key: const Key('chat-message-list'),
      controller: controller,
      reverse: true,
      center: _centreSliverKey,
      slivers: [
        // Always present, even with nothing in it: dropping the sliver would
        // change the slivers list and move which one `center` refers to, and
        // the reader's offset would then mean somewhere else. Its padding goes
        // to zero instead, because a SliverPadding contributes its padding
        // around nothing and that stray extent alone shifts the scroll range.
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, newerCount > 0 ? 12 : 0),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => buildAt(context, itemCount - 1 - index),
              childCount: newerCount,
            ),
          ),
        ),
        SliverPadding(
          key: _centreSliverKey,
          padding: EdgeInsets.fromLTRB(16, 12, 16, newerCount > 0 ? 0 : 12),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => buildAt(context, anchorIndex - index),
              childCount: anchorIndex + 1,
            ),
          ),
        ),
      ],
    );
  }

  /// Chronological index the centre sliver ends at.
  ///
  /// Without an anchor that is the newest item, so nothing lands in the sliver
  /// before the centre. Once the reader has scrolled away the pane freezes the
  /// anchor on the newest message they had seen, and everything that arrives
  /// after it goes into the sliver that cannot move them.
  int _anchorChronologicalIndex(int itemCount) {
    final anchor = anchorMessageId;
    if (anchor == null) {
      return itemCount - 1;
    }
    final offset = hasOlder ? 1 : 0;
    for (var index = messages.length - 1; index >= 0; index--) {
      if (messages[index].messageId <= anchor) {
        return index + offset;
      }
    }
    return itemCount - 1;
  }

  /// Whether the scope's confirmed ranges show a gap between the message at
  /// `index - 1` and the one at `index`. [messages] only ever contains rows
  /// [_messagesWithinBlocks] already verified as covered by some block, so a
  /// change of block between two consecutive entries always means real
  /// unfetched history sits between them, not merely an absent cache row.
  bool _gapBeforeContentIndex(int index) {
    final ranges = blocks;
    if (ranges == null || ranges.length < 2 || index <= 0) {
      return false;
    }
    final previousBlock = _blockIndexOf(ranges, messages[index - 1].messageId);
    final currentBlock = _blockIndexOf(ranges, messages[index].messageId);
    return previousBlock != currentBlock;
  }
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.account,
    required this.message,
    required this.parsed,
    required this.highlighted,
    required this.onJumpToMessage,
    required this.showAuthor,
    required this.showAvatar,
    required this.groupedWithPrevious,
    required this.groupEnd,
    required this.showReplyPreview,
    required this.onOpenThread,
    required this.onMessageActions,
    required this.onReplySwipe,
    required this.onReactionTap,
    required this.deliveryState,
  });

  final StoredAccount account;
  final CachedChatMessage message;
  final ChatMessage? parsed;

  /// Draws a short-lived ring around the bubble so the user can see where a
  /// jump landed.
  final bool highlighted;
  final ValueChanged<int> onJumpToMessage;
  final bool showAuthor;
  final bool showAvatar;
  final bool groupedWithPrevious;
  final bool groupEnd;
  final bool showReplyPreview;
  final ValueChanged<CachedChatMessage>? onOpenThread;
  final void Function(CachedChatMessage message, ChatMessage? parsed)
  onMessageActions;
  final ValueChanged<CachedChatMessage>? onReplySwipe;
  final void Function(
    CachedChatMessage message,
    ChatMessage? parsed,
    String emoji,
  )
  onReactionTap;
  final OutgoingMessageDeliveryState? deliveryState;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strings = AppLocalizations.of(context);
    final isSystem = message.systemMessage.isNotEmpty;
    // Exactly the reply gate the action sheet uses, plus the two kinds of
    // row that have nothing to reply to.
    final swipeToReply = onReplySwipe == null || isSystem || message.deleted
        ? null
        : () => onReplySwipe!(message);
    final outgoing = message.actorId == account.loginName;
    final authorLabel = chatParticipantSemanticsLabel(
      actorType: message.actorType,
      displayName: message.actorDisplayName,
      strings: strings,
    );
    final threadReplies = parsed?.threadReplies ?? 0;
    final canOpenThread =
        onOpenThread != null && (parsed?.isThread == true || threadReplies > 0);
    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
        child: Semantics(
          label: message.displayText,
          child: Text(
            message.displayText,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: groupedWithPrevious ? 2 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: outgoing
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!outgoing) ...[
            SizedBox(
              width: 32,
              height: 32,
              child: showAvatar
                  ? ExcludeSemantics(
                      child: ChatParticipantAvatar(
                        key: Key('chat-avatar-${message.messageId}'),
                        account: account,
                        actorType: message.actorType,
                        actorId: message.actorId,
                        displayName: message.actorDisplayName,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Align(
              alignment: outgoing
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Semantics(
                  key: Key('chat-message-semantics-${message.messageId}'),
                  container: true,
                  explicitChildNodes: true,
                  label: authorLabel,
                  child: _ReplySwipe(
                    messageId: message.messageId,
                    onReply: swipeToReply,
                    child: GestureDetector(
                      key: Key('chat-message-target-${message.messageId}'),
                      behavior: HitTestBehavior.opaque,
                      onLongPress: message.deleted
                          ? null
                          : () => onMessageActions(message, parsed),
                      // Same actions on right-click, for the same reason as the
                      // conversation rows.
                      onSecondaryTap: message.deleted
                          ? null
                          : () => onMessageActions(message, parsed),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        decoration: BoxDecoration(
                          color: outgoing
                              ? scheme.primaryContainer
                              : scheme.surfaceContainerHigh,
                          borderRadius: _bubbleRadius(
                            outgoing: outgoing,
                            groupEnd: groupEnd,
                          ),
                          border: highlighted
                              ? Border.all(color: scheme.tertiary, width: 2)
                              : null,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!outgoing && showAuthor)
                                ExcludeSemantics(
                                  child: Text(
                                    message.actorDisplayName,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: scheme.primary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              if (!outgoing && showAuthor)
                                const SizedBox(height: 2),
                              DefaultTextStyle.merge(
                                style: TextStyle(
                                  color: outgoing
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurface,
                                  fontStyle: message.deleted
                                      ? FontStyle.italic
                                      : null,
                                ),
                                child: ChatMessageContent(
                                  account: account,
                                  message: message.deleted ? null : parsed,
                                  fallbackText: message.deleted
                                      ? AppLocalizations.of(
                                          context,
                                        ).deletedMessage
                                      : message.displayText,
                                  foregroundColor: outgoing
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurface,
                                  showReplyPreview: showReplyPreview,
                                  onReactionTap: message.deleted
                                      ? null
                                      : (emoji) => onReactionTap(
                                          message,
                                          parsed,
                                          emoji,
                                        ),
                                  onOpenParent: onJumpToMessage,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (parsed?.lastEditTimestamp != null) ...[
                                    Text(
                                      AppLocalizations.of(context).edited,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: outgoing
                                                ? scheme.onPrimaryContainer
                                                : scheme.onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Text(
                                    _formatMessageClock(
                                      context,
                                      message.timestamp,
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: outgoing
                                              ? scheme.onPrimaryContainer
                                              : scheme.onSurfaceVariant,
                                        ),
                                  ),
                                  if (outgoing && deliveryState != null) ...[
                                    const SizedBox(width: 6),
                                    _DeliveryMark(
                                      key: Key(
                                        'chat-delivery-${message.messageId}',
                                      ),
                                      state: deliveryState!,
                                      color: scheme.onPrimaryContainer,
                                    ),
                                  ],
                                ],
                              ),
                              if (canOpenThread) ...[
                                const SizedBox(height: 2),
                                TextButton.icon(
                                  key: Key(
                                    'chat-open-thread-${message.messageId}',
                                  ),
                                  onPressed: () => onOpenThread!(message),
                                  style: TextButton.styleFrom(
                                    foregroundColor: outgoing
                                        ? scheme.onPrimaryContainer
                                        : scheme.primary,
                                    minimumSize: const Size(48, 48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.forum_outlined,
                                    size: 18,
                                  ),
                                  label: Text(
                                    threadReplies > 0
                                        ? strings.threadReplies(threadReplies)
                                        : strings.openThread,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.timestamp});

  final int timestamp;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
    ).toLocal();
    final today = DateTime.now();
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final strings = AppLocalizations.of(context);
    final label = _sameCalendarDay(date, today)
        ? strings.dateHeaderToday
        : _sameCalendarDay(date, yesterday)
        ? strings.dateHeaderYesterday
        : MaterialLocalizations.of(context).formatMediumDate(date);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      key: Key('chat-day-${date.year}-${date.month}-${date.day}'),
      container: true,
      excludeSemantics: true,
      header: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: color),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
      ),
    );
  }
}

/// Every own message the server already returned counts as delivered. The
/// read step comes from the server's common read marker, never from local
/// activity, so it also covers attachments and voice messages that never pass
/// through the text outbox.
OutgoingMessageDeliveryState? _serverDeliveryState(
  int messageId,
  int? lastCommonRead,
) {
  if (messageId < 1) {
    return null;
  }
  if (lastCommonRead != null && lastCommonRead >= messageId) {
    return OutgoingMessageDeliveryState.read;
  }
  return OutgoingMessageDeliveryState.sent;
}

int? _cursorValue(String? raw) {
  final parsed = raw == null ? null : int.tryParse(raw);
  return parsed == null || parsed < 0 ? null : parsed;
}

/// Only server-confirmed delivery is rendered. `sent` means the server stored
/// the message, `read` additionally means it is at or below the common read
/// marker; neither is inferred from local activity.
final class _DeliveryMark extends StatelessWidget {
  const _DeliveryMark({super.key, required this.state, required this.color});

  final OutgoingMessageDeliveryState state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final (icon, label) = switch (state) {
      OutgoingMessageDeliveryState.read => (
        Icons.done_all_rounded,
        strings.messageRead,
      ),
      OutgoingMessageDeliveryState.sent => (
        Icons.done_rounded,
        strings.messageSent,
      ),
      OutgoingMessageDeliveryState.failed => (
        Icons.error_outline_rounded,
        strings.outboxFailed,
      ),
      OutgoingMessageDeliveryState.sending => (
        Icons.schedule_send_rounded,
        strings.outboxSending,
      ),
    };
    return Icon(icon, size: 14, color: color, semanticLabel: label);
  }
}

List<ChatBlock>? _decodeScopeBlocks(StoredChatScope? scope) {
  if (scope == null) {
    return null;
  }
  try {
    return decodeChatScopeBlocks(scope.blocksJson);
  } on Object {
    return null;
  }
}

/// Keeps only cached messages the scope's blocks actually cover. With no
/// scope info yet ([blocks] is `null`) nothing is filtered, since there is
/// nothing to judge coverage against.
List<CachedChatMessage> _messagesWithinBlocks(
  List<CachedChatMessage> messages,
  List<ChatBlock>? blocks,
) {
  if (blocks == null) {
    return messages;
  }
  return messages
      .where((message) => _blockIndexOf(blocks, message.messageId) != -1)
      .toList(growable: false);
}

int _blockIndexOf(List<ChatBlock> blocks, int messageId) {
  final cursor = ChatCursor.parse(messageId.toString());
  for (var index = 0; index < blocks.length; index++) {
    if (blocks[index].contains(cursor)) {
      return index;
    }
  }
  return -1;
}

/// A visible divider marking a gap the client honestly knows about: two
/// cached ranges with unfetched messages between them. The current fetch
/// protocol only ever extends a scope's history/future cursor at its two
/// ends (see `planChatGetMerge`), so there is no request that can close an
/// interior gap; this only ever renders when a future feature (for example
/// jumping to a specific message) caches a range disconnected from what is
/// already known, which is why it does not offer a "load" action that
/// would have nothing to call.
final class _ChatHistoryGapNotice extends StatelessWidget {
  const _ChatHistoryGapNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = AppLocalizations.of(context).chatHistoryGapNotice;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Semantics(
        label: label,
        child: Row(
          children: [
            Expanded(child: Divider(color: scheme.outlineVariant)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(child: Divider(color: scheme.outlineVariant)),
          ],
        ),
      ),
    );
  }
}

ChatMessage? _parseCachedMessage(CachedChatMessage cached) {
  try {
    final decoded = jsonDecode(cached.rawJson);
    final message = ChatMessage.fromJson(decoded);
    if (message.messageId != cached.messageId ||
        message.roomToken.value != cached.roomToken) {
      return null;
    }
    return message;
  } on Object {
    return null;
  }
}

bool _shouldShowReplyPreview(ChatMessage? message, int? conversationThreadId) {
  if (conversationThreadId == null) {
    return true;
  }
  final parent = message?.parent;
  final parentId = switch (parent) {
    ChatFullParent() => parent.messageId,
    ChatDeletedParent() => parent.messageId,
    null => null,
  };
  return parentId != conversationThreadId;
}

bool _messagesShareGroup(CachedChatMessage earlier, CachedChatMessage later) {
  if (earlier.systemMessage.isNotEmpty ||
      later.systemMessage.isNotEmpty ||
      earlier.actorType != later.actorType ||
      earlier.actorId != later.actorId ||
      !_sameLocalDay(earlier.timestamp, later.timestamp)) {
    return false;
  }
  final difference = later.timestamp - earlier.timestamp;
  return difference >= 0 && difference <= 5 * 60;
}

bool _sameLocalDay(int leftUnixSeconds, int rightUnixSeconds) {
  final left = DateTime.fromMillisecondsSinceEpoch(
    leftUnixSeconds * 1000,
  ).toLocal();
  final right = DateTime.fromMillisecondsSinceEpoch(
    rightUnixSeconds * 1000,
  ).toLocal();
  return _sameCalendarDay(left, right);
}

bool _sameCalendarDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

BorderRadius _bubbleRadius({required bool outgoing, required bool groupEnd}) {
  const rounded = Radius.circular(16);
  const tail = Radius.circular(5);
  return BorderRadius.only(
    topLeft: rounded,
    topRight: rounded,
    bottomLeft: !outgoing && groupEnd ? tail : rounded,
    bottomRight: outgoing && groupEnd ? tail : rounded,
  );
}

String _formatMessageClock(BuildContext context, int unixSeconds) {
  final value = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
  ).toLocal();
  final localizations = MaterialLocalizations.of(context);
  return localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value));
}

/// Drag a bubble towards the start edge to reply to it, the way every other
/// messenger does. The bubble follows the finger a little and springs back;
/// crossing [_replySwipeThreshold] fires the same reply the action sheet does.
///
/// The follow is a [Transform], never a [Stack] or padding: the bubble already
/// sizes itself against the timeline's constraints, and anything that touches
/// layout here changes how it wraps.
final class _ReplySwipe extends StatefulWidget {
  const _ReplySwipe({
    required this.messageId,
    required this.onReply,
    required this.child,
  });

  final int messageId;
  final VoidCallback? onReply;
  final Widget child;

  @override
  State<_ReplySwipe> createState() => _ReplySwipeState();
}

const double _replySwipeThreshold = 56;
const double _replySwipeMaximum = 72;

final class _ReplySwipeState extends State<_ReplySwipe> {
  double _offset = 0;
  bool _armed = false;

  void _release({required bool fire}) {
    if (_offset != 0 || _armed) {
      setState(() {
        _offset = 0;
        _armed = false;
      });
    }
    if (fire) {
      widget.onReply!();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onReply == null) {
      return widget.child;
    }
    return GestureDetector(
      key: Key('chat-message-reply-swipe-${widget.messageId}'),
      // Only the horizontal axis is claimed; vertical drags stay with the
      // timeline, otherwise the list would not scroll over a bubble.
      onHorizontalDragUpdate: (details) {
        final next = (_offset + details.delta.dx).clamp(
          0.0,
          _replySwipeMaximum,
        );
        if (next != _offset) {
          setState(() {
            _offset = next;
            _armed = next >= _replySwipeThreshold;
          });
        }
      },
      onHorizontalDragEnd: (_) => _release(fire: _armed),
      onHorizontalDragCancel: () => _release(fire: false),
      child: Transform.translate(
        offset: Offset(_offset, 0),
        child: widget.child,
      ),
    );
  }
}

/// Returns the reader to the newest message after they have scrolled back.
///
/// It floats over the timeline rather than sitting in the column, so showing
/// it does not reflow the messages the reader is looking at.
final class _JumpToNewestButton extends StatelessWidget {
  const _JumpToNewestButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).jumpToNewestMessages;
    return FloatingActionButton.small(
      key: const Key('chat-jump-to-newest'),
      onPressed: onPressed,
      tooltip: label,
      child: Icon(Icons.arrow_downward_rounded, semanticLabel: label),
    );
  }
}
