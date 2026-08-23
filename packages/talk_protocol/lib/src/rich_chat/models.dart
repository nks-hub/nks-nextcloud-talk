import 'dart:collection';

import '../chat/models.dart';
import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';

const int richChatMaximumResponseBytes = 8 * 1024 * 1024;
const int richChatMaximumJsonDepth = 64;
const int richChatMaximumJsonNodes = 200000;

final class RichChatMentionSuggestion {
  const RichChatMentionSuggestion._({
    required this.id,
    required this.label,
    required this.source,
    required this.mentionId,
    required this.details,
    required this.status,
    required this.statusClearAt,
    required this.statusIcon,
    required this.statusMessage,
    required this.wire,
  });

  factory RichChatMentionSuggestion.fromJson(Object? json) {
    final value = _frozenObject(json, r'$.ocs.data[]');
    return RichChatMentionSuggestion._(
      id: _string(value['id'], r'$.ocs.data[].id', maximum: 4096),
      label: _string(value['label'], r'$.ocs.data[].label', maximum: 4096),
      source: _string(
        value['source'],
        r'$.ocs.data[].source',
        minimum: 1,
        maximum: 128,
      ),
      mentionId: _string(
        value['mentionId'],
        r'$.ocs.data[].mentionId',
        maximum: 4096,
      ),
      details: _optionalString(
        value['details'],
        r'$.ocs.data[].details',
        maximum: 4096,
      ),
      status: _optionalString(
        value['status'],
        r'$.ocs.data[].status',
        maximum: 128,
      ),
      statusClearAt: _optionalInt(
        value['statusClearAt'],
        r'$.ocs.data[].statusClearAt',
        minimum: 0,
      ),
      statusIcon: _optionalString(
        value['statusIcon'],
        r'$.ocs.data[].statusIcon',
        maximum: 256,
      ),
      statusMessage: _optionalString(
        value['statusMessage'],
        r'$.ocs.data[].statusMessage',
        maximum: 4096,
      ),
      wire: value,
    );
  }

  final String id;
  final String label;
  final String source;
  final String mentionId;
  final String? details;
  final String? status;
  final int? statusClearAt;
  final String? statusIcon;
  final String? statusMessage;
  final Map<String, Object?> wire;

  @override
  String toString() => 'RichChatMentionSuggestion(<redacted>)';
}

final class RichChatThread {
  const RichChatThread._({
    required this.threadId,
    required this.roomToken,
    required this.title,
    required this.lastMessageId,
    required this.lastActivity,
    required this.numReplies,
    required this.notificationLevel,
    required this.firstMessage,
    required this.lastMessage,
    required this.wire,
  });

  factory RichChatThread.fromJson(Object? json) {
    final value = _frozenObject(json, r'$.ocs.data[].threadInfo');
    final thread = requireObject(
      value['thread'],
      path: r'$.ocs.data[].thread',
      code: TalkProtocolErrorCode.invalidRichChatResponse,
    );
    final attendee = requireObject(
      value['attendee'],
      path: r'$.ocs.data[].attendee',
      code: TalkProtocolErrorCode.invalidRichChatResponse,
    );
    final first = value['first'];
    final last = value['last'];
    final threadId = _integer(
      thread['id'],
      r'$.ocs.data[].thread.id',
      minimum: 1,
    );
    final roomToken = ConversationToken.parse(
      thread['roomToken'],
      path: r'$.ocs.data[].thread.roomToken',
      code: TalkProtocolErrorCode.invalidRichChatResponse,
    );
    final lastMessageId = _integer(
      thread['lastMessageId'],
      r'$.ocs.data[].thread.lastMessageId',
      minimum: 0,
    );
    final firstMessage = first == null ? null : ChatMessage.fromJson(first);
    final lastMessage = last == null ? null : ChatMessage.fromJson(last);
    if ((firstMessage != null &&
            (firstMessage.roomToken != roomToken ||
                firstMessage.messageId != threadId)) ||
        (lastMessage != null &&
            (lastMessage.roomToken != roomToken ||
                lastMessage.messageId != lastMessageId))) {
      _responseFailure(r'$.ocs.data[].thread.messages');
    }
    return RichChatThread._(
      threadId: threadId,
      roomToken: roomToken,
      title: _string(
        thread['title'],
        r'$.ocs.data[].thread.title',
        maximum: 4096,
      ),
      lastMessageId: lastMessageId,
      lastActivity: _integer(
        thread['lastActivity'],
        r'$.ocs.data[].thread.lastActivity',
        minimum: 0,
      ),
      numReplies: _integer(
        thread['numReplies'],
        r'$.ocs.data[].thread.numReplies',
        minimum: 0,
      ),
      notificationLevel: _integer(
        attendee['notificationLevel'],
        r'$.ocs.data[].attendee.notificationLevel',
        minimum: 0,
        maximum: 3,
      ),
      firstMessage: firstMessage,
      lastMessage: lastMessage,
      wire: value,
    );
  }

