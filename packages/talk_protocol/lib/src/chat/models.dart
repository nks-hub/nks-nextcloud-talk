import 'dart:collection';

import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';

const int chatJsonMaximumDepth = 64;
const int chatJsonMaximumNodes = 200000;
const int chatMaximumResponseBytes = 8 * 1024 * 1024;

sealed class ChatMessageParent {
  const ChatMessageParent();
}

final class ChatDeletedParent extends ChatMessageParent {
  const ChatDeletedParent({required this.messageId});

  final int messageId;

  @override
  String toString() => 'ChatDeletedParent()';
}

final class ChatFullParent extends ChatMessageParent {
  const ChatFullParent({required this.message});

  final ChatMessage message;

  int get messageId => message.messageId;

  ConversationToken get roomToken => message.roomToken;

  String get referenceId => message.referenceId;

  Map<String, Object?> get metadata => message.metadata;

  Map<String, Object?> get wire => message.wire;

  @override
  String toString() => 'ChatFullParent(<redacted>)';
}

final class ChatRichObjectParameter {
  const ChatRichObjectParameter._({
    required this.type,
    required this.id,
    required this.name,
    required this.link,
    required this.wire,
  });

  factory ChatRichObjectParameter.fromJson(Object? json) {
    const code = TalkProtocolErrorCode.invalidChatResponse;
    final frozen = JsonFreezeSession(
      maximumDepth: chatJsonMaximumDepth,
      maximumNodes: chatJsonMaximumNodes,
      errorCode: code,
      errorPath: r'$.ocs.data[].messageParameters.<member>',
    ).freeze(json);
    final value = requireObject(
      frozen,
      path: r'$.ocs.data[].messageParameters.<member>',
      code: code,
    );
    final type = requireString(
      value['type'],
      path: r'$.ocs.data[].messageParameters.<member>.type',
      code: code,
      minLength: 1,
      maxLength: 128,
    );
    return ChatRichObjectParameter._(
      type: type,
      id: _optionalString(
        value['id'],
        path: r'$.ocs.data[].messageParameters.<member>.id',
        maximum: 4096,
      ),
      name: _optionalString(
        value['name'],
        path: r'$.ocs.data[].messageParameters.<member>.name',
        maximum: 4096,
      ),
      link: _optionalString(
        value['link'],
        path: r'$.ocs.data[].messageParameters.<member>.link',
        maximum: 8192,
      ),
      wire: value,
    );
  }

  final String type;
  final String? id;
  final String? name;
  final String? link;
  final Map<String, Object?> wire;

  @override
  String toString() => 'ChatRichObjectParameter(<redacted>)';
}

final class ChatMessage {
  const ChatMessage._({
    required this.messageId,
    required this.roomToken,
    required this.actorType,
    required this.actorId,
    required this.actorDisplayName,
    required this.timestamp,
    required this.systemMessage,
    required this.messageType,
    required this.isReplyable,
    required this.referenceId,
    required this.message,
    required this.messageParameters,
    required this.expirationTimestamp,
    required this.markdown,
    required this.reactions,
    required this.reactionsSelf,
    required this.deleted,
    required this.lastEditActorDisplayName,
    required this.lastEditActorId,
    required this.lastEditActorType,
    required this.lastEditTimestamp,
    required this.silent,
    required this.threadId,
    required this.isThread,
    required this.threadTitle,
    required this.threadReplies,
    required this.metadata,
    required this.parent,
    required this.wire,
  });

