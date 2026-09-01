part of 'chat_message_content.dart';

const int _maximumReferencesPerMessage = 3;

List<Uri> _messageReferences(ChatMessage message, RichChatDocument document) {
  if (message.deleted ||
      message.messageType != 'comment' ||
      message.systemMessage.isNotEmpty) {
    return const <Uri>[];
  }
  final references = <Uri>[];
  final seen = <Uri>{};
  for (final rawLink in document.activeLinks) {
    final uri = Uri.tryParse(rawLink);
    if (uri == null ||
        !isSafeReferenceUri(uri) ||
        isSupportedGiphyResource(uri) ||
        !seen.add(uri)) {
      continue;
    }
    references.add(uri);
    if (references.length == _maximumReferencesPerMessage) {
      break;
    }
  }
  return List<Uri>.unmodifiable(references);
}

final class _ChatMessageReferenceContent extends StatelessWidget {
  const _ChatMessageReferenceContent({
    required this.target,
    required this.index,
    required this.foregroundColor,
  });

  final ReferenceResolutionTarget target;
  final int index;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    try {
      ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return const SizedBox.shrink();
    }
    return _ReferenceCardConsumer(
      target: target,
      index: index,
      foregroundColor: foregroundColor,
    );
  }
}

final class _ReferenceCardConsumer extends ConsumerWidget {
  const _ReferenceCardConsumer({
    required this.target,
    required this.index,
    required this.foregroundColor,
  });

  final ReferenceResolutionTarget target;
  final int index;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(referenceCardProvider(target))
        .when(
          data: (card) {
            if (card == null || card.reference != target.reference) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _ReferenceCard(
                key: Key('chat-reference-card-$index'),
                card: card,
                target: target,
                foregroundColor: foregroundColor,
                launcher: ref.read(referenceUriLauncherProvider),
              ),
            );
          },
          error: (error, stackTrace) => const SizedBox.shrink(),
          loading: () => const SizedBox.shrink(),
        );
  }
}

final class _ReferenceCard extends StatelessWidget {
  const _ReferenceCard({
    super.key,
    required this.card,
    required this.target,
    required this.foregroundColor,
    required this.launcher,
  });

  final ReferenceCardData card;
  final ReferenceResolutionTarget target;
  final Color foregroundColor;
  final ReferenceUriLauncher launcher;

  @override
  Widget build(BuildContext context) {
    final title = card.title.isEmpty ? target.reference.host : card.title;
    final description = card.description;

    void openReference() {
      unawaited(launcher(target.reference));
    }

    return Semantics(
      container: true,
      link: true,
      button: true,
      label: '$title, ${target.reference.host}',
      onTap: openReference,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: openReference,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: foregroundColor.withValues(alpha: 0.06),
              border: Border.all(
                color: foregroundColor.withValues(alpha: 0.35),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.link, size: 20, color: foregroundColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foregroundColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (description != null && description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: foregroundColor),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Text(
                        target.reference.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: foregroundColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.open_in_new, size: 18, color: foregroundColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
