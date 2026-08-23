import 'dart:collection';

import '../chat/models.dart';
import '../chat/state.dart';
import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';

final class RichChatRoomState {
  RichChatRoomState({
    required this.roomToken,
    required Map<int, ChatMessage> messages,
    required Map<int, RichChatThread> threads,
    required Map<int, RichChatReminder> reminders,
    required Map<RichChatScheduleId, RichChatScheduledMessage>
    scheduledMessages,
    required this.lastMessageId,
  }) : messages = UnmodifiableMapView(Map.of(messages)),
       threads = UnmodifiableMapView(Map.of(threads)),
       reminders = UnmodifiableMapView(Map.of(reminders)),
       scheduledMessages = UnmodifiableMapView(Map.of(scheduledMessages)) {
    _validate();
  }

  factory RichChatRoomState.empty(ConversationToken roomToken) =>
      RichChatRoomState(
        roomToken: roomToken,
        messages: const {},
        threads: const {},
        reminders: const {},
        scheduledMessages: const {},
        lastMessageId: null,
      );

  final ConversationToken roomToken;
  final Map<int, ChatMessage> messages;
  final Map<int, RichChatThread> threads;
  final Map<int, RichChatReminder> reminders;
  final Map<RichChatScheduleId, RichChatScheduledMessage> scheduledMessages;
  final int? lastMessageId;

  ChatMessage? get lastMessage =>
      lastMessageId == null ? null : messages[lastMessageId];

  RichChatRoomState copyWith({
    Map<int, ChatMessage>? messages,
    Map<int, RichChatThread>? threads,
    Map<int, RichChatReminder>? reminders,
    Map<RichChatScheduleId, RichChatScheduledMessage>? scheduledMessages,
    Object? lastMessageId = _unchanged,
  }) => RichChatRoomState(
    roomToken: roomToken,
    messages: messages ?? this.messages,
    threads: threads ?? this.threads,
    reminders: reminders ?? this.reminders,
    scheduledMessages: scheduledMessages ?? this.scheduledMessages,
    lastMessageId: identical(lastMessageId, _unchanged)
        ? this.lastMessageId
        : lastMessageId as int?,
  );

  void _validate() {
    for (final entry in messages.entries) {
      if (entry.key != entry.value.messageId ||
          entry.value.roomToken != roomToken) {
        _stateFailure(r'$.rooms.messages');
      }
    }
    for (final entry in threads.entries) {
      final thread = entry.value;
      if (entry.key != thread.threadId || thread.roomToken != roomToken) {
        _stateFailure(r'$.rooms.threads');
      }
      final first = thread.firstMessage;
      final last = thread.lastMessage;
      if ((first != null &&
              (first.roomToken != roomToken ||
                  first.messageId != thread.threadId)) ||
          (last != null &&
              (last.roomToken != roomToken ||
                  last.messageId != thread.lastMessageId))) {
        _stateFailure(r'$.rooms.threads.messages');
      }
    }
    for (final entry in reminders.entries) {
      if (entry.key != entry.value.messageId ||
          entry.value.roomToken != roomToken) {
        _stateFailure(r'$.rooms.reminders');
      }
    }
    for (final entry in scheduledMessages.entries) {
      if (entry.key != entry.value.scheduleId ||
          entry.value.roomToken != roomToken) {
        _stateFailure(r'$.rooms.scheduledMessages');
      }
    }
    if (lastMessageId != null && !messages.containsKey(lastMessageId)) {
      _stateFailure(r'$.rooms.lastMessageId');
    }
  }

  @override
  String toString() =>
      'RichChatRoomState(messageCount: ${messages.length}, '
      'threadCount: ${threads.length}, reminderCount: ${reminders.length}, '
      'scheduleCount: ${scheduledMessages.length})';
}

final class RichChatAccountState {
  RichChatAccountState({
    required this.accountId,
    required this.server,
    required Map<ConversationToken, RichChatRoomState> rooms,
  }) : rooms = UnmodifiableMapView(Map.of(rooms)) {
    for (final entry in rooms.entries) {
      if (entry.key != entry.value.roomToken) {
        _stateFailure(r'$.accounts.rooms');
      }
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final Map<ConversationToken, RichChatRoomState> rooms;

  RichChatAccountState replaceRoom(RichChatRoomState room) {
    final updated = Map<ConversationToken, RichChatRoomState>.of(rooms);
    updated[room.roomToken] = room;
    return RichChatAccountState(
      accountId: accountId,
      server: server,
      rooms: updated,
    );
  }

  @override
  String toString() => 'RichChatAccountState(roomCount: ${rooms.length})';
}

/// Rich-chat state layered on top of the existing account-bound chat state.
final class RichChatRuntimeSnapshot {
  RichChatRuntimeSnapshot({
    required this.chat,
    required Map<AccountId, RichChatAccountState> accounts,
  }) : accounts = UnmodifiableMapView(Map.of(accounts)) {
    for (final entry in accounts.entries) {
      final chatAccount = chat.accounts[entry.key];
      if (entry.key != entry.value.accountId ||
          chatAccount == null ||
          chatAccount.server != entry.value.server) {
        _stateFailure(r'$.accounts');
      }
    }
  }

  final ChatRuntimeSnapshot chat;
  final Map<AccountId, RichChatAccountState> accounts;

  RichChatRuntimeSnapshot replaceAccount(RichChatAccountState account) {
    final updated = Map<AccountId, RichChatAccountState>.of(accounts);
    updated[account.accountId] = account;
    return RichChatRuntimeSnapshot(chat: chat, accounts: updated);
  }

  RichChatRuntimeSnapshot replaceChat(ChatRuntimeSnapshot chat) =>
      RichChatRuntimeSnapshot(chat: chat, accounts: accounts);

  @override
  String toString() =>
      'RichChatRuntimeSnapshot(accountCount: ${accounts.length})';
}

const Object _unchanged = Object();

Never _stateFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidRichChatState, path);
