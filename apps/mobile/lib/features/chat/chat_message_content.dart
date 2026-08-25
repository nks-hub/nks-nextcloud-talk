import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_providers.dart';
import '../../core/giphy_reference.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import 'composer/giphy.dart';
import 'media/authenticated_image_viewer.dart';

const _maximumGiphyReferencesPerMessage = 4;

final class ChatMessageContent extends StatelessWidget {
  const ChatMessageContent({
    super.key,
    required this.account,
    required this.message,
    required this.fallbackText,
    required this.foregroundColor,
    this.showReplyPreview = true,
  });

  final StoredAccount account;
  final ChatMessage? message;
  final String fallbackText;
  final Color foregroundColor;
  final bool showReplyPreview;

  @override
  Widget build(BuildContext context) {
    final parsed = message;
    if (parsed == null) {
      return Text(fallbackText, style: TextStyle(color: foregroundColor));
    }
    final exactGiphyReference = exactGiphyResource(parsed.message);
    final document = renderRichChatMessage(
      message: parsed.message,
      markdownEnabled: parsed.markdown == true || exactGiphyReference != null,
      parameters: parsed.messageParameters,
      server: ServerBase.parse(account.serverUrl),
    );
    final attachments = parsed.messageParameters.entries
        .where((entry) => entry.value.type == 'file')
        .toList(growable: false);
    final giphySelection = _giphyReferences(document);
    return Column(
      key: Key('chat-rich-content-${parsed.messageId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showReplyPreview && parsed.parent != null) ...[
          _ReplyPreview(account: account, message: parsed),
          const SizedBox(height: 8),
        ],
        if (giphySelection.references.isEmpty)
          _RichDocument(document: document, foregroundColor: foregroundColor)
        else
          _GiphyRichDocument(
            accountId: account.id,
            document: document,
            foregroundColor: foregroundColor,
            references: giphySelection.references,
            hasOverflow: giphySelection.hasOverflow,
          ),
        for (var index = 0; index < attachments.length; index++) ...[
          const SizedBox(height: 8),
          _ChatAttachment(
            key: Key('chat-attachment-${parsed.messageId}-$index'),
            account: account,
            parameter: attachments[index].value,
            messageId: parsed.messageId,
            index: index,
          ),
        ],
        if (parsed.reactions.isNotEmpty) ...[
          const SizedBox(height: 8),
          _ReactionSummary(message: parsed),
        ],
      ],
    );
  }
}

final class ChatPendingGiphyReference extends ConsumerWidget {
  const ChatPendingGiphyReference({
    super.key,
    required this.account,
    required this.resourceUrl,
    required this.foregroundColor,
  });

  final StoredAccount account;
  final Uri resourceUrl;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isSupportedGiphyResource(resourceUrl)) {
      return _GiphyReferenceFailure(index: 0, foregroundColor: foregroundColor);
    }
    final request = GiphyReferenceRequest(
      accountId: account.id,
      resourceUrl: resourceUrl,
    );
    final provider = giphyReferenceMediaProvider(request);
    final media = ref.watch(provider);
    return media.when(
      data: (value) => value.resourceUrl == resourceUrl
          ? _GiphyReferenceImage(
              media: value,
              foregroundColor: foregroundColor,
              index: 0,
            )
          : _GiphyReferenceFailure(
              index: 0,
              foregroundColor: foregroundColor,
              onRetry: () => _retryGiphyReference(ref, account.id, resourceUrl),
            ),
      error: (_, _) => _GiphyReferenceFailure(
        index: 0,
        foregroundColor: foregroundColor,
        onRetry: () => _retryGiphyReference(ref, account.id, resourceUrl),
      ),
      loading: () => const _GiphyReferenceLoading(index: 0),
    );
  }
}

final class _GiphyRichDocument extends ConsumerWidget {
  const _GiphyRichDocument({
    required this.accountId,
    required this.document,
    required this.foregroundColor,
    required this.references,
    required this.hasOverflow,
  });

