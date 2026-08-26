import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import 'app_database.dart';

final class AttachmentThreadBinding {
  const AttachmentThreadBinding._({
    required this.rootMessageId,
    required this.isNamed,
    required this.title,
  });

  factory AttachmentThreadBinding.fromCachedRoot({
    required CachedChatMessage? root,
    required String accountId,
    required String roomToken,
    required int rootMessageId,
  }) {
    if (root == null ||
        root.deleted ||
        root.accountId != accountId ||
        root.roomToken != roomToken ||
        root.messageId != rootMessageId ||
        !_isRootThreadId(root.threadId, rootMessageId)) {
      throw StateError('Attachment thread binding is invalid');
    }

    final ChatMessage message;
    try {
      message = ChatMessage.fromJson(jsonDecode(root.rawJson));
    } on FormatException {
      throw StateError('Attachment thread binding is invalid');
    } on TalkProtocolException {
      throw StateError('Attachment thread binding is invalid');
    }
    if (message.deleted ||
        message.messageId != rootMessageId ||
        message.roomToken.value != roomToken ||
        !_isRootThreadId(message.threadId, rootMessageId)) {
      throw StateError('Attachment thread binding is invalid');
    }

    if (message.isThread == true) {
      final title = message.threadTitle?.trim();
      if (root.threadId != rootMessageId ||
          message.threadId != rootMessageId ||
          title == null ||
          title.isEmpty ||
          title.length > 200) {
        throw StateError('Attachment thread binding is invalid');
      }
      return AttachmentThreadBinding._(
        rootMessageId: rootMessageId,
        isNamed: true,
        title: title,
      );
    }
    return AttachmentThreadBinding._(
      rootMessageId: rootMessageId,
      isNamed: false,
      title: null,
    );
  }

  final int rootMessageId;
  final bool isNamed;
  final String? title;

  AttachmentMetadata applyTo(AttachmentMetadata metadata) => AttachmentMetadata(
    kind: metadata.kind,
    caption: metadata.caption,
    replyTo: isNamed ? null : rootMessageId,
    threadId: isNamed ? rootMessageId : null,
    threadTitle: isNamed ? title : null,
    silent: metadata.silent,
  );

  bool matches(AttachmentMetadata metadata) =>
      metadata.replyTo == (isNamed ? null : rootMessageId) &&
      metadata.threadId == (isNamed ? rootMessageId : null) &&
      metadata.threadTitle == (isNamed ? title : null);
}

bool _isRootThreadId(int? threadId, int rootMessageId) =>
    threadId == null || threadId == 0 || threadId == rootMessageId;
