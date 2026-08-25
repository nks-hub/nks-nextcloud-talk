import '../json_value.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidConversationResponse;

/// A validated Rich Object String parameter from a conversation preview.
final class ConversationRichObjectParameter {
  ConversationRichObjectParameter._({
    required this.type,
    required this.id,
    required this.name,
    required this.link,
    required this.wire,
  });

  final String type;
  final String? id;
  final String? name;
  final String? link;
  final Map<String, Object?> wire;

  @override
  String toString() => 'ConversationRichObjectParameter(<redacted>)';
}

/// A validated last-message preview. Its diagnostic rendering is redacted.
final class ConversationPreview {
  ConversationPreview._({
    required this.actorDisplayName,
    required this.actorId,
    required this.actorType,
    required this.expirationTimestamp,
    required this.message,
    required this.messageParameters,
    required this.messageType,
    required this.systemMessage,
    required this.id,
    required this.isReplyable,
    required this.markdown,
    required this.reactions,
    required this.referenceId,
    required this.timestamp,
    required this.token,
    required this.threadId,
    required this.threadTitle,
    required this.threadReplies,
    required this.wire,
  });

  final String actorDisplayName;
  final String actorId;
  final String actorType;
  final int expirationTimestamp;
  final String message;
  final Map<String, ConversationRichObjectParameter> messageParameters;
  final String messageType;
  final String systemMessage;
  final int? id;
  final bool? isReplyable;
  final bool? markdown;
  final Map<String, int>? reactions;
  final String? referenceId;
  final int? timestamp;
  final ConversationToken? token;
  final int? threadId;
  final String? threadTitle;
  final int? threadReplies;
  final Map<String, Object?> wire;

  @override
  String toString() => 'ConversationPreview(<redacted>)';
}

/// A typed conversation room with its deeply immutable validated wire object.
final class ConversationRoom {
  ConversationRoom._({
    required this.token,
    required this.sessionId,
    required this.id,
    required this.type,
    required this.name,
    required this.objectType,
    required this.avatarVersion,
    required this.isCustomAvatar,
    required this.displayName,
    required this.description,
    required this.status,
    required this.statusClearAt,
    required this.statusIcon,
    required this.statusMessage,
    required this.lastActivity,
    required this.lastReadMessage,
    required this.lastCommonReadMessage,
    required this.unreadMessages,
    required this.unreadMention,
    required this.unreadMentionDirect,
    required this.isFavorite,
    required this.isArchived,
    required this.isImportant,
    required this.isSensitive,
    required this.tagIds,
    required this.permissions,
    required this.attendeePermissions,
    required this.defaultPermissions,
    required this.callPermissions,
    required this.mentionPermissions,
    required this.participantType,
    required this.participantFlags,
    required this.remoteServer,
    required this.readOnly,
    required this.hasCall,
    required this.callFlag,
    required this.callRecording,
    required this.callStartTime,
    required this.canStartCall,
    required this.canDeleteConversation,
    required this.canLeaveConversation,
    required this.canEnableSip,
    required this.hasPassword,
    required this.notificationCalls,
    required this.notificationLevel,
    required this.lastPinnedId,
    required this.hiddenPinnedId,
    required this.hasScheduledMessages,
    required this.lastMessage,
    required this.wire,
  });

  factory ConversationRoom.fromJson(Object? json) {
    final session = JsonFreezeSession(
      errorCode: _responseCode,
      errorPath: r'$.conversation',
    );
    return parseConversationRoom(
      json,
      path: r'$.conversation',
      session: session,
    );
  }

  final ConversationToken token;
  final ConversationSessionId sessionId;
  final int id;
  final int type;
  final String name;
  final String objectType;
  final String avatarVersion;
  final bool isCustomAvatar;
  final String displayName;
  final String description;
  final String? status;
  final int? statusClearAt;
  final String? statusIcon;
  final String? statusMessage;
  final int lastActivity;
  final int lastReadMessage;
  final int lastCommonReadMessage;
  final int unreadMessages;
  final bool unreadMention;
  final bool unreadMentionDirect;
  final bool isFavorite;
  final bool isArchived;
  final bool isImportant;
  final bool isSensitive;
  final Set<String> tagIds;
  final int permissions;
  final int attendeePermissions;
  final int defaultPermissions;
  final int callPermissions;
  final int mentionPermissions;
  final int participantType;
  final int participantFlags;
  final String? remoteServer;
  final int readOnly;

  bool get isFederated => remoteServer != null && remoteServer!.isNotEmpty;
  final bool hasCall;
  final int callFlag;
  final int callRecording;
  final int callStartTime;
  final bool canStartCall;
  final bool canDeleteConversation;
  final bool canLeaveConversation;
  final bool canEnableSip;
  final bool hasPassword;
  final int notificationCalls;
  final int notificationLevel;

