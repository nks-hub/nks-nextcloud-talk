import '../identifiers.dart';
import 'models.dart';

final class ChatConfirmationScope {
  const ChatConfirmationScope({
    required this.messageId,
    required this.parentMessageId,
    required this.parentRoomToken,
    required this.parentThreadId,
    required this.parentDeleted,
    required this.replyToMessageId,
    required this.replyToRoomToken,
    required this.threadId,
  });

  factory ChatConfirmationScope.fromMessage(ChatMessage message) {
    final parent = message.parent;
    final rawReplyTo = parent is ChatFullParent
        ? parent.metadata['replyToMessageId']
        : null;
    final rawReplyToken = parent is ChatFullParent
        ? parent.metadata['replyToConversationToken']
        : null;
    return ChatConfirmationScope(
      messageId: message.messageId,
      parentMessageId: parent is ChatFullParent
          ? parent.messageId
          : parent is ChatDeletedParent
          ? parent.messageId
          : null,
      parentRoomToken: parent is ChatFullParent ? parent.roomToken : null,
      parentThreadId: parent is ChatFullParent ? parent.message.threadId : null,
      parentDeleted: parent is ChatDeletedParent,
      replyToMessageId: rawReplyTo is int ? rawReplyTo : null,
      replyToRoomToken: rawReplyToken is String ? rawReplyToken : null,
      threadId: message.threadId,
    );
  }

  final int messageId;
  final int? parentMessageId;
  final ConversationToken? parentRoomToken;
  final int? parentThreadId;
  final bool parentDeleted;
  final int? replyToMessageId;
  final String? replyToRoomToken;
  final int? threadId;
}

bool matchesAuthoritativeChatConfirmationScope({
  required ChatConfirmationScope confirmation,
  required ConversationToken roomToken,
  required int? replyTo,
  required ConversationToken? replyToToken,
  required ConversationToken? parentRoomToken,
  required int? threadId,
}) {
  if (threadId != null) {
    if (confirmation.threadId != threadId ||
        confirmation.parentMessageId == null) {
      return false;
    }
    if (confirmation.parentDeleted) {
      return confirmation.parentMessageId == threadId &&
          confirmation.parentRoomToken == null &&
          confirmation.parentThreadId == null;
    }
    return confirmation.parentMessageId == threadId &&
        confirmation.parentRoomToken == roomToken &&
        confirmation.parentThreadId == threadId;
  }
  if (replyTo == null) {
    return confirmation.threadId == confirmation.messageId &&
        confirmation.parentMessageId == null &&
        confirmation.parentRoomToken == null;
  }
  if (replyToToken == null) {
    if (confirmation.parentDeleted) {
      return confirmation.parentMessageId == replyTo &&
          confirmation.parentRoomToken == null &&
          confirmation.parentThreadId == null &&
          confirmation.threadId != null &&
          confirmation.threadId! > 0;
    }
    return confirmation.parentMessageId == replyTo &&
        confirmation.parentRoomToken == parentRoomToken &&
        confirmation.parentThreadId != null &&
        confirmation.parentThreadId! > 0 &&
        confirmation.threadId == confirmation.parentThreadId;
  }
  return confirmation.replyToMessageId == replyTo &&
      confirmation.replyToRoomToken == replyToToken.value &&
      confirmation.parentRoomToken == parentRoomToken &&
      confirmation.parentThreadId == 0 &&
      confirmation.threadId == confirmation.parentMessageId;
}
