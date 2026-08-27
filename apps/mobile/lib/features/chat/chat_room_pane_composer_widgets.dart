part of 'chat_room_pane.dart';

final class _GiphyThumbnail extends StatefulWidget {
  const _GiphyThumbnail({required this.repository, required this.entry});

  final HttpGiphyRepository repository;
  final GiphyEntry entry;

  @override
  State<_GiphyThumbnail> createState() => _GiphyThumbnailState();
}

final class _GiphyThumbnailState extends State<_GiphyThumbnail> {
  late Future<GiphyThumbnail> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = widget.repository.loadThumbnail(widget.entry);
  }

  @override
  void didUpdateWidget(covariant _GiphyThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository) ||
        oldWidget.entry.thumbnailUrl != widget.entry.thumbnailUrl) {
      _thumbnail = widget.repository.loadThumbnail(widget.entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      key: ValueKey<String>('giphy-thumbnail-${widget.entry.resourceUrl}'),
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: FutureBuilder<GiphyThumbnail>(
          future: _thumbnail,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            final thumbnail = snapshot.data;
            if (snapshot.hasError || thumbnail == null) {
              return Icon(
                Icons.broken_image_outlined,
                color: scheme.onSurfaceVariant,
              );
            }
            return Image.memory(
              thumbnail.body,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              cacheWidth: 480,
              cacheHeight: 480,
              errorBuilder: (_, _, _) => Icon(
                Icons.broken_image_outlined,
                color: scheme.onSurfaceVariant,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Picks the conversation a message is forwarded into.
///
/// Only writable conversations of the same account are offered; the room the
/// message already lives in is filtered out. The cached list is read without a
/// spinner so an account that has not synced yet shows the empty state instead
/// of an indeterminate progress indicator.
final class _ForwardTargetSheet extends ConsumerWidget {
  const _ForwardTargetSheet({
    required this.accountId,
    required this.excludedToken,
  });

  final String accountId;
  final String excludedToken;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final targets =
        (ref.watch(conversationsProvider(accountId)).valueOrNull ??
                const <CachedConversation>[])
            .where(
              (conversation) =>
                  conversation.token != excludedToken &&
                  conversation.readOnly == 0,
            )
            .toList(growable: false);
    return SafeArea(
      child: Column(
        key: const Key('chat-forward-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              strings.forwardMessageTitle,
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (targets.isEmpty)
            Padding(
              key: const Key('chat-forward-empty'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Text(strings.forwardNoConversations),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: targets.length,
                itemBuilder: (context, index) {
                  final target = targets[index];
                  return ListTile(
                    key: Key('chat-forward-conversation-${target.token}'),
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(
                      target.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).pop(target),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// The controller has to outlive the closing transition of the dialog, so the
/// dialog owns it. Disposing it right after `showDialog` returns tears it down
/// while the still-mounted text field depends on it, which trips the framework
/// assertion `_dependents.isEmpty` and takes the whole app down.
final class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initialText});

  final String initialText;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

final class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('edit-message-dialog'),
      title: Text(strings.editMessageTitle),
      content: TextField(
        key: const Key('edit-message-field'),
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
        maxLength: 32000,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('confirm-edit-message'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(strings.editMessageSave),
        ),
      ],
    );
  }
}

final class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.sending,
    required this.readOnly,
    required this.mediaComposer,
    required this.replyTo,
    required this.onCancelReply,
    required this.mentionSource,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool sending;
  final bool readOnly;
  final Widget mediaComposer;
  final CachedChatMessage? replyTo;
  final VoidCallback onCancelReply;
  final MentionSuggestionSource? mentionSource;

  /// Sends whatever is in the composer, same as the send button.
  final VoidCallback onSubmit;

  /// Routes Escape and, where the platform sends on Enter, a bare Enter.
  KeyEventResult _handleKey(
    KeyEvent event, {
    required bool sendsOnEnter,
  }) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    // Escape backs out of the reply, on every platform with a keyboard: the
    // banner's own close button is a mouse target, and nothing else here
    // wants the key. With no reply open it is left alone, so it can still
    // reach whatever does want it.
    if (key == LogicalKeyboardKey.escape) {
      if (replyTo == null) {
        return KeyEventResult.ignored;
      }
      onCancelReply();
      return KeyEventResult.handled;
    }
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!isEnter || !sendsOnEnter) {
      return KeyEventResult.ignored;
    }
    final value = controller.value;
    final action = composerEnterAction(
      text: value.text,
      caret: value.selection.baseOffset,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      sending: sending,
    );
    switch (action) {
      case ComposerEnterAction.insertNewline:
        return KeyEventResult.ignored;
      case ComposerEnterAction.swallow:
        return KeyEventResult.handled;
      case ComposerEnterAction.send:
        onSubmit();
        return KeyEventResult.handled;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: readOnly
              ? SizedBox(
                  height: 48,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.lock_outline_rounded),
                      const SizedBox(width: 8),
                      Flexible(child: Text(strings.readOnlyConversation)),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (replyTo != null)
                      _ReplyBanner(message: replyTo!, onCancel: onCancelReply),
                    MentionSuggestionsBar(
                      controller: controller,
                      source: mentionSource,
                      enabled: !sending,
                      labels: MentionSuggestionsLabels(
                        noResults: strings.mentionSuggestionsEmpty,
                        error: strings.mentionSuggestionsError,
                      ),
                    ),
                    Focus(
                      onKeyEvent: (node, event) => _handleKey(
                        event,
                        sendsOnEnter: context.sendsOnEnter,
                      ),
                      child: TextField(
                      key: const Key('chat-composer'),
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 32000,
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) => null,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        labelText: strings.messageHint,
                        border: const OutlineInputBorder(),
                      ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    mediaComposer,
                  ],
                ),
        ),
      ),
    );
  }
}

final class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({required this.message, required this.onCancel});

  final CachedChatMessage message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('chat-reply-banner'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.replyingTo(message.actorDisplayName),
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: scheme.primary),
                ),
                Text(
                  message.displayText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('chat-cancel-reply'),
            tooltip: strings.cancelReply,
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}