  final int threadId;
  final ConversationToken roomToken;
  final String title;
  final int lastMessageId;
  final int lastActivity;
  final int numReplies;
  final int notificationLevel;
  final ChatMessage? firstMessage;
  final ChatMessage? lastMessage;
  final Map<String, Object?> wire;

  RichChatThread copyWithMessages({
    Object? firstMessage = _unchangedMessage,
    Object? lastMessage = _unchangedMessage,
  }) {
    final effectiveFirst = identical(firstMessage, _unchangedMessage)
        ? this.firstMessage
        : firstMessage as ChatMessage?;
    final effectiveLast = identical(lastMessage, _unchangedMessage)
        ? this.lastMessage
        : lastMessage as ChatMessage?;
    final updatedWire = _frozenObject(<String, Object?>{
      ...wire,
      'first': effectiveFirst?.wire,
      'last': effectiveLast?.wire,
    }, r'$.threads');
    return RichChatThread._(
      threadId: threadId,
      roomToken: roomToken,
      title: title,
      lastMessageId: lastMessageId,
      lastActivity: lastActivity,
      numReplies: numReplies,
      notificationLevel: notificationLevel,
      firstMessage: effectiveFirst,
      lastMessage: effectiveLast,
      wire: updatedWire,
    );
  }

  @override
  String toString() =>
      'RichChatThread(replyCount: $numReplies, notificationLevel: '
      '$notificationLevel, <redacted>)';
}

final class RichChatReactionActor {
  const RichChatReactionActor._({
    required this.actorDisplayName,
    required this.actorId,
    required this.actorType,
    required this.timestamp,
    required this.wire,
  });

  factory RichChatReactionActor.fromJson(Object? json) {
    final value = _frozenObject(json, r'$.ocs.data.<reaction>[]');
    return RichChatReactionActor._(
      actorDisplayName: _string(
        value['actorDisplayName'],
        r'$.ocs.data.<reaction>[].actorDisplayName',
        maximum: 4096,
      ),
      actorId: _string(
        value['actorId'],
        r'$.ocs.data.<reaction>[].actorId',
        maximum: 4096,
      ),
      actorType: _string(
        value['actorType'],
        r'$.ocs.data.<reaction>[].actorType',
        minimum: 1,
        maximum: 128,
      ),
      timestamp: _integer(
        value['timestamp'],
        r'$.ocs.data.<reaction>[].timestamp',
        minimum: 0,
      ),
      wire: value,
    );
  }

  final String actorDisplayName;
  final String actorId;
  final String actorType;
  final int timestamp;
  final Map<String, Object?> wire;

  @override
  String toString() => 'RichChatReactionActor(<redacted>)';
}

final class RichChatReactionAggregate {
  RichChatReactionAggregate._({
    required Map<String, List<RichChatReactionActor>> actors,
    required Map<String, int> counts,
    required Iterable<String> reactionsSelf,
  }) : actors = UnmodifiableMapView(actors),
       counts = UnmodifiableMapView(counts),
       reactionsSelf = List.unmodifiable(reactionsSelf);