  factory ChatMessage.fromJson(Object? json) {
    final frozen = JsonFreezeSession(
      maximumDepth: chatJsonMaximumDepth,
      maximumNodes: chatJsonMaximumNodes,
      errorCode: TalkProtocolErrorCode.invalidChatResponse,
      errorPath: r'$.ocs.data[]',
    ).freeze(json);
    final value = _messageBase(frozen, path: r'$.ocs.data[]');
    final rawParent = value.wire['parent'];
    ChatMessageParent? parent;
    if (rawParent != null) {
      final parentValue = requireObject(
        rawParent,
        path: r'$.ocs.data[].parent',
        code: TalkProtocolErrorCode.invalidChatResponse,
      );
      if (parentValue['deleted'] == true &&
          !_hasFullMessageShape(parentValue)) {
        parent = ChatDeletedParent(
          messageId: requireInt(
            parentValue['id'],
            path: r'$.ocs.data[].parent.id',
            code: TalkProtocolErrorCode.invalidChatResponse,
            minimum: 1,
          ),
        );
      } else {
        final full = _messageBase(parentValue, path: r'$.ocs.data[].parent');
        parent = ChatFullParent(message: ChatMessage._fromBase(full));
      }
    }
    return ChatMessage._fromBase(value, parent: parent);
  }

  factory ChatMessage._fromBase(
    _MessageBase value, {
    ChatMessageParent? parent,
  }) => ChatMessage._(
    messageId: value.messageId,
    roomToken: value.roomToken,
    actorType: value.actorType,
    actorId: value.actorId,
    actorDisplayName: value.actorDisplayName,
    timestamp: value.timestamp,
    systemMessage: value.systemMessage,
    messageType: value.messageType,
    isReplyable: value.isReplyable,
    referenceId: value.referenceId,
    message: value.message,
    messageParameters: value.messageParameters,
    expirationTimestamp: value.expirationTimestamp,
    markdown: value.markdown,
    reactions: value.reactions,
    reactionsSelf: value.reactionsSelf,
    deleted: value.deleted,
    lastEditActorDisplayName: value.lastEditActorDisplayName,
    lastEditActorId: value.lastEditActorId,
    lastEditActorType: value.lastEditActorType,
    lastEditTimestamp: value.lastEditTimestamp,
    silent: value.silent,
    threadId: value.threadId,
    isThread: value.isThread,
    threadTitle: value.threadTitle,
    threadReplies: value.threadReplies,
    metadata: value.metadata,
    parent: parent,
    wire: value.wire,
  );

  final int messageId;
  final ConversationToken roomToken;
  final String actorType;
  final String actorId;
  final String actorDisplayName;
  final int timestamp;
  final String systemMessage;
  final String messageType;
  final bool isReplyable;
  final String referenceId;
  final String message;
  final Map<String, ChatRichObjectParameter> messageParameters;
  final int? expirationTimestamp;
  final bool? markdown;
  final Map<String, int> reactions;
  final List<String> reactionsSelf;
  final bool deleted;
  final String? lastEditActorDisplayName;
  final String? lastEditActorId;
  final String? lastEditActorType;
  final int? lastEditTimestamp;
  final bool? silent;
  final int? threadId;
  final bool? isThread;
  final String? threadTitle;
  final int? threadReplies;
  final Map<String, Object?> metadata;
  final ChatMessageParent? parent;
  final Map<String, Object?> wire;

  ChatMessage withReactionAggregate({
    required Map<String, int> reactions,
    required Iterable<String> reactionsSelf,
  }) {
    final immutableReactions = UnmodifiableMapView(Map.of(reactions));
    final immutableSelf = List<String>.unmodifiable(reactionsSelf);
    final updatedWire = requireObject(
      JsonFreezeSession(
        maximumDepth: chatJsonMaximumDepth,
        maximumNodes: chatJsonMaximumNodes,
        errorCode: TalkProtocolErrorCode.invalidChatState,
        errorPath: r'$.messages.reactions',
      ).freeze(<String, Object?>{
        ...wire,
        'reactions': immutableReactions,
        'reactionsSelf': immutableSelf,
      }),
      path: r'$.messages',
      code: TalkProtocolErrorCode.invalidChatState,
    );
    return _copyWith(
      reactions: immutableReactions,
      reactionsSelf: immutableSelf,
      threadTitle: threadTitle,
      parent: parent,
      wire: updatedWire,
    );
  }

