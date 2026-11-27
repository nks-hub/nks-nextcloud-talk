part of 'chat_room_pane.dart';

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.account,
    required this.conversation,
    required this.message,
    required this.parsed,
    required this.highlighted,
    required this.onJumpToMessage,
    required this.showAuthor,
    required this.showAvatar,
    required this.groupedWithPrevious,
    required this.groupEnd,
    required this.showReplyPreview,
    required this.inlineReplies,
    required this.readerIsActive,
    required this.repliesVisible,
    required this.onOpenThread,
    required this.onMessageActions,
    required this.onReplySwipe,
    required this.onReactionTap,
    required this.deliveryState,
    this.content,
    this.isThreadRoot = false,
  });

  final StoredAccount account;
  final CachedConversation conversation;
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
  final bool inlineReplies;
  final bool Function() readerIsActive;
  final bool repliesVisible;
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
  final Widget? content;

  /// The message a thread opened on. It gets an outline so it stands apart
  /// from the replies below it.
  final bool isThreadRoot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = AppLocalizations.of(context);
    final isSystem = message.systemMessage.isNotEmpty;
    // Exactly the reply gate the action sheet uses, plus the two kinds of
    // row that have nothing to reply to.
    final swipeToReply = onReplySwipe == null || isSystem || message.deleted
        ? null
        : () => onReplySwipe!(message);
    // The one gate on the action sheet, read by the long press, the right
    // click and the keyboard alike so they cannot drift apart.
    final messageActions = message.deleted
        ? null
        : () => onMessageActions(message, parsed);
    final outgoing = message.actorId == account.loginName;
    final shared = SharedChatAppearance.maybeOf(context);
    final colors = resolveBubbleColors(
      outgoing: outgoing,
      scheme: scheme,
      sharedBubble: outgoing ? shared?.ownBubble : shared?.otherBubble,
      sharedText: outgoing ? shared?.ownText : shared?.otherText,
    );
    final authorLabel = chatParticipantSemanticsLabel(
      actorType: message.actorType,
      displayName: message.actorDisplayName,
      strings: strings,
    );
    final threadReplies = parsed?.threadReplies ?? 0;
    final canOpenThread =
        onOpenThread != null &&
        (parsed?.isThread == true || (!inlineReplies && threadReplies > 0));
    if (isSystem) {
      // The time belongs here as much as on an ordinary message: a run of
      // "joined the call" / "left the call" is unreadable without it
      // (reported on 5 September 2026). Same clock helper as the bubbles, so
      // the two cannot drift apart, and it is in the spoken label too.
      final clock = _formatMessageClock(context, message.timestamp);
      return ChatSelectionJoin(
        separator: '\n',
        breakBefore: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
          child: Semantics(
            label: '${message.displayText} · $clock',
            child: ChatBackgroundChip(
              centered: true,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: message.displayText),
                    const TextSpan(text: '  '),
                    TextSpan(
                      text: clock,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      );
    }
    final desktopThread =
        canOpenThread && !repliesVisible && context.sendsOnEnter
        ? ChatThreadContext.fromCachedRoot(
            accountId: account.id,
            roomToken: conversation.token,
            root: message,
          )
        : null;

    final headerAbove = !outgoing && !groupedWithPrevious;
    final inlineClock =
        outgoing &&
        content == null &&
        !message.deleted &&
        parsed?.parent == null &&
        (parsed?.messageParameters.isEmpty ?? true) &&
        (parsed?.reactions.isEmpty ?? true) &&
        !message.displayText.contains('\n') &&
        !message.displayText.contains('://');
    final metaStyle = theme.textTheme.labelSmall?.copyWith(
      color: headerAbove ? scheme.onSurfaceVariant : colors.meta,
    );
    final metadata = SelectionContainer.disabled(
      child: Wrap(
        spacing: 5,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (parsed?.lastEditTimestamp != null)
            Text(strings.edited, style: metaStyle),
          Text(
            _formatMessageClock(context, message.timestamp),
            key: Key('chat-clock-${message.messageId}'),
            style: metaStyle,
          ),
          if (outgoing && deliveryState != null)
            _DeliveryMark(
              key: Key('chat-delivery-${message.messageId}'),
              state: deliveryState!,
              color: colors.foreground,
            ),
        ],
      ),
    );
    final body = DefaultTextStyle.merge(
      style: TextStyle(
        color: colors.foreground,
        fontStyle: message.deleted ? FontStyle.italic : null,
      ),
      child:
          content ??
          ChatMessageContent(
            account: account,
            message: message.deleted ? null : parsed,
            fallbackText: message.deleted
                ? strings.deletedMessage
                : message.displayText,
            foregroundColor: colors.foreground,
            showReplyPreview: showReplyPreview,
            onReactionTap: message.deleted
                ? null
                : (emoji) => onReactionTap(message, parsed, emoji),
            onOpenParent: onJumpToMessage,
          ),
    );
    final surface = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: _bubbleRadius(
          outgoing: outgoing,
          groupedWithPrevious: groupedWithPrevious,
          groupEnd: groupEnd,
        ),
        // A jump target gets two rings: the bubble's own
        // text colour against the bubble, and outside it
        // the tertiary colour against the room, so the
        // mark shows on light, dark and wallpaper alike.
        border: highlighted
            ? Border.all(color: colors.foreground, width: 2)
            : isThreadRoot
            ? Border.all(color: scheme.outlineVariant)
            : null,
        boxShadow: highlighted
            ? [BoxShadow(color: scheme.tertiary, spreadRadius: 2)]
            : null,
      ),
      child: DefaultSelectionStyle(
        // The default selection colour is the primary at
        // 40 %, which vanishes on a primary-filled bubble.
        selectionColor: colors.foreground.withValues(alpha: 0.35),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (inlineClock)
                Wrap(
                  spacing: 9,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [body, metadata],
                )
              else ...[
                body,
                if (!headerAbove) ...[const SizedBox(height: 3), metadata],
              ],
              if (canOpenThread && desktopThread == null) ...[
                const SizedBox(height: 2),
                SelectionContainer.disabled(
                  child: TextButton.icon(
                    key: Key('chat-open-thread-${message.messageId}'),
                    onPressed: () => onOpenThread!(message),
                    style: TextButton.styleFrom(
                      foregroundColor: outgoing || colors.shared
                          ? colors.foreground
                          : scheme.primary,
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    icon: const Icon(Icons.forum_outlined, size: 18),
                    label: Text(
                      threadReplies > 0
                          ? strings.threadReplies(threadReplies)
                          : strings.openThread,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    // One message per line when a selection runs across several of them;
    // the avatar initials, the clock and the buttons stay out of the copy.
    final bubble = ChatSelectionJoin(
      separator: '\n',
      breakBefore: true,
      child: Padding(
        padding: EdgeInsets.only(top: groupedWithPrevious ? 2 : 12),
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
                    ? SelectionContainer.disabled(
                        child: ExcludeSemantics(
                          child: ChatParticipantAvatar(
                            key: Key('chat-avatar-${message.messageId}'),
                            account: account,
                            actorType: message.actorType,
                            actorId: message.actorId,
                            displayName: message.actorDisplayName,
                          ),
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
                    child: _MessageAffordance(
                      key: Key('chat-message-affordance-${message.messageId}'),
                      messageId: message.messageId,
                      radius: _bubbleRadius(
                        outgoing: outgoing,
                        groupedWithPrevious: groupedWithPrevious,
                        groupEnd: groupEnd,
                      ),
                      onActions: messageActions,
                      child: _ReplySwipe(
                        messageId: message.messageId,
                        onReply: swipeToReply,
                        child: GestureDetector(
                          key: Key('chat-message-target-${message.messageId}'),
                          behavior: HitTestBehavior.opaque,
                          onLongPress: messageActions,
                          // Same actions on right-click, for the same reason as the
                          // conversation rows.
                          onSecondaryTap: messageActions,
                          child: headerAbove
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsetsDirectional.only(
                                        start: 3,
                                        bottom: 4,
                                      ),
                                      child: ChatBackgroundChip(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 2,
                                        ),
                                        child: SelectionContainer.disabled(
                                          child: Wrap(
                                            spacing: 8,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              if (showAuthor)
                                                ExcludeSemantics(
                                                  child: Text(
                                                    authorLabel,
                                                    style: theme
                                                        .textTheme
                                                        .labelLarge
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color:
                                                              scheme.onSurface,
                                                        ),
                                                  ),
                                                ),
                                              metadata,
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    surface,
                                  ],
                                )
                              : surface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (desktopThread == null) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bubble,
        Padding(
          padding: EdgeInsetsDirectional.only(start: outgoing ? 0 : 40),
          child: Align(
            alignment: outgoing
                ? AlignmentDirectional.centerEnd
                : AlignmentDirectional.centerStart,
            child: _DesktopThreadBranch(
              key: ValueKey((
                account.id,
                conversation.token,
                message.messageId,
              )),
              account: account,
              thread: desktopThread,
              readerIsActive: readerIsActive,
              replyCount: threadReplies,
              canPost: ChatPostingAccess.fromCachedConversation(
                conversation,
              ).canPost,
              onOpenThread: () => onOpenThread!(message),
            ),
          ),
        ),
      ],
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fill =
        ChatBackgroundChip.colorOf(context) ?? scheme.surfaceContainerHigh;
    final style = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Semantics(
      key: Key('chat-day-${date.year}-${date.month}-${date.day}'),
      container: true,
      excludeSemantics: true,
      header: true,
      label: label,
      // Kept out of a copied selection, like the clock on each message; it
      // used to land glued to the end of the message above it.
      child: SelectionContainer.disabled(
        child: Center(
          child: Container(
            margin: const EdgeInsets.fromLTRB(4, 14, 4, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: ShapeDecoration(
              color: fill,
              shape: StadiumBorder(
                side: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: Text(label, style: style),
          ),
        ),
      ),
    );
  }
}

final class _DesktopThreadBranch extends ConsumerStatefulWidget {
  const _DesktopThreadBranch({
    super.key,
    required this.account,
    required this.thread,
    required this.readerIsActive,
    required this.replyCount,
    required this.canPost,
    required this.onOpenThread,
  });

  final StoredAccount account;
  final ChatThreadContext thread;
  final bool Function() readerIsActive;
  final int replyCount;
  final bool canPost;
  final VoidCallback onOpenThread;

  @override
  ConsumerState<_DesktopThreadBranch> createState() =>
      _DesktopThreadBranchState();
}

final class _DesktopThreadBranchState
    extends ConsumerState<_DesktopThreadBranch> {
  static const _limit = 3;
  Stream<List<CachedChatMessage>>? _rows;
  bool _refreshing = false;
  bool _failed = false;

  Future<void> _load() async {
    final thread = widget.thread;
    final rows = ref
        .read(chatRepositoryProvider)
        .watchRecentThreadMessages(
          accountId: thread.accountId,
          roomToken: thread.roomToken,
          threadId: thread.rootMessageId,
          limit: _limit + 1,
        );
    setState(() {
      _rows = rows;
      _refreshing = true;
      _failed = false;
    });
    bool stillOpen() => mounted && identical(_rows, rows);
    var failed = false;
    try {
      final result = await ref
          .read(chatServiceProvider)
          .syncRoom(
            accountId: thread.accountId,
            roomToken: thread.roomToken,
            threadId: thread.rootMessageId,
            readerIsActive: () => stillOpen() && widget.readerIsActive(),
          );
      failed = result != ChatSynchronizationResult.converged;
    } on Object {
      failed = true;
    }
    if (!stillOpen()) return;
    setState(() {
      _refreshing = false;
      _failed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = AppLocalizations.of(context);
    final rows = _rows;
    final expanded = rows != null;
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(36, 34),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: theme.textTheme.labelMedium,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: ChatBackgroundChip(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectionContainer.disabled(
              child: Semantics(
                expanded: expanded,
                child: TextButton(
                  key: Key('chat-open-thread-${widget.thread.rootMessageId}'),
                  style: buttonStyle,
                  onPressed: () {
                    if (expanded) {
                      setState(() => _rows = null);
                    } else {
                      unawaited(_load());
                    }
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.forum_outlined, size: 16),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.replyCount > 0
                              ? strings.threadReplies(widget.replyCount)
                              : widget.thread.title ?? strings.thread,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 17,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (rows != null)
              Container(
                key: Key('chat-thread-preview-${widget.thread.rootMessageId}'),
                margin: const EdgeInsetsDirectional.only(start: 12, bottom: 5),
                padding: const EdgeInsetsDirectional.only(start: 14),
                decoration: BoxDecoration(
                  border: BorderDirectional(
                    start: BorderSide(
                      color: scheme.primary.withValues(alpha: .40),
                      width: 2,
                    ),
                  ),
                ),
                child: StreamBuilder<List<CachedChatMessage>>(
                  stream: rows,
                  builder: (context, snapshot) {
                    final replies =
                        (snapshot.data ?? const <CachedChatMessage>[])
                            .where(
                              (row) =>
                                  row.messageId != widget.thread.rootMessageId,
                            )
                            .toList(growable: false);
                    final showReplyAction =
                        widget.canPost &&
                        replies.length <= _limit &&
                        replies.length >= widget.replyCount;
                    final failed = snapshot.hasError || _failed;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final reply in replies.skip(
                          math.max(0, replies.length - _limit),
                        ))
                          _InlineThreadReply(
                            account: widget.account,
                            reply: reply,
                          ),
                        if (replies.isEmpty && !failed) ...[
                          if (_refreshing || !snapshot.hasData)
                            LinearProgressIndicator(
                              minHeight: 2,
                              semanticsLabel: strings.syncing,
                            )
                          else if (widget.replyCount == 0)
                            Text(
                              strings.threadNoReplies,
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                        if (failed)
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                strings.syncUnavailable,
                                style: theme.textTheme.bodySmall,
                              ),
                              TextButton(
                                onPressed: _refreshing
                                    ? null
                                    : () => unawaited(_load()),
                                style: buttonStyle,
                                child: Text(strings.retry),
                              ),
                            ],
                          ),
                        SelectionContainer.disabled(
                          child: TextButton.icon(
                            key: Key(
                              'chat-enter-thread-${widget.thread.rootMessageId}',
                            ),
                            onPressed: widget.onOpenThread,
                            style: buttonStyle,
                            icon: Icon(
                              showReplyAction ? Icons.reply : Icons.open_in_new,
                              size: 16,
                            ),
                            label: Text(
                              showReplyAction
                                  ? strings.replyInThread
                                  : strings.openThread,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _InlineThreadReply extends StatelessWidget {
  const _InlineThreadReply({required this.account, required this.reply});

  final StoredAccount account;
  final CachedChatMessage reply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);
    final author = chatParticipantSemanticsLabel(
      actorType: reply.actorType,
      displayName: reply.actorDisplayName,
      strings: strings,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: ChatParticipantAvatar(
              account: account,
              actorType: reply.actorType,
              actorId: reply.actorId,
              displayName: reply.actorDisplayName,
              size: 24,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(author, style: theme.textTheme.labelMedium),
                    Text(
                      _formatMessageClock(context, reply.timestamp),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Text(
                  reply.deleted ? strings.deletedMessage : reply.displayText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pointer and keyboard affordance around a message bubble.
///
/// The action sheet used to answer only to a long press and a right click, so
/// a keyboard had no way into it at all and a mouse got no hint that the
/// bubble was a target. The ring is drawn outside the bubble's own decoration
/// so showing it never moves the text, and it answers to focus as well as
/// hover: on hover alone the same actions stay invisible to anybody who is
/// not holding a mouse.
final class _MessageAffordance extends StatefulWidget {
  const _MessageAffordance({
    super.key,
    required this.messageId,
    required this.radius,
    required this.onActions,
    required this.child,
  });

  final int messageId;
  final BorderRadius radius;
  final VoidCallback? onActions;
  final Widget child;

  @override
  State<_MessageAffordance> createState() => _MessageAffordanceState();
}

final class _MessageAffordanceState extends State<_MessageAffordance> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Focus wins over hover when both hold: it is the one a person cannot see
    // their pointer sitting on.
    final ring = _focused
        ? scheme.primary
        : _hovered
        ? scheme.outlineVariant
        : Colors.transparent;
    return FocusableActionDetector(
      enabled: widget.onActions != null,
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActions?.call();
            return null;
          },
        ),
      },
      child: DecoratedBox(
        key: Key('chat-message-ring-${widget.messageId}'),
        decoration: BoxDecoration(
          borderRadius: widget.radius,
          border: Border.all(color: ring, width: 2),
        ),
        child: widget.child,
      ),
    );
  }
}

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
      // A finger swipes; a mouse drag along a line selects its text, so the
      // mouse is left to the selection region above the timeline.
      supportedDevices: const {
        ui.PointerDeviceKind.touch,
        ui.PointerDeviceKind.stylus,
        ui.PointerDeviceKind.invertedStylus,
      },
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