  factory RichChatReactionAggregate.fromJson(
    Object? json, {
    required RichChatActorIdentity actor,
  }) {
    final value = _frozenObject(json, r'$.ocs.data');
    final actors = <String, List<RichChatReactionActor>>{};
    final counts = <String, int>{};
    final reactionsSelf = <String>[];
    for (final entry in value.entries) {
      if (entry.key.isEmpty || entry.key.length > 32) {
        _responseFailure(r'$.ocs.data.<reaction>');
      }
      final rawActors = requireList(
        entry.value,
        path: r'$.ocs.data.<reaction>',
        code: TalkProtocolErrorCode.invalidRichChatResponse,
      );
      if (rawActors.length > 10000) {
        _responseFailure(r'$.ocs.data.<reaction>');
      }
      final parsed = rawActors
          .map(RichChatReactionActor.fromJson)
          .toList(growable: false);
      actors[entry.key] = List.unmodifiable(parsed);
      counts[entry.key] = parsed.length;
      if (parsed.any(
        (item) =>
            item.actorType == actor.actorType && item.actorId == actor.actorId,
      )) {
        reactionsSelf.add(entry.key);
      }
    }
    reactionsSelf.sort();
    return RichChatReactionAggregate._(
      actors: actors,
      counts: counts,
      reactionsSelf: reactionsSelf,
    );
  }

  final Map<String, List<RichChatReactionActor>> actors;
  final Map<String, int> counts;
  final List<String> reactionsSelf;

  @override
  String toString() =>
      'RichChatReactionAggregate(reactionKinds: ${counts.length})';
}

final class RichChatReminder {
  const RichChatReminder._({
    required this.messageId,
    required this.timestamp,
    required this.roomToken,
    required this.userId,
    required this.wire,
  });

  factory RichChatReminder.fromJson(Object? json) {
    final value = _frozenObject(json, r'$.ocs.data');
    return RichChatReminder._(
      messageId: _integer(
        value['messageId'],
        r'$.ocs.data.messageId',
        minimum: 1,
      ),
      timestamp: _integer(
        value['timestamp'],
        r'$.ocs.data.timestamp',
        minimum: 0,
      ),
      roomToken: ConversationToken.parse(
        value['token'],
        path: r'$.ocs.data.token',
        code: TalkProtocolErrorCode.invalidRichChatResponse,
      ),
      userId: _string(value['userId'], r'$.ocs.data.userId', maximum: 4096),
      wire: value,
    );
  }

  final int messageId;
  final int timestamp;
  final ConversationToken roomToken;
  final String userId;
  final Map<String, Object?> wire;

  @override
  String toString() => 'RichChatReminder(<redacted>)';
}

final class RichChatScheduledMessage {
  const RichChatScheduledMessage._({
    required this.scheduleId,
    required this.roomToken,
    required this.actorId,
    required this.actorType,
    required this.threadId,
    required this.threadTitle,
    required this.parent,
    required this.message,
    required this.messageType,
    required this.createdAt,
    required this.sendAt,
    required this.silent,
    required this.originalSendAt,
    required this.wire,
  });

  factory RichChatScheduledMessage.fromJson(
    Object? json, {
    required ConversationToken roomToken,
  }) {
    final value = _frozenObject(json, r'$.ocs.data[]');
    final rawParent = value['parent'];
    final parent = rawParent == null ? null : ChatMessage.fromJson(rawParent);
    if (parent != null && parent.roomToken != roomToken) {
      _responseFailure(r'$.ocs.data[].parent.token');
    }
    return RichChatScheduledMessage._(
      scheduleId: RichChatScheduleId.parse(
        value['id'],
        path: r'$.ocs.data[].id',
        code: TalkProtocolErrorCode.invalidRichChatResponse,
      ),
      roomToken: roomToken,
      actorId: _string(
        value['actorId'],
        r'$.ocs.data[].actorId',
        maximum: 4096,
      ),
      actorType: _string(
        value['actorType'],
        r'$.ocs.data[].actorType',
        minimum: 1,
        maximum: 128,
      ),
      threadId: _integer(value['threadId'], r'$.ocs.data[].threadId'),
      threadTitle: _optionalString(
        value['threadTitle'],
        r'$.ocs.data[].threadTitle',
        maximum: 4096,
      ),
      parent: parent,
      message: _string(value['message'], r'$.ocs.data[].message'),
      messageType: _string(
        value['messageType'],
        r'$.ocs.data[].messageType',
        minimum: 1,
        maximum: 128,
      ),
      createdAt: _integer(
        value['createdAt'],
        r'$.ocs.data[].createdAt',
        minimum: 0,
      ),
      sendAt: _integer(value['sendAt'], r'$.ocs.data[].sendAt', minimum: 0),
      silent: _boolean(value['silent'], r'$.ocs.data[].silent'),
      originalSendAt: _optionalInt(
        value['originalSendAt'],
        r'$.ocs.data[].originalSendAt',
        minimum: 0,
      ),
      wire: value,
    );
  }