  /// Projects a canonical thread title only within the exact room and thread.
  ChatMessage projectThreadTitle({
    required ConversationToken roomToken,
    required int threadId,
    required String threadTitle,
  }) {
    if (this.roomToken != roomToken ||
        this.threadId != threadId ||
        (this.threadTitle == threadTitle &&
            wire['threadTitle'] == threadTitle)) {
      return this;
    }
    final updatedWire = requireObject(
      JsonFreezeSession(
        maximumDepth: chatJsonMaximumDepth,
        maximumNodes: chatJsonMaximumNodes,
        errorCode: TalkProtocolErrorCode.invalidChatState,
        errorPath: r'$.messages.threadTitle',
      ).freeze(<String, Object?>{...wire, 'threadTitle': threadTitle}),
      path: r'$.messages',
      code: TalkProtocolErrorCode.invalidChatState,
    );
    return _copyWith(
      reactions: reactions,
      reactionsSelf: reactionsSelf,
      threadTitle: threadTitle,
      parent: parent,
      wire: updatedWire,
    );
  }

  ChatMessage replaceParentMessageIfMatching(ChatMessage authoritative) {
    final currentParent = parent;
    if (currentParent is! ChatFullParent ||
        currentParent.messageId != authoritative.messageId ||
        currentParent.roomToken != authoritative.roomToken ||
        identical(currentParent.message, authoritative)) {
      return this;
    }
    final updatedWire = requireObject(
      JsonFreezeSession(
        maximumDepth: chatJsonMaximumDepth,
        maximumNodes: chatJsonMaximumNodes,
        errorCode: TalkProtocolErrorCode.invalidChatState,
        errorPath: r'$.messages.parent',
      ).freeze(<String, Object?>{...wire, 'parent': authoritative.wire}),
      path: r'$.messages',
      code: TalkProtocolErrorCode.invalidChatState,
    );
    return _copyWith(
      reactions: reactions,
      reactionsSelf: reactionsSelf,
      threadTitle: threadTitle,
      parent: ChatFullParent(message: authoritative),
      wire: updatedWire,
    );
  }

  ChatMessage _copyWith({
    required Map<String, int> reactions,
    required List<String> reactionsSelf,
    required String? threadTitle,
    required ChatMessageParent? parent,
    required Map<String, Object?> wire,
  }) => ChatMessage._(
    messageId: messageId,
    roomToken: roomToken,
    actorType: actorType,
    actorId: actorId,
    actorDisplayName: actorDisplayName,
    timestamp: timestamp,
    systemMessage: systemMessage,
    messageType: messageType,
    isReplyable: isReplyable,
    referenceId: referenceId,
    message: message,
    messageParameters: messageParameters,
    expirationTimestamp: expirationTimestamp,
    markdown: markdown,
    reactions: reactions,
    reactionsSelf: reactionsSelf,
    deleted: deleted,
    lastEditActorDisplayName: lastEditActorDisplayName,
    lastEditActorId: lastEditActorId,
    lastEditActorType: lastEditActorType,
    lastEditTimestamp: lastEditTimestamp,
    silent: silent,
    threadId: threadId,
    isThread: isThread,
    threadTitle: threadTitle,
    threadReplies: threadReplies,
    metadata: metadata,
    parent: parent,
    wire: wire,
  );

  @override
  String toString() => 'ChatMessage(<redacted>)';
}

