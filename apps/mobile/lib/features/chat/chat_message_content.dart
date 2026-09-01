import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_providers.dart';
import '../../core/giphy_reference.dart';
import '../../data/app_database.dart';
import 'references/reference_resolver.dart';
import '../../platform/media/voice_platform_adapters.dart';
import '../../l10n/generated/app_localizations.dart';
import 'emoji_only_message.dart';
import 'poll_dialog.dart';
import 'composer/giphy.dart';
import 'media/authenticated_image_viewer.dart';
import 'media/chat_attachment_opener.dart';
import 'media/chat_attachment_exporter.dart';

part 'chat_message_attachment_content.dart';
part 'chat_message_giphy_content.dart';
part 'chat_message_reference_content.dart';
part 'chat_message_rich_content.dart';
part 'chat_location_preview.dart';

typedef LocationTileClientFactory = http.Client Function(String accountId);

http.Client _createLocationTileClient(String accountId) => http.Client();

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
    this.locationTileClientFactory = _createLocationTileClient,
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
  final LocationTileClientFactory locationTileClientFactory;

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
    final references = _messageReferences(parsed, document);
    return _PollViewerScope(
      account: account,
      message: parsed,
      child: _LocationTileScope(
        accountId: account.id,
        clientFactory: locationTileClientFactory,
        child: Column(
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
              if (attachments.isEmpty &&
                  parsed.messageParameters.isEmpty &&
                  isEmojiOnlyMessage(parsed.message))
                Text(
                  parsed.message.trim(),
                  key: Key('chat-enlarged-emoji-${parsed.messageId}'),
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: enlargedEmojiFontSize,
                    height: 1.15,
                  ),
                )
              else
                RichChatDocumentContent(
                  document: document,
                  foregroundColor: foregroundColor,
                )
            else
              _GiphyRichDocument(
                accountId: account.id,
                document: document,
                foregroundColor: foregroundColor,
                references: giphySelection.references,
                hasOverflow: giphySelection.hasOverflow,
              ),
            for (var index = 0; index < references.length; index++)
              _ChatMessageReferenceContent(
                target: ReferenceResolutionTarget(
                  accountId: account.id,
                  server: ServerBase.parse(account.serverUrl),
                  reference: references[index],
                ),
                index: index,
                foregroundColor: foregroundColor,
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
        ),
      ),
    );
  }
}

final class _PollViewerScope extends InheritedWidget {
  const _PollViewerScope({
    required this.account,
    required this.message,
    required super.child,
  });

  final StoredAccount account;
  final ChatMessage message;

  static _PollViewerScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PollViewerScope>();

  int? validatedPollId(
    ChatRichObjectParameter parameter,
    String? parameterKey,
  ) {
    if (message.deleted ||
        message.messageType != 'comment' ||
        (message.systemMessage.isNotEmpty &&
            message.systemMessage != 'object_shared') ||
        parameterKey == null ||
        message.message.trim() != '{$parameterKey}' ||
        parameter.type != 'talk-poll' ||
        !identical(message.messageParameters[parameterKey], parameter)) {
      return null;
    }
    final rawId = parameter.id;
    if (rawId == null || !RegExp(r'^[1-9]\d{0,18}$').hasMatch(rawId)) {
      return null;
    }
    return int.tryParse(rawId);
  }

  @override
  bool updateShouldNotify(_PollViewerScope oldWidget) =>
      oldWidget.account.id != account.id ||
      oldWidget.message.messageId != message.messageId ||
      oldWidget.message.deleted != message.deleted;
}

Widget _showAfterFirstImageFrame({
  required Widget image,
  required int? frame,
  required bool wasSynchronouslyLoaded,
  required Widget placeholder,
}) {
  return wasSynchronouslyLoaded || frame != null ? image : placeholder;
}
