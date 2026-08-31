import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/app_database.dart';
import '../../data/chat_repository.dart';
import '../chat/chat_room_pane.dart';
import '../chat/chat_service.dart';
import '../conversations/conversation_presence.dart';

enum MessageSearchThreadError {
  unavailable,
  credential,
  rateLimited,
  serviceUnavailable,
  network,
}

final class MessageSearchThreadException implements Exception {
  const MessageSearchThreadException(this.code);

  final MessageSearchThreadError code;

  @override
  String toString() => 'MessageSearchThreadException(${code.name})';
}

final class MessageDestinationTarget {
  const MessageDestinationTarget({
    required this.roomToken,
    required this.messageId,
    required this.threadId,
  });

  factory MessageDestinationTarget.fromSearchResult(
    MessageSearchResult result,
  ) => MessageDestinationTarget(
    roomToken: result.roomToken,
    messageId: result.messageId,
    threadId: result.threadId,
  );

  factory MessageDestinationTarget.fromChatMessage(ChatMessage message) =>
      MessageDestinationTarget(
        roomToken: message.roomToken,
        messageId: message.messageId,
        threadId: message.threadId,
      );

  final ConversationToken roomToken;
  final int messageId;
  final int? threadId;
}

/// Resolves the canonical root needed to open a message inside a thread.
///
/// Search and shared-items responses supply the root ID but not the root
/// message shape needed to distinguish an ordinary reply chain from a named
/// thread. Chat synchronization owns materializing an absent root.
Future<ChatThreadContext> resolveMessageThread({
  required ChatRepository repository,
  required String accountId,
  required MessageDestinationTarget target,
  required Future<void> Function() synchronizeThread,
}) async {
  final threadId = target.threadId;
  if (threadId == null || threadId == target.messageId) {
    throw const MessageSearchThreadException(
      MessageSearchThreadError.unavailable,
    );
  }

  var root = await repository.getMessage(
    accountId: accountId,
    roomToken: target.roomToken.value,
    messageId: threadId,
  );
  if (root == null) {
    try {
      await synchronizeThread();
    } on ChatServiceException catch (error) {
      throw MessageSearchThreadException(_threadError(error.code));
    }
    root = await repository.getMessage(
      accountId: accountId,
      roomToken: target.roomToken.value,
      messageId: threadId,
    );
  }

  if (root == null) {
    throw const MessageSearchThreadException(
      MessageSearchThreadError.unavailable,
    );
  }
  final context = ChatThreadContext.fromCachedRoot(
    accountId: accountId,
    roomToken: target.roomToken.value,
    root: root,
  );
  if (context == null) {
    throw const MessageSearchThreadException(
      MessageSearchThreadError.unavailable,
    );
  }

  final cachedTarget = await repository.getMessage(
    accountId: accountId,
    roomToken: target.roomToken.value,
    messageId: target.messageId,
  );
  if (cachedTarget != null && !_matchesThread(cachedTarget, target)) {
    throw const MessageSearchThreadException(
      MessageSearchThreadError.unavailable,
    );
  }
  return context;
}

MessageSearchThreadError _threadError(ChatServiceError error) =>
    switch (error) {
      ChatServiceError.credentialMissing ||
      ChatServiceError.reauthenticationRequired =>
        MessageSearchThreadError.credential,
      ChatServiceError.rateLimited => MessageSearchThreadError.rateLimited,
      ChatServiceError.serviceUnavailable =>
        MessageSearchThreadError.serviceUnavailable,
      ChatServiceError.network => MessageSearchThreadError.network,
      ChatServiceError.accountMissing ||
      ChatServiceError.conversationMissing ||
      ChatServiceError.talkUnavailable ||
      ChatServiceError.chatUnsupported ||
      ChatServiceError.sendUnsupported ||
      ChatServiceError.readOnly ||
      ChatServiceError.invalidResponse => MessageSearchThreadError.unavailable,
    };

bool _matchesThread(CachedChatMessage cached, MessageDestinationTarget target) {
  if (cached.deleted || cached.threadId != target.threadId) {
    return false;
  }
  try {
    final message = ChatMessage.fromJson(jsonDecode(cached.rawJson));
    return message.messageId == target.messageId &&
        message.roomToken == target.roomToken &&
        message.threadId == target.threadId &&
        !message.deleted;
  } on FormatException {
    return false;
  } on TalkProtocolException {
    return false;
  }
}

Widget buildMessageDestination({
  required StoredAccount account,
  required CachedConversation conversation,
  required MessageDestinationTarget target,
  required ChatThreadContext? threadContext,
}) {
  final threadId = target.threadId;
  if (threadId == null || threadId == target.messageId) {
    return PresenceChatRoomScreen(
      account: account,
      conversation: conversation,
      jumpToMessageId: target.messageId,
    );
  }
  if (threadContext == null ||
      !threadContext.matches(
        accountId: account.id,
        roomToken: conversation.token,
        rootMessageId: threadId,
      )) {
    throw const MessageSearchThreadException(
      MessageSearchThreadError.unavailable,
    );
  }
  return MessageSearchThreadScreen(
    account: account,
    conversation: conversation,
    threadContext: threadContext,
    jumpToMessageId: target.messageId,
  );
}

final class MessageSearchThreadScreen extends StatelessWidget {
  const MessageSearchThreadScreen({
    super.key,
    required this.account,
    required this.conversation,
    required this.threadContext,
    required this.jumpToMessageId,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final ChatThreadContext threadContext;
  final int jumpToMessageId;

  @override
  Widget build(BuildContext context) {
    final threadId = threadContext.rootMessageId;
    return KeyedSubtree(
      key: Key('message-search-thread-screen-$threadId'),
      child: ChatThreadScreen(
        account: account,
        conversation: conversation,
        threadContext: threadContext,
        jumpToMessageId: jumpToMessageId,
      ),
    );
  }
}