_MessageBase _messageBase(Object? json, {required String path}) {
  const code = TalkProtocolErrorCode.invalidChatResponse;
  final value = requireObject(json, path: path, code: code);
  final parameters = _messageParameters(value['messageParameters']);
  final reactions = _reactions(value['reactions']);
  final rawMetadata = value['metaData'];
  final metadata = rawMetadata == null
      ? const <String, Object?>{}
      : requireObject(rawMetadata, path: '$path.metaData', code: code);
  return _MessageBase(
    messageId: requireInt(
      value['id'],
      path: '$path.id',
      code: code,
      minimum: 1,
    ),
    roomToken: ConversationToken.parse(
      value['token'],
      path: '$path.token',
      code: code,
    ),
    actorType: requireString(
      value['actorType'],
      path: '$path.actorType',
      code: code,
      minLength: 1,
      maxLength: 128,
    ),
    actorId: requireString(
      value['actorId'],
      path: '$path.actorId',
      code: code,
      maxLength: 4096,
    ),
    actorDisplayName: requireString(
      value['actorDisplayName'],
      path: '$path.actorDisplayName',
      code: code,
      maxLength: 4096,
    ),
    timestamp: requireInt(
      value['timestamp'],
      path: '$path.timestamp',
      code: code,
      minimum: 0,
    ),
    systemMessage: requireString(
      value['systemMessage'],
      path: '$path.systemMessage',
      code: code,
      maxLength: 256,
    ),
    messageType: requireString(
      value['messageType'],
      path: '$path.messageType',
      code: code,
      minLength: 1,
      maxLength: 128,
    ),
    isReplyable: requireBool(
      value['isReplyable'],
      path: '$path.isReplyable',
      code: code,
    ),
    referenceId: requireString(
      value['referenceId'],
      path: '$path.referenceId',
      code: code,
      maxLength: 64,
    ),
    message: requireString(value['message'], path: '$path.message', code: code),
    messageParameters: parameters,
    expirationTimestamp: _optionalInt(
      value['expirationTimestamp'],
      path: '$path.expirationTimestamp',
    ),
    markdown: _optionalBool(value['markdown'], path: '$path.markdown'),
    reactions: reactions,
    reactionsSelf: _reactionsSelf(value['reactionsSelf'], path: path),
    deleted: _optionalTrue(value['deleted'], path: '$path.deleted'),
    lastEditActorDisplayName: _optionalString(
      value['lastEditActorDisplayName'],
      path: '$path.lastEditActorDisplayName',
      maximum: 4096,
    ),
    lastEditActorId: _optionalString(
      value['lastEditActorId'],
      path: '$path.lastEditActorId',
      maximum: 4096,
    ),
    lastEditActorType: _optionalString(
      value['lastEditActorType'],
      path: '$path.lastEditActorType',
      maximum: 128,
    ),
    lastEditTimestamp: _optionalInt(
      value['lastEditTimestamp'],
      path: '$path.lastEditTimestamp',
      minimum: 0,
    ),
    silent: _optionalBool(value['silent'], path: '$path.silent'),
    threadId: _optionalInt(
      value['threadId'],
      path: '$path.threadId',
      minimum: 0,
    ),
    isThread: _optionalBool(value['isThread'], path: '$path.isThread'),
    threadTitle: _optionalString(
      value['threadTitle'],
      path: '$path.threadTitle',
    ),
    threadReplies: _optionalInt(
      value['threadReplies'],
      path: '$path.threadReplies',
      minimum: 0,
    ),
    metadata: metadata,
    wire: value,
  );
}

Map<String, ChatRichObjectParameter> _messageParameters(Object? raw) {
  const code = TalkProtocolErrorCode.invalidChatResponse;
  if (raw is List<Object?>) {
    if (raw.isNotEmpty) {
      protocolFailure(code, r'$.ocs.data[].messageParameters');
    }
    return const <String, ChatRichObjectParameter>{};
  }
  final value = requireObject(
    raw,
    path: r'$.ocs.data[].messageParameters',
    code: code,
  );
  final result = <String, ChatRichObjectParameter>{};
  for (final entry in value.entries) {
    result[entry.key] = ChatRichObjectParameter.fromJson(entry.value);
  }
  return UnmodifiableMapView(result);
}

Map<String, int> _reactions(Object? raw) {
  if (raw == null) {
    return const <String, int>{};
  }
  const code = TalkProtocolErrorCode.invalidChatResponse;
  if (raw is List<Object?>) {
    if (raw.isNotEmpty) {
      protocolFailure(code, r'$.ocs.data[].reactions');
    }
    return const <String, int>{};
  }
  final value = requireObject(raw, path: r'$.ocs.data[].reactions', code: code);
  final result = <String, int>{};
  for (final entry in value.entries) {
    result[entry.key] = requireInt(
      entry.value,
      path: r'$.ocs.data[].reactions.<member>',
      code: code,
      minimum: 0,
    );
  }
  return UnmodifiableMapView(result);
}

