part of 'chat_message_content.dart';

final class _RichDocument extends StatelessWidget {
  const _RichDocument({
    required this.document,
    required this.foregroundColor,
    this.hiddenLinks = const <Uri>{},
  });

  final RichChatDocument document;
  final Color foregroundColor;
  final Set<Uri> hiddenLinks;

  @override
  Widget build(BuildContext context) {
    final blocks = document.root.children
        .map((node) => _buildBlock(context, node))
        .toList(growable: false);
    if (blocks.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          if (index > 0) const SizedBox(height: 6),
          blocks[index],
        ],
      ],
    );
  }

  Widget _buildBlock(BuildContext context, RichChatSemanticNode node) {
    final theme = Theme.of(context);
    return switch (node.kind) {
      RichChatSemanticKind.heading => Text.rich(
        TextSpan(
          children: _inlineChildren(
            context,
            node,
            foregroundColor,
            hiddenLinks,
          ),
        ),
        style: _headingStyle(
          theme,
          node.headingLevel ?? 3,
        )?.copyWith(color: foregroundColor),
      ),
      RichChatSemanticKind.codeBlock => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            node.text ?? '',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
      RichChatSemanticKind.unorderedList ||
      RichChatSemanticKind.orderedList ||
      RichChatSemanticKind.taskList => _RichList(
        node: node,
        foregroundColor: foregroundColor,
        hiddenLinks: hiddenLinks,
      ),
      RichChatSemanticKind.quote => Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 3),
          ),
        ),
        child: Text.rich(
          TextSpan(
            children: _inlineChildren(
              context,
              node,
              foregroundColor,
              hiddenLinks,
            ),
          ),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: foregroundColor,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
      RichChatSemanticKind.table => _RichTable(
        node: node,
        foregroundColor: foregroundColor,
        hiddenLinks: hiddenLinks,
      ),
      RichChatSemanticKind.horizontalRule => const Divider(height: 12),
      _ => Text.rich(
        TextSpan(
          children: _inlineChildren(
            context,
            node,
            foregroundColor,
            hiddenLinks,
          ),
        ),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: foregroundColor,
          height: 1.35,
        ),
      ),
    };
  }
}

final class _RichList extends StatelessWidget {
  const _RichList({
    required this.node,
    required this.foregroundColor,
    required this.hiddenLinks,
  });

  final RichChatSemanticNode node;
  final Color foregroundColor;
  final Set<Uri> hiddenLinks;

