import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_providers.dart';
import '../../core/giphy_reference.dart';
import '../../data/app_database.dart';
import '../../platform/media/voice_platform_adapters.dart';
import '../../l10n/generated/app_localizations.dart';
import 'composer/giphy.dart';
import 'media/authenticated_image_viewer.dart';

part 'chat_message_attachment_content.dart';
part 'chat_message_giphy_content.dart';
part 'chat_message_rich_content.dart';

final class ChatMessageContent extends StatelessWidget {
  const ChatMessageContent({
    super.key,
    required this.account,
    required this.message,
    required this.fallbackText,
    required this.foregroundColor,
    this.showReplyPreview = true,
    this.onReactionTap,
    this.onOpenParent,
  });

  final StoredAccount account;
  final ChatMessage? message;
  final String fallbackText;
  final Color foregroundColor;
  final bool showReplyPreview;

  /// Toggles the account's own reaction for the tapped emoji. `null` renders
  /// the existing reactions read-only (e.g. for a deleted message).
  final ValueChanged<String>? onReactionTap;

  /// Jumps to the quoted original, identified by its message id. `null`
  /// renders the reply preview as a plain, non-interactive quote.
  final ValueChanged<int>? onOpenParent;

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
          _ReplyPreview(
            account: account,
            message: parsed,
            onOpenParent: onOpenParent,
          ),
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
          _ReactionSummary(message: parsed, onTap: onReactionTap),
        ],
      ],
    );
  }
}
