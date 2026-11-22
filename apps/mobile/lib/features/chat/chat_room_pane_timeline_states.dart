part of 'chat_room_pane.dart';

const _provisionalOperationPrefix = 'provisional-';

/// Stand-in correlation id; a provisional row is display only and never sent.
const _provisionalReferenceUuid = '00000000-0000-4000-8000-000000000000';

/// A line the user sent that the outbox has not admitted yet.
///
/// Display only: nothing here is ever sent. The outbox row stays the one
/// record of what goes to the server, and this entry is dropped when that row
/// appears or the admission fails.
final class _ProvisionalSend {
  _ProvisionalSend({
    required this.id,
    required this.key,
    required this.message,
    required this.knownOperationIds,
    this.restorableDraft,
    this.emojiSizeStep,
  });

  final int id;
  final ChatRoomProviderKey key;
  final String message;

  /// Outbox rows that existed before this line was sent, so none of them can
  /// be the row it is admitted as.
  final Set<String> knownOperationIds;

  /// The composer text this line came from, when it can be put back.
  final String? restorableDraft;

  /// The enlargement picked by holding the quick emoji, shown from the first
  /// frame so the bubble does not change size once it is admitted.
  final int? emojiSizeStep;
  String? operationId;
  bool failed = false;

  StoredTextSendOperation asOperation(String accountId) {
    return StoredTextSendOperation(
      accountId: accountId,
      operationId: '$_provisionalOperationPrefix$id',
      roomToken: key.roomToken,
      referenceId: emojiSizeStep == null
          ? ''
          : ChatEmojiSizeReference(
              uuid: _provisionalReferenceUuid,
              step: emojiSizeStep!,
            ).referenceId,
      message: message,
      replayContractRevision: '',
      silent: false,
      enqueueSequence: id,
      outboxState: failed ? 'failed' : 'queued',
      attemptCount: 0,
      messageIdsJson: '[]',
      duplicateRiskAcknowledged: false,
      automaticResendCount: 0,
      createdAtMillis: 0,
      updatedAtMillis: 0,
    );
  }
}

final class _PendingMessageBubble extends StatefulWidget {
  const _PendingMessageBubble({
    super.key,
    required this.account,
    required this.operation,
    required this.onRetry,
    required this.onResend,
    required this.onCancel,
    this.groupedWithPrevious = false,
  });

  final StoredAccount account;
  final StoredTextSendOperation operation;

  /// Whether the bubble continues a run of the user's own messages.
  final bool groupedWithPrevious;
  final VoidCallback onRetry;
  final VoidCallback onResend;
  final VoidCallback onCancel;

  @override
  State<_PendingMessageBubble> createState() => _PendingMessageBubbleState();
}

final class _PendingMessageBubbleState extends State<_PendingMessageBubble> {
  /// A send that goes straight out is queued for a fraction of a second. Its
  /// cancel button would only flash and make the bubble jump, so the button
  /// waits until the message has really been sitting in the queue.
  static const _queuedGrace = Duration(milliseconds: 1500);

  Timer? _graceTimer;

  StoredAccount get account => widget.account;
  StoredTextSendOperation get operation => widget.operation;
  VoidCallback get onRetry => widget.onRetry;
  VoidCallback get onResend => widget.onResend;
  VoidCallback get onCancel => widget.onCancel;

  Duration get _queuedFor => Duration(
    milliseconds:
        DateTime.now().millisecondsSinceEpoch - operation.createdAtMillis,
  );