  final String accountId;
  final RichChatDocument document;
  final Color foregroundColor;
  final List<Uri> references;
  final bool hasOverflow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolutions = <AsyncValue<GiphyReferenceMedia>>[
      for (final resourceUrl in references)
        ref.watch(
          giphyReferenceMediaProvider(
            GiphyReferenceRequest(
              accountId: accountId,
              resourceUrl: resourceUrl,
            ),
          ),
        ),
    ];
    final hiddenLinks = references.toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RichDocument(
          document: document,
          foregroundColor: foregroundColor,
          hiddenLinks: hiddenLinks,
        ),
        for (var index = 0; index < references.length; index++)
          resolutions[index].when(
            data: (media) => media.resourceUrl == references[index]
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _GiphyReferenceImage(
                      media: media,
                      foregroundColor: foregroundColor,
                      index: index,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _GiphyReferenceFailure(
                      index: index,
                      foregroundColor: foregroundColor,
                      onRetry: () => _retryGiphyReference(
                        ref,
                        accountId,
                        references[index],
                      ),
                    ),
                  ),
            error: (_, _) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _GiphyReferenceFailure(
                index: index,
                foregroundColor: foregroundColor,
                onRetry: () =>
                    _retryGiphyReference(ref, accountId, references[index]),
              ),
            ),
            loading: () => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _GiphyReferenceLoading(index: index),
            ),
          ),
        if (hasOverflow)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _GiphyReferenceFailure(
              index: _maximumGiphyReferencesPerMessage,
              foregroundColor: foregroundColor,
            ),
          ),
      ],
    );
  }
}

void _retryGiphyReference(WidgetRef ref, String accountId, Uri resourceUrl) {
  ref.invalidate(giphyRepositoryProvider(accountId));
  ref.invalidate(
    giphyReferenceMediaProvider(
      GiphyReferenceRequest(accountId: accountId, resourceUrl: resourceUrl),
    ),
  );
}

final class _GiphyReferenceLoading extends StatelessWidget {
  const _GiphyReferenceLoading({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: Key('chat-giphy-reference-loading-$index'),
      width: 48,
      height: 48,
      child: const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

final class _GiphyReferenceImage extends StatelessWidget {
  const _GiphyReferenceImage({
    required this.media,
    required this.foregroundColor,
    required this.index,
  });

  final GiphyReferenceMedia media;
  final Color foregroundColor;
  final int index;

  @override
  Widget build(BuildContext context) {
    final rawAspectRatio = media.aspectRatio;
    final aspectRatio = rawAspectRatio == null || !rawAspectRatio.isFinite
        ? 4 / 3
        : rawAspectRatio.clamp(0.1, 10.0).toDouble();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360, maxHeight: 360),
      child: AspectRatio(
        key: Key('chat-giphy-reference-media-$index'),
        aspectRatio: aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            media.body,
            fit: BoxFit.contain,
            cacheWidth: 1080,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _GiphyReferenceFailure(
              index: index,
              foregroundColor: foregroundColor,
            ),
          ),
        ),
      ),
    );
  }
}

final class _GiphyReferenceFailure extends StatelessWidget {
  const _GiphyReferenceFailure({
    required this.index,
    required this.foregroundColor,
    this.onRetry,
  });

  final int index;
  final Color foregroundColor;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Row(
      key: Key('chat-giphy-reference-error-$index'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, size: 18, color: foregroundColor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            strings.imageLoadFailed,
            style: TextStyle(color: foregroundColor),
          ),
        ),
        if (onRetry != null)
          IconButton(
            key: Key('chat-giphy-reference-retry-$index'),
            onPressed: onRetry,
            tooltip: strings.retry,
            color: foregroundColor,
            icon: const Icon(Icons.refresh_rounded),
          ),
      ],
    );
  }
}

