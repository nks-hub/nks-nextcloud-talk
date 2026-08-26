import '../chat/models.dart';
import '../chat/state.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';
import 'response.dart';
import 'state.dart';

enum RichChatMergeOutcome {
  applied,
  unchanged,
  rejected,
  reauthenticationRequired,
}

/// Single-use transaction candidate bound to one exact source snapshot.
final class RichChatStatePlan {
  RichChatStatePlan._(this._source, this._candidate);

  final RichChatRuntimeSnapshot _source;
  final RichChatRuntimeSnapshot _candidate;
  bool _consumed = false;

  RichChatRuntimeSnapshot commit(RichChatRuntimeSnapshot current) {
    _consume(current);
    return _candidate;
  }

  RichChatRuntimeSnapshot discard(RichChatRuntimeSnapshot current) {
    _consume(current);
    return current;
  }

  RichChatRuntimeSnapshot complete(
    RichChatRuntimeSnapshot current, {
    required bool persisted,
  }) {
    _consume(current);
    return persisted ? _candidate : current;
  }

  void _consume(RichChatRuntimeSnapshot current) {
    if (_consumed) {
      _mergeFailure(r'$.plan.consumed');
    }
    _consumed = true;
    if (!identical(current, _source)) {
      _mergeFailure(r'$.plan.source');
    }
  }

  @override
  String toString() => 'RichChatStatePlan(<redacted>)';
}

final class RichChatMergeResult {
  const RichChatMergeResult._(this.outcome, this.plan);

  final RichChatMergeOutcome outcome;
  final RichChatStatePlan? plan;

  @override
  String toString() => 'RichChatMergeResult(outcome: ${outcome.name})';
}

RichChatMergeResult planRichChatMerge(
  RichChatRuntimeSnapshot snapshot,
  RichChatResponse response,
) {
  final request = response.request;
  final account = snapshot.accounts[request.accountId];
  final chatAccount = snapshot.chat.accounts[request.accountId];
  if (account == null ||
      chatAccount == null ||
      account.server != request.server ||
      chatAccount.server != request.server) {
    return _rejected;
  }

  if (response.classification ==
      RichChatResponseClassification.reauthenticationRequired) {
    if (chatAccount.lane == ChatAccountLane.reauthenticationRequired) {
      return _unchanged;
    }
    final updatedChat = snapshot.chat.replaceAccount(
      chatAccount.copyWith(lane: ChatAccountLane.reauthenticationRequired),
    );
    return _planned(
      snapshot,
      snapshot.replaceChat(updatedChat),
      RichChatMergeOutcome.reauthenticationRequired,
    );
  }
  if (response.classification != RichChatResponseClassification.success) {
    return _unchanged;
  }

  return switch (request.operation) {
    RichChatOperation.getMentionSuggestions ||
    RichChatOperation.hidePinnedChatMessage => _unchanged,
    RichChatOperation.getRecentThreads ||
    RichChatOperation.getSubscribedThreads ||
    RichChatOperation.getThread ||
    RichChatOperation.renameThread ||
    RichChatOperation.setThreadNotificationLevel => _mergeThreads(
      snapshot,
      account,
      response.threads,
    ),
    RichChatOperation.getMessageReactions ||
    RichChatOperation.addMessageReaction ||
    RichChatOperation.deleteMessageReaction => _mergeReactions(
      snapshot,
      account,
      response,
    ),
    RichChatOperation.editChatMessage ||
    RichChatOperation.deleteChatMessage ||
    RichChatOperation.pinChatMessage ||
    RichChatOperation.unpinChatMessage => _mergeMessageMutation(
      snapshot,
      account,
      response,
    ),
    RichChatOperation.getChatReminder ||
    RichChatOperation.setChatReminder ||
    RichChatOperation.deleteChatReminder => _mergeReminder(
      snapshot,
      account,
      response,
    ),
    RichChatOperation.getScheduledChatMessages ||
    RichChatOperation.scheduleChatMessage ||
    RichChatOperation.editScheduledChatMessage ||
    RichChatOperation.deleteScheduledChatMessage => _mergeSchedule(
      snapshot,
      account,
      response,
    ),
  };
}