  /// Message ID of the conversation's currently pinned message, `0` when
  /// nothing is pinned. Talk keeps at most one pin per conversation.
  final int lastPinnedId;

  /// The pinned message ID this account hid for itself, `0` when the pin is
  /// not hidden. A pin is visible while
  /// `lastPinnedId > 0 && lastPinnedId != hiddenPinnedId`.
  final int hiddenPinnedId;
  final int hasScheduledMessages;
  final ConversationPreview? lastMessage;
  final Map<String, Object?> wire;

  bool get hasUserStatusWire => wire.containsKey('status');

  ConversationRoom preserveUserStatusFrom(ConversationRoom previous) {
    if (token != previous.token) {
      protocolFailure(
        TalkProtocolErrorCode.invalidConversationMerge,
        r'$.rooms[].token',
      );
    }
    if (hasUserStatusWire || !previous.hasUserStatusWire) {
      return this;
    }
    final merged = Map<String, Object?>.of(wire);
    for (final key in const <String>[
      'status',
      'statusClearAt',
      'statusIcon',
      'statusMessage',
    ]) {
      if (previous.wire.containsKey(key)) {
        merged[key] = previous.wire[key];
      }
    }
    return ConversationRoom.fromJson(merged);
  }

  @override
  String toString() => 'ConversationRoom(<redacted>)';
}

