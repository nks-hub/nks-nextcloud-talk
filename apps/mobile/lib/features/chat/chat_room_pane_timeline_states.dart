part of 'chat_room_pane.dart';

final class _PendingMessageBubble extends StatelessWidget {
  const _PendingMessageBubble({
    super.key,
    required this.account,
    required this.operation,
    required this.onRetry,
    required this.onResend,
    required this.onCancel,
  });

  final StoredAccount account;
  final StoredTextSendOperation operation;
  final VoidCallback onRetry;
  final VoidCallback onResend;
  final VoidCallback onCancel;

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
    final retryable = operation.outboxState == 'retryable';
    final ambiguous = operation.outboxState == 'awaitingConfirmation';
    final resourceUrl = exactGiphyResource(operation.message);
    final isGiphy = resourceUrl != null;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Card(
          color: scheme.secondaryContainer,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isGiphy)
                  ChatPendingGiphyReference(
                    account: account,
                    resourceUrl: resourceUrl,
                    foregroundColor: scheme.onSecondaryContainer,
                  )
                else
                  Text(
                    normalizeGiphyReferencePreview(operation.message),
                    style: TextStyle(color: scheme.onSecondaryContainer),
                  ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      ambiguous || operation.outboxState == 'failed'
                          ? Icons.warning_amber_rounded
                          : Icons.schedule_send_rounded,
                      size: 18,
                      color: scheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        status,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    if (retryable)
                      IconButton(
                        key: Key('chat-retry-${operation.operationId}'),
                        onPressed: onRetry,
                        tooltip: strings.retrySend,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    if (ambiguous)
                      IconButton(
                        key: Key('chat-resend-${operation.operationId}'),
                        onPressed: onResend,
                        tooltip: strings.resendMessage,
                        icon: const Icon(Icons.send_rounded),
                      ),
                    // Every pending state stays cancelable. Ambiguous sends
                    // can refuse the cancellation with a visible explanation.
                    IconButton(
                      key: Key('chat-cancel-${operation.operationId}'),
                      onPressed: onCancel,
                      tooltip: strings.cancelSend,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ],
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
        );
      },
    );
  }
}