  @override
  Widget build(BuildContext context) {
    final items = node.children
        .where((child) => child.kind == RichChatSemanticKind.listItem)
        .toList(growable: false);
    final start = node.orderedStart ?? 1;
    return DefaultTextStyle.merge(
      style: TextStyle(color: foregroundColor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < items.length; index++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      node.kind == RichChatSemanticKind.orderedList
                          ? '${start + index}.'
                          : '•',
                      textAlign: TextAlign.end,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: _inlineChildren(
                          context,
                          items[index],
                          foregroundColor,
                          hiddenLinks,
                        ),
                      ),
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

final class _RichTable extends StatelessWidget {
  const _RichTable({
    required this.node,
    required this.foregroundColor,
    required this.hiddenLinks,
  });

  final RichChatSemanticNode node;
  final Color foregroundColor;
  final Set<Uri> hiddenLinks;

  @override
  Widget build(BuildContext context) {
    final rows = node.depthFirst
        .where((child) => child.kind == RichChatSemanticKind.tableRow)
        .toList(growable: false);
    if (rows.isEmpty) {
      return Text(node.flattenedText, style: TextStyle(color: foregroundColor));
    }
    final width = rows
        .map(
          (row) => row.children
              .where((cell) => cell.kind == RichChatSemanticKind.tableCell)
              .length,
        )
        .fold<int>(0, (maximum, value) => value > maximum ? value : maximum);
    return DefaultTextStyle.merge(
      style: TextStyle(color: foregroundColor),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: width * 112),
          child: Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            children: [
              for (final row in rows)
                TableRow(
                  children: [
                    for (var index = 0; index < width; index++)
                      if (index <
                          row.children
                              .where(
                                (child) =>
                                    child.kind ==
                                    RichChatSemanticKind.tableCell,
                              )
                              .length)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text.rich(
                            TextSpan(
                              children: _inlineChildren(
                                context,
                                row.children
                                    .where(
                                      (child) =>
                                          child.kind ==
                                          RichChatSemanticKind.tableCell,
                                    )
                                    .elementAt(index),
                                foregroundColor,
                                hiddenLinks,
                              ),
                            ),
                          ),
                        )
                      else
                        const SizedBox.shrink(),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

List<InlineSpan> _inlineChildren(
  BuildContext context,
  RichChatSemanticNode node,
  Color foregroundColor,
  Set<Uri> hiddenLinks,
) {
  if (node.children.isEmpty) {
    return [_inlineSpan(context, node, foregroundColor, hiddenLinks)];
  }
  return node.children
      .map((child) => _inlineSpan(context, child, foregroundColor, hiddenLinks))
      .toList();
}

InlineSpan _inlineSpan(
  BuildContext context,
  RichChatSemanticNode node,
  Color foregroundColor,
  Set<Uri> hiddenLinks,
) {
  if (node.kind == RichChatSemanticKind.link && node.link != null) {
    final resourceUrl = Uri.tryParse(node.link!);
    if (resourceUrl != null &&
        (hiddenLinks.contains(resourceUrl) ||
            isSupportedGiphyResource(resourceUrl))) {
      return const TextSpan();
    }
  }
  final theme = Theme.of(context);
  final children = node.children
      .map((child) => _inlineSpan(context, child, foregroundColor, hiddenLinks))
      .toList(growable: false);
  return switch (node.kind) {
    RichChatSemanticKind.text => TextSpan(text: node.text ?? ''),
    RichChatSemanticKind.softBreak => const TextSpan(text: '\n'),
    RichChatSemanticKind.strong => TextSpan(
      children: children,
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    RichChatSemanticKind.emphasis => TextSpan(
      children: children,
      style: const TextStyle(fontStyle: FontStyle.italic),
    ),
    RichChatSemanticKind.strikethrough => TextSpan(
      children: children,
      style: const TextStyle(decoration: TextDecoration.lineThrough),
    ),
    RichChatSemanticKind.inlineCode => TextSpan(
      text: node.text ?? '',
      style: TextStyle(
        fontFamily: 'monospace',
        color: theme.colorScheme.onSurface,
        backgroundColor: theme.colorScheme.surfaceContainerLowest,
      ),
    ),
    RichChatSemanticKind.link => WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: _InlineLink(
        uri: Uri.parse(node.link!),
        label: node.flattenedText,
        color: foregroundColor,
      ),
    ),
    RichChatSemanticKind.richObject => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _RichObjectPill(node: node),
    ),
    RichChatSemanticKind.taskCheckbox => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(
          node.checked == true
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded,
          size: 18,
        ),
      ),
    ),
    RichChatSemanticKind.codeBlock => TextSpan(
      text: node.text ?? '',
      style: const TextStyle(fontFamily: 'monospace'),
    ),
    _ => TextSpan(children: children),
  };
}

final class _InlineLink extends StatelessWidget {
  const _InlineLink({
    required this.uri,
    required this.label,
    required this.color,
  });

  final Uri uri;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    void openLink() {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
    }

    return Semantics(
      container: true,
      link: true,
      label: label,
      onTap: openLink,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: openLink,
          borderRadius: BorderRadius.circular(4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  decoration: TextDecoration.underline,
                  decorationColor: color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _RichObjectPill extends StatelessWidget {
  const _RichObjectPill({required this.node});

  final RichChatSemanticNode node;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parameter = node.parameter!;
    final label = parameter.name ?? parameter.id ?? node.parameterKey ?? '';
    final icon = switch (node.objectKind) {
      RichChatObjectKind.user ||
      RichChatObjectKind.guest ||
      RichChatObjectKind.federatedUser => Icons.alternate_email_rounded,
      RichChatObjectKind.userGroup ||
      RichChatObjectKind.circle => Icons.groups_rounded,
      RichChatObjectKind.call => Icons.call_rounded,
      RichChatObjectKind.email => Icons.mail_outline_rounded,
      RichChatObjectKind.generic || null => Icons.attachment_rounded,
    };
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: scheme.onSecondaryContainer)),
        ],
      ),
    );
  }
}

final class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({
    required this.account,
    required this.message,
    required this.onOpenParent,
  });

