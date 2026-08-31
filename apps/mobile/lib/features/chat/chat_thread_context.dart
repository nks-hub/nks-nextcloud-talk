import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/app_database.dart';
import 'composer/chat_media_composer.dart';

enum ChatThreadKind { ordinary, named }

final class ChatThreadContext {
  ChatThreadContext._({
    required this.accountId,
    required this.roomToken,
    required this.rootMessageId,
    required this.kind,
    required this.title,
  });

  static ChatThreadContext? fromCachedRoot({
    required String accountId,
    required String roomToken,
    required CachedChatMessage root,
  }) {
    if (root.deleted ||
        root.accountId != accountId ||
        root.roomToken != roomToken ||
        root.messageId < 1 ||
        (root.threadId != null &&
            root.threadId != 0 &&
            root.threadId != root.messageId)) {
      return null;
    }
    try {
      final message = ChatMessage.fromJson(jsonDecode(root.rawJson));
      if (message.messageId != root.messageId ||
          message.roomToken.value != roomToken ||
          (message.threadId != null &&
              message.threadId != 0 &&
              message.threadId != message.messageId)) {
        return null;
      }
      if (message.isThread == true) {
        final title = message.threadTitle?.trim();
        if (message.threadId != message.messageId ||
            title == null ||
            title.isEmpty) {
          return null;
        }
        return ChatThreadContext._(
          accountId: accountId,
          roomToken: roomToken,
          rootMessageId: message.messageId,
          kind: ChatThreadKind.named,
          title: title,
        );
      }
      return ChatThreadContext._(
        accountId: accountId,
        roomToken: roomToken,
        rootMessageId: message.messageId,
        kind: ChatThreadKind.ordinary,
        title: null,
      );
    } on FormatException {
      return null;
    } on TalkProtocolException {
      return null;
    }
  }

  final String accountId;
  final String roomToken;
  final int rootMessageId;
  final ChatThreadKind kind;
  final String? title;

  bool get isNamed => kind == ChatThreadKind.named;
  int? get replyTo => isNamed ? null : rootMessageId;
  int? get networkThreadId => isNamed ? rootMessageId : null;

  ChatMediaThreadBinding mediaBinding({
    required AccountId accountId,
    required ConversationToken roomToken,
  }) {
    if (accountId.value != this.accountId ||
        roomToken.value != this.roomToken) {
      throw StateError('Chat thread media binding scope changed');
    }
    return isNamed
        ? ChatMediaThreadBinding.named(
            accountId: accountId,
            roomToken: roomToken,
            rootMessageId: rootMessageId,
          )
        : ChatMediaThreadBinding.ordinary(
            accountId: accountId,
            roomToken: roomToken,
            rootMessageId: rootMessageId,
          );
  }

  bool matches({
    required String accountId,
    required String roomToken,
    required int? rootMessageId,
  }) =>
      this.accountId == accountId &&
      this.roomToken == roomToken &&
      this.rootMessageId == rootMessageId;

  @override
  bool operator ==(Object other) =>
      other is ChatThreadContext &&
      other.accountId == accountId &&
      other.roomToken == roomToken &&
      other.rootMessageId == rootMessageId &&
      other.kind == kind &&
      other.title == title;

  @override
  int get hashCode =>
      Object.hash(accountId, roomToken, rootMessageId, kind, title);
}
