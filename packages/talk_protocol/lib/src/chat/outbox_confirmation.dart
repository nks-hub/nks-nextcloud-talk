part of 'outbox.dart';

bool _authoritativeConfirmationMatches(
  ChatAccountState account,
  TextSendOutboxOperation operation,
  ChatMessageConfirmation message,
) {
  if (message.accountId != account.accountId ||
      message.server != account.server ||
      message.roomToken != operation.roomToken ||
      message.referenceId != operation.referenceId.value) {
    return false;
  }
  return matchesAuthoritativeChatConfirmationScope(
    confirmation: ChatConfirmationScope(
      messageId: message.messageId,
      parentMessageId: message.parentMessageId,
      parentRoomToken: message.parentRoomToken,
      parentThreadId: message.parentThreadId,
      parentDeleted: message.parentDeleted,
      replyToMessageId: message.replyToMessageId,
      replyToRoomToken: message.replyToRoomToken,
      threadId: message.threadId,
    ),
    roomToken: operation.roomToken,
    replyTo: operation.replyTo,
    replyToToken: operation.replyToToken,
    parentRoomToken: operation.parentRoomToken,
    threadId: operation.replyThreadId ?? operation.threadId,
  );
}

bool _responseMatches(
  ChatAccountState account,
  TextSendOutboxOperation operation,
  ChatSendResponse response,
) {
  final request = response.request;
  return request.accountId == account.accountId &&
      request.server == account.server &&
      request.operationId == operation.operationId &&
      request.roomToken == operation.roomToken &&
      request.referenceId == operation.referenceId &&
      request.replyTo == operation.replyTo &&
      request.threadId ==
          (operation.replyTo == null ? operation.threadId : null) &&
      request.replyThreadId == operation.replyThreadId &&
      request.replyToToken == operation.replyToToken &&
      request.parentRoomToken == operation.parentRoomToken;
}