  final RichChatScheduleId scheduleId;
  final ConversationToken roomToken;
  final String actorId;
  final String actorType;
  final int threadId;
  final String? threadTitle;
  final ChatMessage? parent;
  final String message;
  final String messageType;
  final int createdAt;
  final int sendAt;
  final bool silent;
  final int? originalSendAt;
  final Map<String, Object?> wire;

  RichChatScheduledMessage replaceParentMessageIfMatching(
    ChatMessage authoritative,
  ) {
    final currentParent = parent;
    if (currentParent == null || authoritative.roomToken != roomToken) {
      return this;
    }
    final updatedParent = currentParent.messageId == authoritative.messageId
        ? authoritative
        : currentParent.replaceParentMessageIfMatching(authoritative);
    if (identical(updatedParent, currentParent)) {
      return this;
    }
    final updatedWire = requireObject(
      JsonFreezeSession(
        maximumDepth: richChatMaximumJsonDepth,
        maximumNodes: richChatMaximumJsonNodes,
        errorCode: TalkProtocolErrorCode.invalidRichChatState,
        errorPath: r'$.scheduledMessages.parent',
      ).freeze(<String, Object?>{...wire, 'parent': updatedParent.wire}),
      path: r'$.scheduledMessages',
      code: TalkProtocolErrorCode.invalidRichChatState,
    );
    return RichChatScheduledMessage._(
      scheduleId: scheduleId,
      roomToken: roomToken,
      actorId: actorId,
      actorType: actorType,
      threadId: threadId,
      threadTitle: threadTitle,
      parent: updatedParent,
      message: message,
      messageType: messageType,
      createdAt: createdAt,
      sendAt: sendAt,
      silent: silent,
      originalSendAt: originalSendAt,
      wire: updatedWire,
    );
  }

  @override
  String toString() => 'RichChatScheduledMessage(<redacted>)';
}

Map<String, Object?> _frozenObject(Object? json, String path) {
  final frozen = JsonFreezeSession(
    maximumDepth: richChatMaximumJsonDepth,
    maximumNodes: richChatMaximumJsonNodes,
    errorCode: TalkProtocolErrorCode.invalidRichChatResponse,
    errorPath: path,
  ).freeze(json);
  return requireObject(
    frozen,
    path: path,
    code: TalkProtocolErrorCode.invalidRichChatResponse,
  );
}

String _string(Object? value, String path, {int minimum = 0, int? maximum}) =>
    requireString(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidRichChatResponse,
      minLength: minimum,
      maxLength: maximum,
    );

String? _optionalString(Object? value, String path, {int? maximum}) =>
    value == null ? null : _string(value, path, maximum: maximum);

int _integer(Object? value, String path, {int? minimum, int? maximum}) =>
    requireInt(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidRichChatResponse,
      minimum: minimum,
      maximum: maximum,
    );

int? _optionalInt(Object? value, String path, {int? minimum}) =>
    value == null ? null : _integer(value, path, minimum: minimum);

bool _boolean(Object? value, String path) => requireBool(
  value,
  path: path,
  code: TalkProtocolErrorCode.invalidRichChatResponse,
);

Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidRichChatResponse, path);

const Object _unchangedMessage = Object();