List<String> _reactionsSelf(Object? raw, {required String path}) {
  if (raw == null) {
    return const <String>[];
  }
  const code = TalkProtocolErrorCode.invalidChatResponse;
  final values = requireList(raw, path: '$path.reactionsSelf', code: code);
  final result = <String>[];
  final unique = <String>{};
  for (var index = 0; index < values.length; index++) {
    final reaction = requireString(
      values[index],
      path: '$path.reactionsSelf[$index]',
      code: code,
      minLength: 1,
      maxLength: 32,
    );
    if (!unique.add(reaction)) {
      protocolFailure(code, '$path.reactionsSelf');
    }
    result.add(reaction);
  }
  return List.unmodifiable(result);
}

bool _optionalTrue(Object? value, {required String path}) {
  if (value == null) {
    return false;
  }
  final parsed = requireBool(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidChatResponse,
  );
  if (!parsed) {
    protocolFailure(TalkProtocolErrorCode.invalidChatResponse, path);
  }
  return true;
}

bool _hasFullMessageShape(Map<String, Object?> value) => const <String>{
  'id',
  'token',
  'actorType',
  'actorId',
  'actorDisplayName',
  'timestamp',
  'systemMessage',
  'messageType',
  'isReplyable',
  'referenceId',
  'message',
  'messageParameters',
  'markdown',
  'reactions',
}.every(value.containsKey);

bool? _optionalBool(Object? value, {required String path}) {
  return value == null
      ? null
      : requireBool(
          value,
          path: path,
          code: TalkProtocolErrorCode.invalidChatResponse,
        );
}

int? _optionalInt(Object? value, {required String path, int? minimum}) {
  return value == null
      ? null
      : requireInt(
          value,
          path: path,
          code: TalkProtocolErrorCode.invalidChatResponse,
          minimum: minimum,
        );
}

String? _optionalString(Object? value, {required String path, int? maximum}) {
  return value == null
      ? null
      : requireString(
          value,
          path: path,
          code: TalkProtocolErrorCode.invalidChatResponse,
          maxLength: maximum,
        );
}

final class _MessageBase {
  const _MessageBase({
    required this.messageId,
    required this.roomToken,
    required this.actorType,
    required this.actorId,
    required this.actorDisplayName,
    required this.timestamp,
    required this.systemMessage,
    required this.messageType,
    required this.isReplyable,
    required this.referenceId,
    required this.message,
    required this.messageParameters,
    required this.expirationTimestamp,
    required this.markdown,
    required this.reactions,
    required this.reactionsSelf,
    required this.deleted,
    required this.lastEditActorDisplayName,
    required this.lastEditActorId,
    required this.lastEditActorType,
    required this.lastEditTimestamp,
    required this.silent,
    required this.threadId,
    required this.isThread,
    required this.threadTitle,
    required this.threadReplies,
    required this.metadata,
    required this.wire,
  });

  final int messageId;
  final ConversationToken roomToken;
  final String actorType;
  final String actorId;
  final String actorDisplayName;
  final int timestamp;
  final String systemMessage;
  final String messageType;
  final bool isReplyable;
  final String referenceId;
  final String message;
  final Map<String, ChatRichObjectParameter> messageParameters;
  final int? expirationTimestamp;
  final bool? markdown;
  final Map<String, int> reactions;
  final List<String> reactionsSelf;
  final bool deleted;
  final String? lastEditActorDisplayName;
  final String? lastEditActorId;
  final String? lastEditActorType;
  final int? lastEditTimestamp;
  final bool? silent;
  final int? threadId;
  final bool? isThread;
  final String? threadTitle;
  final int? threadReplies;
  final Map<String, Object?> metadata;
  final Map<String, Object?> wire;
}