RichChatMergeResult _mergeThreads(
  RichChatRuntimeSnapshot snapshot,
  RichChatAccountState account,
  Iterable<RichChatThread> threads,
) {
  var updatedAccount = account;
  for (final incoming in threads) {
    final room =
        updatedAccount.rooms[incoming.roomToken] ??
        RichChatRoomState.empty(incoming.roomToken);
    final existing = room.threads[incoming.threadId];
    final retainedFirst =
        incoming.firstMessage ??
        (existing?.firstMessage?.messageId == incoming.threadId &&
                existing?.firstMessage?.threadId == incoming.threadId
            ? existing?.firstMessage
            : null);
    final retainedLast =
        incoming.lastMessage ??
        (existing?.lastMessage?.messageId == incoming.lastMessageId &&
                existing?.lastMessage?.threadId == incoming.threadId
            ? existing?.lastMessage
            : null);
    var projectedFirst = _projectThreadTitle(incoming, retainedFirst);
    var projectedLast = _projectThreadTitle(incoming, retainedLast);
    final cachedRoot = room.messages[incoming.threadId];
    final projectedRoot =
        projectedFirst ??
        (cachedRoot?.threadId == incoming.threadId
            ? _projectThreadTitle(incoming, cachedRoot)
            : null) ??
        (projectedLast?.messageId == incoming.threadId ? projectedLast : null);
    if (projectedRoot != null) {
      if (projectedFirst?.messageId == projectedRoot.messageId) {
        projectedFirst = projectedRoot;
      } else {
        projectedFirst = projectedFirst?.replaceParentMessageIfMatching(
          projectedRoot,
        );
      }
      if (projectedLast?.messageId == projectedRoot.messageId) {
        projectedLast = projectedRoot;
      } else {
        projectedLast = projectedLast?.replaceParentMessageIfMatching(
          projectedRoot,
        );
      }
    }
    final merged = incoming.copyWithMessages(
      firstMessage: projectedFirst,
      lastMessage: projectedLast,
    );
    var updatedMessages = <int, ChatMessage>{
      for (final entry in room.messages.entries)
        entry.key: _projectThreadTitle(incoming, entry.value)!,
    };
    var updatedThreads = Map<int, RichChatThread>.of(room.threads);
    var updatedSchedules = <RichChatScheduleId, RichChatScheduledMessage>{
      for (final entry in room.scheduledMessages.entries)
        entry.key: _projectScheduledThreadTitle(incoming, entry.value),
    };
    if (projectedRoot != null) {
      updatedMessages = _replaceMessageInMessages(
        updatedMessages,
        projectedRoot,
      );
      updatedThreads = _replaceMessageInThreads(updatedThreads, projectedRoot);
      updatedSchedules = _replaceMessageInSchedules(
        updatedSchedules,
        projectedRoot,
      );
    }
    updatedThreads[merged.threadId] = merged;
    if (merged.firstMessage case final first?) {
      updatedMessages[first.messageId] = first;
    }
    if (merged.lastMessage case final last?) {
      updatedMessages[last.messageId] = last;
    }
    updatedAccount = updatedAccount.replaceRoom(
      room.copyWith(
        messages: updatedMessages,
        threads: updatedThreads,
        scheduledMessages: updatedSchedules,
      ),
    );
  }
  if (identical(updatedAccount, account)) {
    return _unchanged;
  }
  return _replaceAccount(snapshot, updatedAccount);
}

ChatMessage? _projectThreadTitle(RichChatThread thread, ChatMessage? message) {
  if (message == null ||
      message.roomToken != thread.roomToken ||
      message.threadId != thread.threadId ||
      (message.threadTitle == thread.title &&
          message.wire['threadTitle'] == thread.title)) {
    return message;
  }
  return ChatMessage.fromJson(<String, Object?>{
    ...message.wire,
    'threadTitle': thread.title,
  });
}

