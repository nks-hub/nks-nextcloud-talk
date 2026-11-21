part of 'chat_message_content.dart';

const int _reactionPreviewLimit = 12;

final class _ReactionSummary extends StatelessWidget {
  const _ReactionSummary({required this.message, this.onTap});

  final ChatMessage message;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final reactions = message.reactions.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    final selected = message.reactionsSelf.toSet();
    final previewCount = reactions.length < _reactionPreviewLimit
        ? reactions.length
        : _reactionPreviewLimit;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var index = 0; index < previewCount; index++)
          _ReactionChip(
            messageId: message.messageId,
            index: index,
            emoji: reactions[index].key,
            count: reactions[index].value,
            selected: selected.contains(reactions[index].key),
            onTap: onTap,
          ),
        if (reactions.length > previewCount)
          Tooltip(
            message: MaterialLocalizations.of(context).moreButtonTooltip,
            child: ActionChip(
              key: Key('chat-reaction-more-${message.messageId}'),
              label: Text('+${reactions.length - previewCount}'),
              onPressed: () => _showAll(context, reactions, selected),
            ),
          ),
      ],
    );
  }

  void _showAll(
    BuildContext context,
    List<MapEntry<String, int>> reactions,
    Set<String> selected,
  ) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => _ReactionListDialog(
          messageId: message.messageId,
          reactions: reactions,
          selected: selected,
          onTap: onTap,
        ),
      ),
    );
  }
}

final class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.messageId,
    required this.index,
    required this.emoji,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final int messageId;
  final int index;
  final String emoji;
  final int count;
  final bool selected;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: emoji,
              style: const TextStyle(fontSize: 18, height: 1.2),
            ),
            TextSpan(text: ' $count'),
          ],
        ),
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: foreground),
      ),
    );
    return Semantics(
      label: '$emoji, $count',
      selected: selected,
      button: onTap != null,
      child: Material(
        key: Key('chat-reaction-$messageId-$index'),
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? label
            : InkWell(onTap: () => onTap!(emoji), child: label),
      ),
    );
  }
}

final class _ReactionListDialog extends StatelessWidget {
  const _ReactionListDialog({
    required this.messageId,
    required this.reactions,
    required this.selected,
    required this.onTap,
  });

  final int messageId;
  final List<MapEntry<String, int>> reactions;
  final Set<String> selected;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final material = MaterialLocalizations.of(context);
    return Dialog(
      key: Key('chat-reaction-dialog-$messageId'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      material.moreButtonTooltip,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: material.closeButtonLabel,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  key: Key('chat-reaction-list-$messageId'),
                  itemCount: reactions.length,
                  itemBuilder: (context, index) {
                    final reaction = reactions[index];
                    final ownReaction = selected.contains(reaction.key);
                    final VoidCallback? activate = onTap == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            onTap!(reaction.key);
                          };
                    return Semantics(
                      label: '${reaction.key}, ${reaction.value}',
                      selected: ownReaction,
                      button: onTap != null,
                      onTap: activate,
                      child: ExcludeSemantics(
                        child: ListTile(
                          key: Key('chat-reaction-dialog-$messageId-$index'),
                          title: Text('${reaction.key}  ${reaction.value}'),
                          trailing: ownReaction
                              ? const Icon(Icons.check)
                              : null,
                          onTap: activate,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
