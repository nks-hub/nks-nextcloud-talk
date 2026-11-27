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
      decoration: BoxDecoration(
        color:
            ChatBackgroundChip.colorOf(context) ??
            Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _chatContentMaxWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: ConversationAvatar(
                    account: account,
                    conversation: conversation,
                    radius: context.headerAvatarRadius,
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
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Recomputes only when [key] changes; lists in a record key compare by
/// identity, so a stream that has not emitted costs nothing.
final class _Memo<T> {
  Object? _key;
  T? _value;
  bool _filled = false;

  T call(Object? key, T Function() compute) {
    if (!_filled || key != _key) {
      _value = compute();
      _key = key;
      _filled = true;
    }
    return _value as T;
  }

  void clear() {
    _filled = false;
    _key = null;
    _value = null;
  }
}

/// What the timeline derives from the cached rows, apart from the bubbles.
typedef _TimelineLayout = ({
  List<ChatMessage?> parsed,
  Set<int> pendingMessageIds,
  Set<int> threadsWithVisibleReplies,
  Map<int, List<int>> albumRows,
  Map<String, List<int>> confirmedAttachments,
  Set<int> hidden,
});

/// What the pane reads out of the conversation's JSON, each of which decodes
/// it again.
typedef _RoomFacts = ({
  ChatPostingAccess postingAccess,
  ChatTypingRoomKey? typingKey,
  PinnedMessageState pinned,
  int scheduledMessages,
});

/// Everything the pane derives from the current room's streams, kept across
/// rebuilds. The pane rebuilds many times per send, and each of these is
/// linear in the room's cached history.
final class _TimelineCache {
  final blocks = _Memo<List<ChatBlock>?>();
  final visible = _Memo<List<CachedChatMessage>>();
  final attachments = _Memo<List<PendingAttachmentBatch>>();
  final layout = _Memo<_TimelineLayout>();
  final room = _Memo<_RoomFacts>();
  final canShare = _Memo<bool>();
  final Map<int, (String, ChatMessage?)> _parsed = {};

  /// Decodes a row once per `rawJson`; an edit, reaction or delete rewrites
  /// the JSON and is decoded again.
  ChatMessage? parse(CachedChatMessage cached) {
    final hit = _parsed[cached.messageId];
    if (hit != null && hit.$1 == cached.rawJson) {
      return hit.$2;
    }
    final parsed = _parseCachedMessage(cached);
    _parsed[cached.messageId] = (cached.rawJson, parsed);
    return parsed;
  }

  /// Drops decoded rows that left the timeline.
  void retain(List<CachedChatMessage> messages) {
    if (_parsed.isEmpty) {
      return;
    }
    final ids = {for (final message in messages) message.messageId};
    _parsed.removeWhere((messageId, _) => !ids.contains(messageId));
  }

  void clear() {
    blocks.clear();
    visible.clear();
    attachments.clear();
    layout.clear();
    room.clear();
    canShare.clear();
    _parsed.clear();
  }
}

final class _ChatTimeline extends StatelessWidget {
  const _ChatTimeline({
    required this.cache,
    required this.account,
    required this.conversation,
    required this.threadId,
    required this.inlineReplies,
    required this.readerIsActive,
    required this.messages,
    required this.blocks,
    required this.pending,
    required this.selectedOperationId,
    required this.attachments,
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

  final _TimelineCache cache;
  final StoredAccount account;
  final CachedConversation conversation;
  final int? threadId;

  /// Replies are shown in this timeline under their quoted parent, so a
  /// derived reply count would only point at what is already on screen.
  final bool inlineReplies;
  final bool Function() readerIsActive;
  final List<CachedChatMessage> messages;

  /// The scope's confirmed message-id ranges, `null` when the scope itself
  /// hasn't loaded yet. More than one entry means the client knows about a
  /// gap between two cached ranges (see [_gapBeforeContentIndex]).
  final List<ChatBlock>? blocks;
  final List<StoredTextSendOperation> pending;
  final String? selectedOperationId;
  final List<PendingAttachmentBatch> attachments;
  final bool hasOlder;
  final bool loadingOlder;
  final ChatScrollController controller;
  final VoidCallback onLoadOlder;
  final ValueChanged<StoredTextSendOperation> onRetry;
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
    if (messages.isEmpty &&
        pending.isEmpty &&
        attachments.isEmpty &&
        !hasOlder) {
      return const _EmptyChat();
    }
    final itemCount =
        messages.length +
        pending.length +
        attachments.length +
        (hasOlder ? 1 : 0);
    final (
      parsed: parsedMessages,
      :pendingMessageIds,
      :threadsWithVisibleReplies,
      :albumRows,
      :confirmedAttachments,
      :hidden,
    ) = cache.layout((
      messages,
      blocks,
      attachments,
      inlineReplies,
      anchorMessageId,
      // Not the account row: it is rewritten on every sync.
      account.id,
      account.serverUrl,
    ), _layout);
    Widget buildAt(BuildContext context, int chronologicalIndex) {
      if (hasOlder && chronologicalIndex == 0) {
        return Center(
          key: const Key('chat-load-older'),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ChatBackgroundChip(
              padding: EdgeInsets.zero,
              radius: 20,
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
          ),
        );
      }
      final contentIndex = chronologicalIndex - (hasOlder ? 1 : 0);
      if (contentIndex < messages.length) {
        if (hidden.contains(contentIndex)) {
          if (pendingMessageIds.contains(messages[contentIndex].messageId)) {
            return const SizedBox.shrink();
          }
          return ChatMessageExtentObserver(
            controller: controller,
            messageId: messages[contentIndex].messageId,
            child: const SizedBox.shrink(),
          );
        }
        final album = albumRows[contentIndex];
        final firstIndex = album?.first ?? contentIndex;
        final message = messages[firstIndex];
        final lastMessage = messages[contentIndex];
        final parsed = parsedMessages[firstIndex] ?? cache.parse(message);
        final previous = firstIndex == 0 ? null : messages[firstIndex - 1];
        final next = contentIndex + 1 >= messages.length
            ? null
            : messages[contentIndex + 1];
        final gapBeforeThis = _gapBeforeContentIndex(firstIndex);
        // The divider under a thread's root breaks the author's group.
        final isRoot = threadId != null && message.messageId == threadId;
        final groupedWithPrevious =
            !gapBeforeThis &&
            previous != null &&
            previous.messageId != threadId &&
            _messagesShareGroup(previous, message);
        // The last confirmed message also joins a pending bubble below it.
        final groupedWithNext =
            lastMessage.messageId != threadId &&
            (next != null
                ? _messagesShareGroup(lastMessage, next)
                : pending.isNotEmpty &&
                      _pendingSharesGroup(lastMessage, account.loginName));
        final startsDay =
            gapBeforeThis ||
            previous == null ||
            !_sameLocalDay(previous.timestamp, message.timestamp);
        return KeyedSubtree(
          key: ValueKey(
            'chat-message-${account.id}-${conversation.token}-${lastMessage.messageId}',
          ),
          child: ChatMessageExtentObserver(
            controller: controller,
            messageId: lastMessage.messageId,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (gapBeforeThis)
                  const _ChatHistoryGapNotice(key: Key('chat-history-gap')),
                if (startsDay) _DaySeparator(timestamp: message.timestamp),
                _MessageBubble(
                  key:
                      (album ?? [contentIndex]).any(
                        (index) => messages[index].messageId == jumpTargetId,
                      )
                      ? jumpTargetKey
                      : null,
                  account: account,
                  conversation: conversation,
                  message: message,
                  parsed: parsed,
                  highlighted: (album ?? [contentIndex]).any(
                    (index) =>
                        messages[index].messageId == highlightedMessageId,
                  ),
                  content: album == null
                      ? null
                      : ChatPhotoAlbumContent(
                          account: account,
                          messages: [
                            for (final index in album) parsedMessages[index]!,
                          ],
                          foregroundColor: resolveBubbleColors(
                            outgoing: message.actorId == account.loginName,
                            scheme: Theme.of(context).colorScheme,
                            sharedBubble: message.actorId == account.loginName
                                ? SharedChatAppearance.maybeOf(
                                    context,
                                  )?.ownBubble
                                : SharedChatAppearance.maybeOf(
                                    context,
                                  )?.otherBubble,
                            sharedText: message.actorId == account.loginName
                                ? SharedChatAppearance.maybeOf(context)?.ownText
                                : SharedChatAppearance.maybeOf(
                                    context,
                                  )?.otherText,
                          ).foreground,
                          showReplyPreview: _shouldShowReplyPreview(
                            parsed,
                            threadId,
                          ),
                          onOpenParent: onJumpToMessage,
                          onMessageActions: (photo) => onMessageActions(
                            messages.firstWhere(
                              (row) => row.messageId == photo.messageId,
                            ),
                            photo,
                          ),
                          onReactionTap: (photo, emoji) => onReactionTap(
                            messages.firstWhere(
                              (row) => row.messageId == photo.messageId,
                            ),
                            photo,
                            emoji,
                          ),
                        ),
                  onJumpToMessage: onJumpToMessage,
                  // A direct chat has one other sender, so naming them is noise.
                  showAuthor:
                      !groupedWithPrevious &&
                      (conversation.roomType != _oneToOneRoomType ||
                          message.actorType != 'users'),
                  showAvatar: !groupedWithNext,
                  groupedWithPrevious: groupedWithPrevious,
                  groupEnd: !groupedWithNext,
                  showReplyPreview: _shouldShowReplyPreview(parsed, threadId),
                  inlineReplies: inlineReplies,
                  repliesVisible: threadsWithVisibleReplies.contains(
                    message.messageId,
                  ),
                  readerIsActive: readerIsActive,
                  onOpenThread: threadId == null ? onOpenThread : null,
                  onMessageActions: onMessageActions,
                  onReplySwipe: onReplySwipe,
                  onReactionTap: onReactionTap,
                  deliveryState:
                      deliveryStates[lastMessage.messageId] ??
                      _serverDeliveryState(
                        lastMessage.messageId,
                        lastCommonRead,
                      ),
                  isThreadRoot: isRoot,
                ),
                if (isRoot)
                  _ThreadRepliesDivider(
                    // A named thread's root reports no replies of its own, so
                    // the rows below it in this timeline are the fallback.
                    count: math.max(
                      parsed?.threadReplies ?? 0,
                      messages.length - firstIndex - 1,
                    ),
                  ),
              ],
            ),
          ),
        );
      }
      final pendingIndex = contentIndex - messages.length;
      if (pendingIndex >= pending.length) {
        final batch = attachments[pendingIndex - pending.length];
        final confirmed = confirmedAttachments[batch.key]!;
        Widget bubble = PendingAttachmentBubble(
          key: batch.confirmedMessageIds.contains(jumpTargetId)
              ? jumpTargetKey
              : ValueKey(batch.key),
          batch: batch,
          highlighted: batch.confirmedMessageIds.contains(highlightedMessageId),
          confirmedContent: confirmed.isEmpty
              ? null
              : ChatPhotoAlbumContent(
                  account: account,
                  messages: [
                    for (final index in confirmed) parsedMessages[index]!,
                  ],
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onPrimaryContainer,
                  showReplyPreview: _shouldShowReplyPreview(
                    parsedMessages[confirmed.first],
                    threadId,
                  ),
                  onOpenParent: onJumpToMessage,
                  onMessageActions: (photo) => onMessageActions(
                    messages.firstWhere(
                      (row) => row.messageId == photo.messageId,
                    ),
                    photo,
                  ),
                  onReactionTap: (photo, emoji) => onReactionTap(
                    messages.firstWhere(
                      (row) => row.messageId == photo.messageId,
                    ),
                    photo,
                    emoji,
                  ),
                ),
        );
        for (final index in confirmed) {
          bubble = ChatMessageExtentObserver(
            controller: controller,
            messageId: messages[index].messageId,
            child: bubble,
          );
        }
        return bubble;
      }
      final operation = pending[pendingIndex];
      final bubble = _PendingMessageBubble(
        key: ValueKey('chat-pending-${operation.operationId}'),
        account: account,
        operation: operation,
        // The gap a sent bubble would get here, so confirmation moves nothing.
        groupedWithPrevious:
            pendingIndex > 0 ||
            (messages.isNotEmpty &&
                messages.last.messageId != threadId &&
                _pendingSharesGroup(messages.last, account.loginName)),
        groupEnd: pendingIndex == pending.length - 1,
        onRetry: () => onRetry(operation),
        onResend: () => onResend(operation),
        onCancel: () => onCancel(operation),
      );
      if (operation.operationId != selectedOperationId) return bubble;
      return DecoratedBox(
        key: ValueKey('undelivered-target-${operation.operationId}'),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 3,
            ),
          ),
        ),
        child: bubble,
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
    // Scoped, not global: a room pane and a thread pane are on screen at the
    // same time on a wide window, and one shared key left the second viewport
    // without a centre at all ('center != null' inside the framework).
    final centreKey = ValueKey(
      'chat-centre-${account.id}-${conversation.token}-$threadId',
    );
    final newerCount = itemCount - 1 - anchorIndex;
    final historyAnchored = anchorMessageId != null;
    return LayoutBuilder(
      builder: (context, box) {
        final horizontalInset = math.max(
          16.0,
          (box.maxWidth - _chatContentMaxWidth) / 2,
        );
        return CustomScrollView(
          key: const Key('chat-message-list'),
          controller: controller,
          reverse: true,
          center: centreKey,
          slivers: [
            // Keep both slivers in place as newer rows arrive. At offset zero
            // the empty sliver is below the viewport, so the centre owns the gap.
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalInset,
                0,
                horizontalInset,
                historyAnchored ? 12 : 0,
              ),
              sliver: SliverList(
                // This sliver grows down from the centre, so its first child
                // sits right under the anchor: the oldest of the newer rows.
                delegate: SliverChildBuilderDelegate(
                  (context, index) => buildAt(context, anchorIndex + 1 + index),
                  childCount: newerCount,
                ),
              ),
            ),
            SliverPadding(
              key: centreKey,
              padding: EdgeInsets.fromLTRB(
                horizontalInset,
                12,
                horizontalInset,
                historyAnchored ? 0 : 12,
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => buildAt(context, anchorIndex - index),
                  childCount: anchorIndex + 1,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Album grouping and the rows folded into another bubble. Linear in the
  /// cached history, so it runs through [_TimelineCache.layout].
  _TimelineLayout _layout() {
    final parsedMessages = messages
        .map(
          (message) => message.referenceId.startsWith('otg1.')
              ? cache.parse(message)
              : null,
        )
        .toList();
    final pendingMessageIds = {
      for (final batch in attachments) ...batch.confirmedMessageIds,
    };
    final albums = groupPhotoAlbums(
      parsedMessages,
      canGroup: (index) =>
          !pendingMessageIds.contains(messages[index].messageId) &&
          !messages[index].deleted &&
          parsedMessages[index] != null &&
          (inlineReplies || (parsedMessages[index]!.threadReplies ?? 0) == 0) &&
          chatGalleryImage(account, parsedMessages[index]!) != null,
      boundaryBefore: (index) =>
          _gapBeforeContentIndex(index) ||
          !_sameLocalDay(
            messages[index - 1].timestamp,
            messages[index].timestamp,
          ) ||
          (anchorMessageId != null &&
              messages[index - 1].messageId <= anchorMessageId! &&
              messages[index].messageId > anchorMessageId!),
    );
    final albumRows = {for (final album in albums) album.last: album};
    final confirmedAttachments = {
      for (final batch in attachments)
        batch.key: _confirmedIndices(batch.confirmedMessageIds, parsedMessages),
    };
    return (
      parsed: parsedMessages,
      pendingMessageIds: pendingMessageIds,
      threadsWithVisibleReplies: {
        if (inlineReplies)
          for (final row in messages)
            if (row.threadId case final int id
                when id > 0 && id != row.messageId)
              id,
      },
      albumRows: albumRows,
      confirmedAttachments: confirmedAttachments,
      hidden: {
        for (final album in albums) ...album.take(album.length - 1),
        for (final indices in confirmedAttachments.values) ...indices,
      },
    );
  }

  List<int> _confirmedIndices(Set<int> confirmed, List<ChatMessage?> parsed) =>
      [
        for (var index = 0; index < messages.length; index++)
          if (confirmed.contains(messages[index].messageId) &&
              parsed[index] != null &&
              chatGalleryImage(account, parsed[index]!) != null)
            index,
      ];

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

/// Closes the root message of a thread and says how many replies follow it.
final class _ThreadRepliesDivider extends StatelessWidget {
  const _ThreadRepliesDivider({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final label = count == 0
        ? strings.threadNoReplies
        : strings.threadReplies(count);
    return Semantics(
      key: const Key('chat-thread-replies-divider'),
      container: true,
      excludeSemantics: true,
      header: true,
      label: label,
      child: SelectionContainer.disabled(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          // The label may take 80 % of the row; past that it wraps instead of
          // pushing the rule lines out of the layout at large text sizes.
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * 0.8),
                    child: ChatBackgroundChip(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
          ),
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
  final bounds = _blockBounds(blocks);
  return messages
      .where(
        (message) => _blockIndexWithin(bounds, blocks, message.messageId) != -1,
      )
      .toList(growable: false);
}

int _blockIndexOf(List<ChatBlock> blocks, int messageId) =>
    _blockIndexWithin(_blockBounds(blocks), blocks, messageId);

/// The blocks as integer ranges, or null when a cursor does not fit an int.
/// Message ids are ints, and building a cursor string for every row of the
/// room just to compare it was most of the cost of the filter.
List<(int, int)>? _blockBounds(List<ChatBlock> blocks) {
  final bounds = <(int, int)>[];
  for (final block in blocks) {
    final start = int.tryParse(block.start.value);
    final end = int.tryParse(block.end.value);
    if (start == null || end == null) {
      return null;
    }
    bounds.add((start, end));
  }
  return bounds;
}

int _blockIndexWithin(
  List<(int, int)>? bounds,
  List<ChatBlock> blocks,
  int messageId,
) {
  if (bounds != null) {
    for (var index = 0; index < bounds.length; index++) {
      if (bounds[index].$1 <= messageId && messageId <= bounds[index].$2) {
        return index;
      }
    }
    return -1;
  }
  final cursor = ChatCursor.parse(messageId.toString());
  for (var index = 0; index < blocks.length; index++) {
    if (blocks[index].contains(cursor)) {
      return index;
    }
  }
  return -1;
}

/// A visible divider marking a gap the client honestly knows about: two
/// cached ranges with unfetched messages between them, such as a sent
/// message confirmed before the catch-up that joins it to the rest. A jump's
/// island never shows here: the timeline lists it on its own.
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
              child: ChatBackgroundChip(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
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

/// Whether a message of [loginName] sent now would join [earlier]'s group,
/// by the rule [_messagesShareGroup] applies once the server confirms it.
bool _pendingSharesGroup(CachedChatMessage earlier, String loginName) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final difference = now - earlier.timestamp;
  return earlier.systemMessage.isEmpty &&
      earlier.actorType == 'users' &&
      earlier.actorId == loginName &&
      _sameLocalDay(earlier.timestamp, now) &&
      // A little slack below zero: the server's clock may run ahead of ours.
      difference >= -60 &&
      difference <= 5 * 60;
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

/// Outer corners are round; on the side where consecutive messages of one
/// sender join, the corners that touch a neighbour tighten so the run reads as
/// one stack.
BorderRadius _bubbleRadius({
  required bool outgoing,
  required bool groupedWithPrevious,
  required bool groupEnd,
}) {
  const round = Radius.circular(20);
  const joined = Radius.circular(5);
  final top = groupedWithPrevious ? joined : round;
  final bottom = groupEnd ? round : joined;
  return outgoing
      ? BorderRadius.only(
          topLeft: round,
          bottomLeft: round,
          topRight: top,
          bottomRight: bottom,
        )
      : BorderRadius.only(
          topRight: round,
          bottomRight: round,
          topLeft: top,
          bottomLeft: bottom,
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
/// Returns the reader to the newest message after they have scrolled back.
///
/// It floats over the timeline rather than sitting in the column, so showing
/// it does not reflow the messages the reader is looking at.
final class _JumpToNewestButton extends StatelessWidget {
  const _JumpToNewestButton({required this.onPressed, this.newer = 0});

  final VoidCallback onPressed;

  /// Messages that arrived while the reader was in an island.
  final int newer;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).jumpToNewestMessages;
    return Badge(
      key: const Key('chat-jump-to-newest-count'),
      isLabelVisible: newer > 0,
      label: Text('$newer'),
      child: FloatingActionButton.small(
        key: const Key('chat-jump-to-newest'),
        onPressed: onPressed,
        tooltip: label,
        child: Icon(Icons.arrow_downward_rounded, semanticLabel: label),
      ),
    );
  }
}