RichChatScheduledMessage _projectScheduledThreadTitle(
  RichChatThread thread,
  RichChatScheduledMessage scheduled,
) {
  if (scheduled.roomToken != thread.roomToken ||
      scheduled.threadId != thread.threadId) {
    return scheduled;
  }
  return scheduled.projectThreadTitle(
    threadId: thread.threadId,
    threadTitle: thread.title,
    parent: _projectThreadTitle(thread, scheduled.parent),
  );
}

RichChatMergeResult _mergeReactions(
  RichChatRuntimeSnapshot snapshot,
  RichChatAccountState account,
  RichChatResponse response,
) {
  final roomToken = response.request.roomToken;
  final messageId = response.request.messageId;
  final aggregate = response.reactionAggregate;
  if (roomToken == null || messageId == null || aggregate == null) {
    return _rejected;
  }
  final room = account.rooms[roomToken];
  final message = room?.messages[messageId];
  if (room == null || message == null) {
    return _rejected;
  }
  final updatedMessage = message.withReactionAggregate(
    reactions: aggregate.counts,
    reactionsSelf: aggregate.reactionsSelf,
  );
  final updatedMessages = _replaceMessageInMessages(
    room.messages,
    updatedMessage,
  );
  final updatedThreads = _replaceMessageInThreads(room.threads, updatedMessage);
  final updatedSchedules = _replaceMessageInSchedules(
    room.scheduledMessages,
    updatedMessage,
  );
  return _replaceAccount(
    snapshot,
    account.replaceRoom(
      room.copyWith(
        messages: updatedMessages,
        threads: updatedThreads,
        scheduledMessages: updatedSchedules,
      ),
    ),
  );
}

RichChatMergeResult _mergeMessageMutation(
  RichChatRuntimeSnapshot snapshot,
  RichChatAccountState account,
  RichChatResponse response,
) {
  final roomToken = response.request.roomToken;
  final messageId = response.request.messageId;
  final mutation = response.messageMutation;
  final parent = mutation?.parent;
  if (roomToken == null ||
      messageId == null ||
      parent is! ChatFullParent ||
      parent.messageId != messageId ||
      parent.roomToken != roomToken) {
    return _rejected;
  }
  final room = account.rooms[roomToken];
  if (room == null || !room.messages.containsKey(messageId)) {
    return _rejected;
  }
  final authoritative = parent.message;
  final updatedMessages = _replaceMessageInMessages(
    room.messages,
    authoritative,
  );
  final updatedThreads = _replaceMessageInThreads(room.threads, authoritative);
  final updatedSchedules = _replaceMessageInSchedules(
    room.scheduledMessages,
    authoritative,
  );
  return _replaceAccount(
    snapshot,
    account.replaceRoom(
      room.copyWith(
        messages: updatedMessages,
        threads: updatedThreads,
        scheduledMessages: updatedSchedules,
      ),
    ),
  );
}

RichChatMergeResult _mergeReminder(
  RichChatRuntimeSnapshot snapshot,
  RichChatAccountState account,
  RichChatResponse response,
) {
  final roomToken = response.request.roomToken;
  final messageId = response.request.messageId;
  if (roomToken == null || messageId == null) {
    return _rejected;
  }
  final room = account.rooms[roomToken];
  if (room == null) {
    return _rejected;
  }
  final reminders = Map<int, RichChatReminder>.of(room.reminders);
  if (response.request.operation == RichChatOperation.deleteChatReminder) {
    if (reminders.remove(messageId) == null) {
      return _unchanged;
    }
  } else {
    final reminder = response.reminder;
    if (reminder == null ||
        reminder.messageId != messageId ||
        reminder.roomToken != roomToken) {
      return _rejected;
    }
    reminders[messageId] = reminder;
  }
  return _replaceAccount(
    snapshot,
    account.replaceRoom(room.copyWith(reminders: reminders)),
  );
}