  final StoredAccount account;
  final ChatMessage message;
  final ValueChanged<int>? onOpenParent;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final parent = message.parent;
    final String author;
    final String text;
    int? parentId;
    if (parent is ChatFullParent && !parent.message.deleted) {
      parentId = parent.message.messageId;
      author = parent.message.actorDisplayName;
      final rendered = renderRichChatMessage(
        message: parent.message.message,
        markdownEnabled: parent.message.markdown ?? false,
        parameters: parent.message.messageParameters,
        server: ServerBase.parse(account.serverUrl),
      ).root.flattenedText.trim();
      text = normalizeGiphyReferencePreview(rendered);
    } else {
      author = '';
      text = strings.deletedMessage;
    }
    final targetId = parentId;
    final jump = targetId == null ? null : onOpenParent;
    return Semantics(
      label: author.isEmpty ? text : '${strings.replyingTo(author)}. $text',
      button: jump != null,
      hint: jump == null ? null : strings.jumpToOriginalMessage,
      onTap: jump == null ? null : () => jump(targetId!),
      child: ExcludeSemantics(
        child: _tappable(
          jump == null ? null : () => jump(targetId!),
          message.messageId,
          Container(
            key: Key('chat-reply-preview-${message.messageId}'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(9, 6, 8, 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(7),
              border: Border(left: BorderSide(color: scheme.primary, width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (author.isNotEmpty)
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Wraps the quote in a tap target only when there is somewhere to jump.
  /// A quote whose original was deleted stays inert instead of offering a
  /// jump that would always fail.
  Widget _tappable(VoidCallback? onTap, int messageId, Widget child) {
    if (onTap == null) {
      return child;
    }
    return GestureDetector(
      key: Key('chat-reply-jump-$messageId'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: child,
    );
  }
}

final class _ReactionSummary extends StatelessWidget {
  const _ReactionSummary({required this.message, this.onTap});

  final ChatMessage message;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final reactions = message.reactions.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var index = 0; index < reactions.length; index++)
          Builder(
            builder: (context) {
              final emoji = reactions[index].key;
              final selected = message.reactionsSelf.contains(emoji);
              final foreground = selected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurface;
              final pill = Container(
                key: Key('chat-reaction-${message.messageId}-$index'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
                child: Text(
                  '$emoji ${reactions[index].value}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: foreground),
                ),
              );
              return Semantics(
                label: '$emoji, ${reactions[index].value}',
                selected: selected,
                button: onTap != null,
                child: onTap == null
                    ? pill
                    : InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => onTap!(emoji),
                        child: pill,
                      ),
              );
            },
          ),
      ],
    );
  }
}

/// Plays a voice message straight from the bubble. The file is fetched over
/// the account's authenticated origin, never through a public link.

TextStyle? _headingStyle(ThemeData theme, int level) {
  return switch (level) {
    1 => theme.textTheme.headlineSmall,
    2 => theme.textTheme.titleLarge,
    3 => theme.textTheme.titleMedium,
    _ => theme.textTheme.titleSmall,
  }?.copyWith(fontWeight: FontWeight.w700);
}

/// A Talk attachment carries a WebDAV path. The `link` field points at the