ConversationRoom parseConversationRoom(
  Object? json, {
  required String path,
  required JsonFreezeSession session,
}) {
  final frozen = session.freeze(json);
  final room = requireObject(frozen, path: path, code: _responseCode);

  _requireString(room, 'actorId', path);
  _optionalString(room, 'invitedActorId', path);
  _requireString(room, 'actorType', path);
  _requireInt(room, 'attendeeId', path);
  final attendeePermissions = _requireInt(room, 'attendeePermissions', path);
  _requireNullableString(room, 'attendeePin', path, required: true);
  final avatarVersion = _requireString(room, 'avatarVersion', path);
  _requireInt(room, 'breakoutRoomMode', path);
  _requireInt(room, 'breakoutRoomStatus', path);
  final callFlag = _requireInt(room, 'callFlag', path);
  final callPermissions = _requireInt(room, 'callPermissions', path);
  final callRecording = _requireInt(
    room,
    'callRecording',
    path,
    minimum: 0,
    maximum: 5,
  );
  final callStartTime = _requireInt(room, 'callStartTime', path);
  final canDeleteConversation = _requireBool(
    room,
    'canDeleteConversation',
    path,
  );
  final canEnableSip = _requireBool(room, 'canEnableSIP', path);
  final canLeaveConversation = _requireBool(room, 'canLeaveConversation', path);
  final canStartCall = _requireBool(room, 'canStartCall', path);
  final defaultPermissions = _requireInt(room, 'defaultPermissions', path);
  final description = _requireString(room, 'description', path);
  final displayName = _requireString(room, 'displayName', path);
  final hasCall = _requireBool(room, 'hasCall', path);
  final hasPassword = _requireBool(room, 'hasPassword', path);
  final id = _requireInt(room, 'id', path);
  final isCustomAvatar = _requireBool(room, 'isCustomAvatar', path);
  final isFavorite = _requireBool(room, 'isFavorite', path);
  final lastActivity = _requireInt(room, 'lastActivity', path);
  final lastCommonReadMessage = _requireInt(
    room,
    'lastCommonReadMessage',
    path,
  );
  final lastMessage = _optionalPreview(room, 'lastMessage', path);
  _requireInt(room, 'lastPing', path);
  final lastReadMessage = _requireInt(room, 'lastReadMessage', path);
  _requireInt(room, 'listable', path);
  _requireString(room, 'liveTranscriptionLanguageId', path);
  _requireInt(room, 'lobbyState', path);
  _requireInt(room, 'lobbyTimer', path);
  final mentionPermissions = _requireInt(
    room,
    'mentionPermissions',
    path,
    minimum: 0,
    maximum: 1,
  );
  _requireInt(room, 'messageExpiration', path);
  final name = _requireString(room, 'name', path);
  final notificationCalls = _requireInt(room, 'notificationCalls', path);
  final notificationLevel = _requireInt(room, 'notificationLevel', path);
  _requireString(room, 'objectId', path);
  final objectType = _requireString(room, 'objectType', path);
  final participantFlags = _requireInt(room, 'participantFlags', path);
  final participantType = _requireInt(room, 'participantType', path);
  final permissions = _requireInt(room, 'permissions', path);
  final readOnly = _requireInt(room, 'readOnly', path);
  _requireInt(room, 'recordingConsent', path);
  final remoteServer = _optionalString(room, 'remoteServer', path);
  _optionalString(room, 'remoteToken', path);
  final sessionId = ConversationSessionId.parse(
    room['sessionId'],
    path: '$path.sessionId',
    code: _responseCode,
  );
  _requireInt(room, 'sipEnabled', path);
  final status = _optionalString(room, 'status', path);
  final statusClearAt = _optionalNullableInt(room, 'statusClearAt', path);
  final statusIcon = _requireNullableString(room, 'statusIcon', path);
  final statusMessage = _requireNullableString(room, 'statusMessage', path);
  final token = ConversationToken.parse(room['token'], path: '$path.token');
  final type = _requireInt(room, 'type', path);
  final unreadMention = _requireBool(room, 'unreadMention', path);
  final unreadMentionDirect = _requireBool(room, 'unreadMentionDirect', path);
  final unreadMessages = _requireInt(room, 'unreadMessages', path);
  final isArchived = _requireBool(room, 'isArchived', path);
  final isImportant = _requireBool(room, 'isImportant', path);
  final isSensitive = _requireBool(room, 'isSensitive', path);
  final tagIds = requireUniqueStringSet(
    room['tagIds'],
    path: '$path.tagIds',
    code: _responseCode,
  );
  final lastPinnedId = _requireInt(room, 'lastPinnedId', path);
  final hiddenPinnedId = _requireInt(room, 'hiddenPinnedId', path);
  final hasScheduledMessages = _requireInt(
    room,
    'hasScheduledMessages',
    path,
    minimum: 0,
    maximum: 1,
  );
  _requireInt(room, 'attributes', path);

  if (lastMessage != null && lastMessage.token != token) {
    protocolFailure(
      TalkProtocolErrorCode.previewConversationMismatch,
      '$path.lastMessage.token',
    );
  }

  return ConversationRoom._(
    token: token,
    sessionId: sessionId,
    id: id,
    type: type,
    name: name,
    objectType: objectType,
    avatarVersion: avatarVersion,
    isCustomAvatar: isCustomAvatar,
    displayName: displayName,
    description: description,
    status: status,
    statusClearAt: statusClearAt,
    statusIcon: statusIcon,
    statusMessage: statusMessage,
    lastActivity: lastActivity,
    lastReadMessage: lastReadMessage,
    lastCommonReadMessage: lastCommonReadMessage,
    unreadMessages: unreadMessages,
    unreadMention: unreadMention,
    unreadMentionDirect: unreadMentionDirect,
    isFavorite: isFavorite,
    isArchived: isArchived,
    isImportant: isImportant,
    isSensitive: isSensitive,
    tagIds: tagIds,
    permissions: permissions,
    attendeePermissions: attendeePermissions,
    defaultPermissions: defaultPermissions,
    callPermissions: callPermissions,
    mentionPermissions: mentionPermissions,
    participantType: participantType,
    participantFlags: participantFlags,
    remoteServer: remoteServer,
    readOnly: readOnly,
    hasCall: hasCall,
    callFlag: callFlag,
    callRecording: callRecording,
    callStartTime: callStartTime,
    canStartCall: canStartCall,
    canDeleteConversation: canDeleteConversation,
    canLeaveConversation: canLeaveConversation,
    canEnableSip: canEnableSip,
    hasPassword: hasPassword,
    notificationCalls: notificationCalls,
    notificationLevel: notificationLevel,
    lastPinnedId: lastPinnedId,
    hiddenPinnedId: hiddenPinnedId,
    hasScheduledMessages: hasScheduledMessages,
    lastMessage: lastMessage,
    wire: room,
  );
}