RichChatMergeResult _mergeSchedule(
  RichChatRuntimeSnapshot snapshot,
  RichChatAccountState account,
  RichChatResponse response,
) {
  final roomToken = response.request.roomToken;
  if (roomToken == null) {
    return _rejected;
  }
  final room = account.rooms[roomToken];
  if (room == null) {
    return _rejected;
  }
  final schedules = Map<RichChatScheduleId, RichChatScheduledMessage>.of(
    room.scheduledMessages,
  );
  switch (response.request.operation) {
    case RichChatOperation.getScheduledChatMessages:
      schedules
        ..clear()
        ..addEntries(
          response.scheduledMessages.map(
            (message) => MapEntry(message.scheduleId, message),
          ),
        );
    case RichChatOperation.scheduleChatMessage:
    case RichChatOperation.editScheduledChatMessage:
      if (response.scheduledMessages.length != 1) {
        return _rejected;
      }
      final scheduled = response.scheduledMessages.single;
      schedules[scheduled.scheduleId] = scheduled;
    case RichChatOperation.deleteScheduledChatMessage:
      final scheduleId = response.request.scheduleId;
      if (scheduleId == null) {
        return _rejected;
      }
      if (schedules.remove(scheduleId) == null) {
        return _unchanged;
      }
    default:
      return _rejected;
  }
  return _replaceAccount(
    snapshot,
    account.replaceRoom(room.copyWith(scheduledMessages: schedules)),
  );
}

Map<int, RichChatThread> _replaceMessageInThreads(
  Map<int, RichChatThread> source,
  ChatMessage message,
) {
  final updated = Map<int, RichChatThread>.of(source);
  for (final entry in source.entries) {
    final thread = entry.value;
    final first = thread.firstMessage;
    final last = thread.lastMessage;
    final updatedFirst = first?.messageId == message.messageId
        ? message
        : first?.replaceParentMessageIfMatching(message);
    final updatedLast = last?.messageId == message.messageId
        ? message
        : last?.replaceParentMessageIfMatching(message);
    if (!identical(updatedFirst, first) || !identical(updatedLast, last)) {
      updated[entry.key] = thread.copyWithMessages(
        firstMessage: updatedFirst,
        lastMessage: updatedLast,
      );
    }
  }
  return updated;
}

Map<int, ChatMessage> _replaceMessageInMessages(
  Map<int, ChatMessage> source,
  ChatMessage authoritative,
) => <int, ChatMessage>{
  for (final entry in source.entries)
    entry.key: entry.key == authoritative.messageId
        ? authoritative
        : entry.value.replaceParentMessageIfMatching(authoritative),
};

Map<RichChatScheduleId, RichChatScheduledMessage> _replaceMessageInSchedules(
  Map<RichChatScheduleId, RichChatScheduledMessage> source,
  ChatMessage authoritative,
) => <RichChatScheduleId, RichChatScheduledMessage>{
  for (final entry in source.entries)
    entry.key: entry.value.replaceParentMessageIfMatching(authoritative),
};

RichChatMergeResult _replaceAccount(
  RichChatRuntimeSnapshot snapshot,
  RichChatAccountState account,
) => _planned(
  snapshot,
  snapshot.replaceAccount(account),
  RichChatMergeOutcome.applied,
);

RichChatMergeResult _planned(
  RichChatRuntimeSnapshot source,
  RichChatRuntimeSnapshot candidate,
  RichChatMergeOutcome outcome,
) => RichChatMergeResult._(outcome, RichChatStatePlan._(source, candidate));

const RichChatMergeResult _unchanged = RichChatMergeResult._(
  RichChatMergeOutcome.unchanged,
  null,
);
const RichChatMergeResult _rejected = RichChatMergeResult._(
  RichChatMergeOutcome.rejected,
  null,
);

Never _mergeFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidRichChatMerge, path);