  @override
  void initState() {
    super.initState();
    final remaining = _queuedGrace - _queuedFor;
    if (remaining > Duration.zero) {
      _graceTimer = Timer(remaining, () {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = switch (operation.outboxState) {
      'queued' => strings.outboxQueued,
      'sending' => strings.outboxSending,
      'retryable' => strings.outboxRetryable,
      'awaitingConfirmation' => strings.outboxAwaitingConfirmation,
      'failed' => strings.outboxFailed,
      _ => strings.outboxFailed,
    };
    // An admission cannot be called back, so the stand-in has nothing to
    // cancel until it fails.
    // A send in flight cannot be cancelled either: the repository refuses it.
    // Leaving the button out keeps the row as low as a sent bubble's, so the
    // bubble does not change height when the server confirms it.
    final cancelable =
        operation.outboxState != 'sending' &&
        (operation.outboxState != 'queued' || _queuedFor >= _queuedGrace) &&
        (!operation.operationId.startsWith(_provisionalOperationPrefix) ||
            operation.outboxState == 'failed');
    final retryable = operation.outboxState == 'retryable';
    final ambiguous = operation.outboxState == 'awaitingConfirmation';
    final resourceUrl = exactGiphyResource(operation.message);
    final isGiphy = resourceUrl != null;
    // The colours a sent outgoing bubble resolves to, the room's shared
    // appearance included, so confirmation does not recolour the bubble.
    final shared = SharedChatAppearance.maybeOf(context);
    final colors = resolveBubbleColors(
      outgoing: true,
      scheme: scheme,
      sharedBubble: shared?.ownBubble,
      sharedText: shared?.ownText,
    );
    final onBubble = colors.foreground;
    final action = IconButtonThemeData(
      style: IconButton.styleFrom(
        // The row, not the text, drove the old height: three default icon
        // buttons reserve 48 each. Compact keeps a 40 target and gives the
        // bubble back a third of its height.
        padding: EdgeInsets.zero,
        minimumSize: const Size.square(40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: onBubble,
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: widget.groupedWithPrevious ? 2 : 12),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Semantics(
            container: true,
            label: status,
            child: DecoratedBox(
              // Same shape and colour as a sent outgoing bubble, so a message
              // on its way no longer reads as a separate card.
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: _bubbleRadius(
                  outgoing: true,
                  groupedWithPrevious: widget.groupedWithPrevious,
                  groupEnd: true,
                ),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  8,
                  12,
                  cancelable || retryable || ambiguous ? 4 : 7,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isGiphy)
                      ChatPendingGiphyReference(
                        account: account,
                        resourceUrl: resourceUrl,
                        foregroundColor: onBubble,
                      )
                    else if (isEmojiOnlyMessage(operation.message))
                      ChatEnlargedEmoji(
                        text: operation.message.trim(),
                        color: onBubble,
                        step:
                            ChatEmojiSizeReference.tryParse(
                              operation.referenceId,
                            )?.step ??
                            0,
                      )
                    else
                      Text(
                        normalizeGiphyReferencePreview(operation.message),
                        style: TextStyle(color: onBubble),
                      ),
                    IconButtonTheme(
                      data: action,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            ambiguous || operation.outboxState == 'failed'
                                ? Icons.warning_amber_rounded
                                : Icons.schedule_send_rounded,
                            size: 14,
                            color: onBubble.withValues(alpha: 0.75),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              status,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: onBubble.withValues(alpha: 0.75),
                                  ),
                            ),
                          ),
                          if (retryable)
                            IconButton(
                              key: Key('chat-retry-${operation.operationId}'),
                              onPressed: onRetry,
                              tooltip: strings.retrySend,
                              iconSize: 18,
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                          if (ambiguous)
                            IconButton(
                              key: Key('chat-resend-${operation.operationId}'),
                              onPressed: onResend,
                              tooltip: strings.resendMessage,
                              iconSize: 18,
                              icon: const Icon(Icons.send_rounded),
                            ),
                          // Every pending state stays cancelable. Ambiguous
                          // sends can refuse it with a visible explanation.
                          if (cancelable)
                            IconButton(
                              key: Key('chat-cancel-${operation.operationId}'),
                              onPressed: onCancel,
                              tooltip: strings.cancelSend,
                              iconSize: 18,
                              icon: const Icon(Icons.close_rounded),
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

final class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        assert(constraints.hasBoundedHeight);
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: ChatBackgroundChip(
                  padding: const EdgeInsets.all(20),
                  radius: 20,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 52,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        strings.chatEmpty,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        strings.chatEmptyBody,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