ConversationPreview? _optionalPreview(
  Map<String, Object?> object,
  String key,
  String parentPath,
) {
  if (!object.containsKey(key) || object[key] == null) {
    return null;
  }
  final path = '$parentPath.$key';
  final preview = requireObject(object[key], path: path, code: _responseCode);
  final rawParameters = _objectOrEmptyList(
    preview['messageParameters'],
    path: '$path.messageParameters',
  );
  final parameters = <String, ConversationRichObjectParameter>{};
  for (final entry in rawParameters.entries) {
    final parameterPath = '$path.messageParameters[<member>]';
    final value = requireObject(
      entry.value,
      path: parameterPath,
      code: _responseCode,
    );
    parameters[entry.key] = ConversationRichObjectParameter._(
      type: requireString(
        value['type'],
        path: '$parameterPath.type',
        code: _responseCode,
        minLength: 1,
        maxLength: 128,
      ),
      id: _optionalString(value, 'id', parameterPath, maxLength: 4096),
      name: _optionalString(value, 'name', parameterPath, maxLength: 4096),
      link: _optionalString(value, 'link', parameterPath, maxLength: 8192),
      wire: value,
    );
  }

  Map<String, int>? reactions;
  if (preview.containsKey('reactions')) {
    final rawReactions = _objectOrEmptyList(
      preview['reactions'],
      path: '$path.reactions',
    );
    final parsed = <String, int>{};
    for (final entry in rawReactions.entries) {
      parsed[entry.key] = requireInt(
        entry.value,
        path: '$path.reactions[<member>]',
        code: _responseCode,
        minimum: 0,
      );
    }
    reactions = RedactedMapView(parsed);
  }

  ConversationToken? token;
  if (preview.containsKey('token')) {
    token = ConversationToken.parse(preview['token'], path: '$path.token');
  }

  return ConversationPreview._(
    actorDisplayName: _requireString(preview, 'actorDisplayName', path),
    actorId: _requireString(preview, 'actorId', path),
    actorType: _requireString(preview, 'actorType', path),
    expirationTimestamp: _requireInt(preview, 'expirationTimestamp', path),
    message: _requireString(preview, 'message', path),
    messageParameters: RedactedMapView(parameters),
    messageType: _requireString(preview, 'messageType', path),
    systemMessage: _requireString(preview, 'systemMessage', path),
    id: _optionalInt(preview, 'id', path),
    isReplyable: _optionalBool(preview, 'isReplyable', path),
    markdown: _optionalBool(preview, 'markdown', path),
    reactions: reactions,
    referenceId: _optionalString(preview, 'referenceId', path),
    timestamp: _optionalInt(preview, 'timestamp', path),
    token: token,
    threadId: _optionalInt(preview, 'threadId', path),
    threadTitle: _optionalString(preview, 'threadTitle', path),
    threadReplies: _optionalInt(preview, 'threadReplies', path, minimum: 0),
    wire: preview,
  );
}

Map<String, Object?> _objectOrEmptyList(Object? value, {required String path}) {
  if (value is List<Object?>) {
    if (value.isNotEmpty) {
      protocolFailure(_responseCode, path);
    }
    return const <String, Object?>{};
  }
  return requireObject(value, path: path, code: _responseCode);
}

String _requireString(
  Map<String, Object?> object,
  String key,
  String parentPath, {
  int? maxLength,
}) {
  return requireString(
    object[key],
    path: '$parentPath.$key',
    code: _responseCode,
    maxLength: maxLength,
  );
}

String? _optionalString(
  Map<String, Object?> object,
  String key,
  String parentPath, {
  int? maxLength,
}) {
  if (!object.containsKey(key)) {
    return null;
  }
  return requireString(
    object[key],
    path: '$parentPath.$key',
    code: _responseCode,
    maxLength: maxLength,
  );
}

String? _requireNullableString(
  Map<String, Object?> object,
  String key,
  String parentPath, {
  bool required = false,
}) {
  if (!object.containsKey(key)) {
    if (required) {
      protocolFailure(_responseCode, '$parentPath.$key');
    }
    return null;
  }
  final value = object[key];
  if (value == null) {
    return null;
  }
  return requireString(value, path: '$parentPath.$key', code: _responseCode);
}

int _requireInt(
  Map<String, Object?> object,
  String key,
  String parentPath, {
  int? minimum,
  int? maximum,
}) {
  return requireInt(
    object[key],
    path: '$parentPath.$key',
    code: _responseCode,
    minimum: minimum,
    maximum: maximum,
  );
}

int? _optionalInt(
  Map<String, Object?> object,
  String key,
  String parentPath, {
  int? minimum,
  int? maximum,
}) {
  if (!object.containsKey(key)) {
    return null;
  }
  return requireInt(
    object[key],
    path: '$parentPath.$key',
    code: _responseCode,
    minimum: minimum,
    maximum: maximum,
  );
}

int? _optionalNullableInt(
  Map<String, Object?> object,
  String key,
  String parentPath,
) {
  if (!object.containsKey(key) || object[key] == null) {
    return null;
  }
  return requireInt(object[key], path: '$parentPath.$key', code: _responseCode);
}

bool _requireBool(Map<String, Object?> object, String key, String parentPath) {
  return requireBool(
    object[key],
    path: '$parentPath.$key',
    code: _responseCode,
  );
}

bool? _optionalBool(
  Map<String, Object?> object,
  String key,
  String parentPath,
) {
  if (!object.containsKey(key)) {
    return null;
  }
  return requireBool(
    object[key],
    path: '$parentPath.$key',
    code: _responseCode,
  );
}
