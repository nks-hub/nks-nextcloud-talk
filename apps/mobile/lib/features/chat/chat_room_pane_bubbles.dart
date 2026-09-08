part of 'chat_room_pane.dart';

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
    required this.inlineReplies,
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
  final bool inlineReplies;
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
    // The one gate on the action sheet, read by the long press, the right
    // click and the keyboard alike so they cannot drift apart.
    final messageActions = message.deleted
        ? null
        : () => onMessageActions(message, parsed);
    final outgoing = message.actorId == account.loginName;
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
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
        child: Semantics(
          label: '${message.displayText} · $clock',
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
                  child: _MessageAffordance(
                    key: Key('chat-message-affordance-${message.messageId}'),
                    messageId: message.messageId,
                    radius: _bubbleRadius(
                      outgoing: outgoing,
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
