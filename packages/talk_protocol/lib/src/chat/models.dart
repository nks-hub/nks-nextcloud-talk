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
  const ChatFullParent({
    required this.messageId,
    required this.roomToken,
    required this.referenceId,
    required this.metadata,
    required this.wire,
  });

  final int messageId;
  final ConversationToken roomToken;
  final String referenceId;
  final Map<String, Object?> metadata;
  final Map<String, Object?> wire;

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
    final value = requireObject(
      json,
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
    required this.threadId,
    required this.threadTitle,
    required this.threadReplies,
    required this.metadata,
    required this.parent,
    required this.wire,
  });

  factory ChatMessage.fromJson(Object? json) {
    final value = _messageBase(json, path: r'$.ocs.data[]');
    final rawParent = value.wire['parent'];
    ChatMessageParent? parent;
    if (rawParent != null) {
      final parentValue = requireObject(
        rawParent,
        path: r'$.ocs.data[].parent',
        code: TalkProtocolErrorCode.invalidChatResponse,
      );
      if (parentValue['deleted'] == true) {
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
        parent = ChatFullParent(
          messageId: full.messageId,
          roomToken: full.roomToken,
          referenceId: full.referenceId,
          metadata: full.metadata,
          wire: full.wire,
        );
      }
    }
    return ChatMessage._(
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
      threadId: value.threadId,
      threadTitle: value.threadTitle,
      threadReplies: value.threadReplies,
      metadata: value.metadata,
      parent: parent,
      wire: value.wire,
    );
  }

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
  final int? threadId;
  final String? threadTitle;
  final int? threadReplies;
  final Map<String, Object?> metadata;
  final ChatMessageParent? parent;
  final Map<String, Object?> wire;

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
    threadId: _optionalInt(
      value['threadId'],
      path: '$path.threadId',
      minimum: 0,
    ),
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
    required this.threadId,
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
  final int? threadId;
  final String? threadTitle;
  final int? threadReplies;
  final Map<String, Object?> metadata;
  final Map<String, Object?> wire;
}