({List<Uri> references, bool hasOverflow}) _giphyReferences(
  RichChatDocument document,
) {
  final references = <Uri>[];
  final seen = <Uri>{};
  for (final node in document.nodes) {
    if (node.kind != RichChatSemanticKind.link || node.link == null) {
      continue;
    }
    final resourceUrl = Uri.tryParse(node.link!);
    if (resourceUrl == null ||
        !isSupportedGiphyResource(resourceUrl) ||
        !seen.add(resourceUrl)) {
      continue;
    }
    if (references.length == _maximumGiphyReferencesPerMessage) {
      return (
        references: List<Uri>.unmodifiable(references),
        hasOverflow: true,
      );
    }
    references.add(resourceUrl);
  }
  return (references: List<Uri>.unmodifiable(references), hasOverflow: false);
}

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
  const _ReplyPreview({required this.account, required this.message});

  final StoredAccount account;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final parent = message.parent;
    final String author;
    final String text;
    if (parent is ChatFullParent) {
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
    return Semantics(
      label: author.isEmpty ? text : '${strings.replyingTo(author)}. $text',
      child: ExcludeSemantics(
        child: Container(
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
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ReactionSummary extends StatelessWidget {
  const _ReactionSummary({required this.message});

  final ChatMessage message;

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
              final selected = message.reactionsSelf.contains(
                reactions[index].key,
              );
              final foreground = selected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurface;
              return Semantics(
                label: '${reactions[index].key}, ${reactions[index].value}',
                selected: selected,
                child: Container(
                  key: Key('chat-reaction-${message.messageId}-$index'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
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
                    '${reactions[index].key} ${reactions[index].value}',
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: foreground),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

final class _ChatAttachment extends ConsumerWidget {
  const _ChatAttachment({
    super.key,
    required this.account,
    required this.parameter,
    required this.messageId,
    required this.index,
  });

  final StoredAccount account;
  final ChatRichObjectParameter parameter;
  final int messageId;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = (parameter.name ?? '').trim().isEmpty
        ? strings.attachment
        : parameter.name!.trim();
    final mimeType = _mimeType(parameter);
    final previewUri = _previewUri(account, parameter, mimeType);
    final link = _safeSameOriginLink(account, parameter.link);
    final image = previewUri == null
        ? null
        : ref.watch(chatMediaProvider((account: account, uri: previewUri)));
    final loadedImage = image?.asData?.value;
    final fullScreenPreviewUri = previewUri == null
        ? null
        : _fullScreenPreviewUri(previewUri);
    final VoidCallback? openImage = fullScreenPreviewUri == null
        ? null
        : () => unawaited(
            showAuthenticatedImageViewer(
              context,
              account: account,
              previewUri: fullScreenPreviewUri,
              imageName: name,
              repository: ref.read(chatMediaRepositoryProvider),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (loadedImage != null) ...[
          Semantics(
            key: Key('chat-open-image-$messageId-$index'),
            image: true,
            button: true,
            label: '${strings.openImage}: $name',
            onTap: openImage,
            child: ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: openImage,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                        maxWidth: 420,
                        maxHeight: 320,
                      ),
                      child: Image.memory(
                        loadedImage.body,
                        key: Key('chat-image-$messageId-$index'),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
        ] else if (image?.isLoading ?? false) ...[
          Container(
            key: Key('chat-image-loading-$messageId-$index'),
            width: 240,
            height: 120,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 6),
        ],
        Material(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: Key('chat-open-attachment-$messageId-$index'),
            onTap: link == null
                ? null
                : () => unawaited(
                    launchUrl(link, mode: LaunchMode.externalApplication),
                  ),
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      mimeType?.startsWith('image/') == true
                          ? Icons.image_rounded
                          : Icons.insert_drive_file_rounded,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (link != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.open_in_new_rounded,
                        size: 18,
                        semanticLabel: strings.openAttachment,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

TextStyle? _headingStyle(ThemeData theme, int level) {
  return switch (level) {
    1 => theme.textTheme.headlineSmall,
    2 => theme.textTheme.titleLarge,
    3 => theme.textTheme.titleMedium,
    _ => theme.textTheme.titleSmall,
  }?.copyWith(fontWeight: FontWeight.w700);
}

String? _mimeType(ChatRichObjectParameter parameter) {
  final value = parameter.wire['mimetype'] ?? parameter.wire['mimeType'];
  return value is String ? value.trim().toLowerCase() : null;
}

Uri? _previewUri(
  StoredAccount account,
  ChatRichObjectParameter parameter,
  String? mimeType,
) {
  if (mimeType?.startsWith('image/') != true) {
    return null;
  }
  final available = parameter.wire['preview-available'];
  if (available == false || available == 0 || available == 'no') {
    return null;
  }
  final fileId = int.tryParse(parameter.id ?? '');
  if (fileId == null || fileId < 1) {
    return null;
  }
  final server = ServerBase.parse(account.serverUrl);
  return server.uri.replace(
    pathSegments: [...server.uri.pathSegments, 'index.php', 'core', 'preview'],
    queryParameters: {'fileId': '$fileId', 'x': '1024', 'y': '1024', 'a': '0'},
  );
}

Uri? _safeSameOriginLink(StoredAccount account, String? raw) {
  if (raw == null || raw.isEmpty || raw.contains(r'\')) {
    return null;
  }
  final parsed = Uri.tryParse(raw);
  if (parsed == null || parsed.userInfo.isNotEmpty) {
    return null;
  }
  final server = ServerBase.parse(account.serverUrl);
  final resolved = parsed.hasScheme ? parsed : server.uri.resolveUri(parsed);
  return resolved.scheme == 'https' && server.hasSameOrigin(resolved)
      ? resolved
      : null;
}

Uri _fullScreenPreviewUri(Uri previewUri) {
  return previewUri.replace(
    queryParameters: <String, String>{
      ...previewUri.queryParameters,
      'x': '2048',
      'y': '2048',
    },
  );
}
