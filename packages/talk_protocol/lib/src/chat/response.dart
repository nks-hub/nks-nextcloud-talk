import 'dart:convert';
import 'dart:typed_data';

import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';

enum ChatGetClassification {
  messages,
  invisibleCursorAdvance,
  commonReadOnly,
  notModified,
  reauthenticationRequired,
  threadNotFound,
  transientError,
  ocsError,
}

enum ChatReadClassification {
  readConfirmed,
  unreadConfirmed,
  reauthenticationRequired,
  ocsError,
}

enum ChatSendClassification {
  confirmed,
  unconfirmed,
  ambiguous,
  deterministicFailure,
  rateLimited,
  reauthenticationRequired,
  serverError,
}

final class ChatGetResponse {
  const ChatGetResponse._({
    required this.request,
    required this.classification,
    required this.messages,
    required this.cursor,
    required this.lastCommonRead,
  });

  final ChatFetchRequest request;
  final ChatGetClassification classification;
  final List<ChatMessage> messages;
  final ChatCursor? cursor;
  final ChatCursor? lastCommonRead;

  @override
  String toString() =>
      'ChatGetResponse(classification: ${classification.name}, '
      'messageCount: ${messages.length})';
}

final class ChatReadMarkerSnapshot {
  const ChatReadMarkerSnapshot._({
    required this.roomToken,
    required this.lastReadMessage,
    required this.lastCommonReadMessage,
    required this.unreadMessages,
    required this.wire,
  });

  final ConversationToken roomToken;
  final int lastReadMessage;
  final int lastCommonReadMessage;
  final int unreadMessages;
  final Map<String, Object?> wire;

  @override
  String toString() => 'ChatReadMarkerSnapshot(<redacted>)';
}

final class ChatReadResponse {
  const ChatReadResponse._({
    required this.request,
    required this.classification,
    required this.marker,
  });

  final ChatRequest request;
  final ChatReadClassification classification;
  final ChatReadMarkerSnapshot? marker;

  @override
  String toString() =>
      'ChatReadResponse(classification: ${classification.name})';
}

final class ChatResponseHeaders {
  ChatResponseHeaders._(this._values);

  factory ChatResponseHeaders.fromEntries(
    Iterable<MapEntry<String, String>> entries,
  ) {
    final values = <String, String>{};
    for (final entry in entries) {
      if (entry.key.isEmpty ||
          entry.key.length > 256 ||
          entry.value.length > 8192 ||
          _hasControlCharacter(entry.key) ||
          _hasForbiddenHeaderControl(entry.value)) {
        protocolFailure(TalkProtocolErrorCode.invalidChatHeaders, r'$.headers');
      }
      final name = entry.key.toLowerCase();
      if (values.containsKey(name)) {
        protocolFailure(TalkProtocolErrorCode.invalidChatHeaders, r'$.headers');
      }
      values[name] = entry.value;
    }
    return ChatResponseHeaders._(Map.unmodifiable(values));
  }

  factory ChatResponseHeaders.fromMap(Map<String, String> headers) =>
      ChatResponseHeaders.fromEntries(headers.entries);

  final Map<String, String> _values;

  String? value(String name) => _values[name.toLowerCase()];

  ChatCursor? cursor(String name) {
    final raw = value(name);
    return raw == null
        ? null
        : ChatCursor.parse(
            raw,
            path: r'$.headers',
            code: TalkProtocolErrorCode.invalidChatHeaders,
          );
  }

  int? get retryAfterSeconds {
    final raw = value('Retry-After');
    if (raw == null || !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(raw)) {
      return null;
    }
    if (raw.length > 5 || (raw.length == 5 && raw.compareTo('86400') > 0)) {
      return 86400;
    }
    final seconds = int.parse(raw);
    return seconds > 86400 ? 86400 : seconds;
  }

  @override
  String toString() => 'ChatResponseHeaders(count: ${_values.length})';
}

final class ChatSendResponse {
  const ChatSendResponse._({
    required this.request,
    required this.classification,
    required this.message,
    required this.messageId,
    required this.retryAfterSeconds,
  });

  final ChatSendRequest request;
  final ChatSendClassification classification;
  final ChatMessage? message;
  final int? messageId;
  final int? retryAfterSeconds;

  @override
  String toString() =>
      'ChatSendResponse(classification: ${classification.name})';
}

ChatGetResponse decodeChatGetResponse({
  required ChatFetchRequest request,
  required int statusCode,
  required Uint8List body,
  ChatResponseHeaders? headers,
}) {
  final responseHeaders = headers ?? ChatResponseHeaders.fromMap(const {});
  if (statusCode == 304) {
    if (body.isNotEmpty) {
      _responseFailure(r'$.body');
    }
    return ChatGetResponse._(
      request: request,
      classification: ChatGetClassification.notModified,
      messages: const [],
      cursor: null,
      lastCommonRead: null,
    );
  }
  final envelope = _decodeOcsEnvelope(body);
  final errorClassification = switch (statusCode) {
    401 => ChatGetClassification.reauthenticationRequired,
    404 => ChatGetClassification.threadNotFound,
    429 || 503 => ChatGetClassification.transientError,
    200 => null,
    _ => throw TalkProtocolException(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      path: r'$.statusCode',
    ),
  };
  if (errorClassification != null) {
    return ChatGetResponse._(
      request: request,
      classification: errorClassification,
      messages: const [],
      cursor: null,
      lastCommonRead: null,
    );
  }
  if (!envelope.isSuccess(200)) {
    return ChatGetResponse._(
      request: request,
      classification: ChatGetClassification.ocsError,
      messages: const [],
      cursor: null,
      lastCommonRead: null,
    );
  }

  final rawMessages = requireList(
    envelope.data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidChatResponse,
  );
  if (rawMessages.length > 200) {
    _responseFailure(r'$.ocs.data');
  }
  final messages = rawMessages
      .map(ChatMessage.fromJson)
      .toList(growable: false);
  _validateMessages(request, messages);
  final cursor = responseHeaders.cursor('X-Chat-Last-Given');
  final commonRead = responseHeaders.cursor('X-Chat-Last-Common-Read');
  if (messages.isNotEmpty && cursor == null) {
    _responseFailure(r'$.headers.X-Chat-Last-Given');
  }
  // Cursor `0` is "no position yet": a room whose preview carried no message
  // id (a federated room, measured on Talk 24) starts its history from
  // nothing, and the server answers with the newest page. Only a real
  // cursor bounds which way the answer may go.
  final openCursor = request.cursor.value == '0';
  if (cursor != null && !openCursor) {
    final directionOrder = cursor.compareTo(request.cursor);
    if ((request.direction == ChatFetchDirection.history &&
            directionOrder > 0) ||
        (request.direction == ChatFetchDirection.future &&
            directionOrder < 0)) {
      _responseFailure(r'$.headers.X-Chat-Last-Given');
    }
  }
  if (messages.isNotEmpty) {
    final ids = messages.map((message) => message.messageId).toList();
    final boundary = request.direction == ChatFetchDirection.history
        ? ids.reduce((left, right) => left < right ? left : right)
        : ids.reduce((left, right) => left > right ? left : right);
    final boundaryCursor = ChatCursor.parse(boundary.toString());
    if ((request.direction == ChatFetchDirection.history &&
            cursor!.compareTo(boundaryCursor) > 0) ||
        (request.direction == ChatFetchDirection.future &&
            cursor!.compareTo(boundaryCursor) < 0)) {
      _responseFailure(r'$.headers.X-Chat-Last-Given');
    }
  }
  final classification = messages.isNotEmpty
      ? ChatGetClassification.messages
      : cursor != null
      ? ChatGetClassification.invisibleCursorAdvance
      : commonRead != null
      ? ChatGetClassification.commonReadOnly
      : null;
  if (classification == null) {
    _responseFailure(r'$.ocs.data');
  }
  return ChatGetResponse._(
    request: request,
    classification: classification,
    messages: List.unmodifiable(messages),
    cursor: cursor,
    lastCommonRead: commonRead,
  );
}

ChatReadResponse decodeChatReadResponse({
  required ChatRequest request,
  required int statusCode,
  required Uint8List body,
  ChatResponseHeaders? headers,
}) {
  if (request is! ChatSetReadMarkerRequest &&
      request is! ChatMarkUnreadRequest) {
    protocolFailure(TalkProtocolErrorCode.invalidChatRequest, r'$.request');
  }
  final envelope = _decodeOcsEnvelope(body);
  if (statusCode == 401) {
    return ChatReadResponse._(
      request: request,
      classification: ChatReadClassification.reauthenticationRequired,
      marker: null,
    );
  }
  if (statusCode != 200 || !envelope.isSuccess(200)) {
    return ChatReadResponse._(
      request: request,
      classification: ChatReadClassification.ocsError,
      marker: null,
    );
  }
  final value = requireObject(
    envelope.data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidChatResponse,
  );
  final roomToken = ConversationToken.parse(
    value['token'],
    path: r'$.ocs.data.token',
    code: TalkProtocolErrorCode.invalidChatResponse,
  );
  if (roomToken != request.roomToken) {
    _responseFailure(r'$.ocs.data.token');
  }
  final marker = ChatReadMarkerSnapshot._(
    roomToken: roomToken,
    lastReadMessage: requireInt(
      value['lastReadMessage'],
      path: r'$.ocs.data.lastReadMessage',
      code: TalkProtocolErrorCode.invalidChatResponse,
      minimum: -2,
    ),
    lastCommonReadMessage: requireInt(
      value['lastCommonReadMessage'],
      path: r'$.ocs.data.lastCommonReadMessage',
      code: TalkProtocolErrorCode.invalidChatResponse,
      minimum: 0,
    ),
    unreadMessages: requireInt(
      value['unreadMessages'],
      path: r'$.ocs.data.unreadMessages',
      code: TalkProtocolErrorCode.invalidChatResponse,
      minimum: 0,
    ),
    wire: value,
  );
  if (request is ChatSetReadMarkerRequest &&
      marker.lastReadMessage != request.lastReadMessage) {
    _responseFailure(r'$.ocs.data.lastReadMessage');
  }
  final commonRead = (headers ?? ChatResponseHeaders.fromMap(const {})).cursor(
    'X-Chat-Last-Common-Read',
  );
  if (commonRead != null &&
      commonRead.value != marker.lastCommonReadMessage.toString()) {
    _responseFailure(r'$.headers.X-Chat-Last-Common-Read');
  }
  return ChatReadResponse._(
    request: request,
    classification: request is ChatSetReadMarkerRequest
        ? ChatReadClassification.readConfirmed
        : ChatReadClassification.unreadConfirmed,
    marker: marker,
  );
}

ChatSendResponse decodeChatSendResponse({
  required ChatSendRequest request,
  required int statusCode,
  required Uint8List body,
  ChatResponseHeaders? headers,
}) {
  final responseHeaders = headers ?? ChatResponseHeaders.fromMap(const {});
  final envelope = _decodeOcsEnvelope(body);
  final errorCode = envelope.data is Map<String, Object?>
      ? (envelope.data! as Map<String, Object?>)['error']
      : null;
  if (statusCode == 401) {
    return _sendResult(
      request,
      ChatSendClassification.reauthenticationRequired,
    );
  }
  if (statusCode == 429 && errorCode == 'mentions') {
    return _sendResult(
      request,
      ChatSendClassification.rateLimited,
      retryAfterSeconds: responseHeaders.retryAfterSeconds,
    );
  }
  if ((<int>{400, 403}.contains(statusCode) && errorCode == 'reply-to') ||
      (statusCode == 404 && errorCode == 'actor') ||
      (statusCode == 413 && errorCode == 'message')) {
    return _sendResult(request, ChatSendClassification.deterministicFailure);
  }
  if (statusCode == 400 && errorCode == 'message') {
    return _sendResult(request, ChatSendClassification.ambiguous);
  }
  if (statusCode != 201 || !envelope.isSuccess(201)) {
    return _sendResult(request, ChatSendClassification.serverError);
  }
  if (envelope.data == null) {
    return _sendResult(request, ChatSendClassification.unconfirmed);
  }
  final message = ChatMessage.fromJson(envelope.data);
  if (message.roomToken != request.roomToken ||
      message.referenceId != request.referenceId.value) {
    return _sendResult(
      request,
      ChatSendClassification.unconfirmed,
      message: message,
    );
  }
  if (!_matchesDirectSendContext(request, message)) {
    _responseFailure(r'$.ocs.data.parent');
  }
  return _sendResult(
    request,
    ChatSendClassification.confirmed,
    message: message,
    messageId: message.messageId,
  );
}

_OcsEnvelope _decodeOcsEnvelope(Uint8List body) {
  if (body.length > chatMaximumResponseBytes) {
    _responseFailure(r'$.body');
  }
  String source;
  try {
    source = utf8.decode(body, allowMalformed: false);
  } on FormatException {
    _responseFailure(r'$.body');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    _responseFailure(r'$.body');
  }
  final frozen = JsonFreezeSession(
    maximumDepth: chatJsonMaximumDepth,
    maximumNodes: chatJsonMaximumNodes,
    errorCode: TalkProtocolErrorCode.invalidChatResponse,
    errorPath: r'$.body',
  ).freeze(decoded);
  final root = requireObject(
    frozen,
    path: r'$',
    code: TalkProtocolErrorCode.invalidChatResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidChatResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidChatResponse,
  );
  return _OcsEnvelope(
    status: requireString(
      meta['status'],
      path: r'$.ocs.meta.status',
      code: TalkProtocolErrorCode.invalidChatResponse,
      minLength: 1,
      maxLength: 128,
    ),
    statusCode: requireInt(
      meta['statuscode'],
      path: r'$.ocs.meta.statuscode',
      code: TalkProtocolErrorCode.invalidChatResponse,
      minimum: 0,
      maximum: 999,
    ),
    data: ocs['data'],
  );
}

bool _matchesDirectSendContext(ChatSendRequest request, ChatMessage message) {
  if (request.threadId != null) {
    return message.threadId == request.threadId && message.parent == null;
  }
  if (request.replyTo == null) {
    return message.threadId == message.messageId && message.parent == null;
  }
  final parent = message.parent;
  if (parent is! ChatFullParent ||
      parent.roomToken != request.parentRoomToken) {
    return false;
  }
  if (request.replyToToken == null) {
    final parentThreadId = parent.message.threadId;
    return parent.messageId == request.replyTo &&
        parentThreadId != null &&
        parentThreadId > 0 &&
        message.threadId == parentThreadId;
  }
  return parent.metadata['replyToMessageId'] == request.replyTo &&
      parent.metadata['replyToConversationToken'] ==
          request.replyToToken!.value &&
      parent.message.threadId == 0 &&
      message.threadId == parent.messageId;
}

ChatSendResponse _sendResult(
  ChatSendRequest request,
  ChatSendClassification classification, {
  ChatMessage? message,
  int? messageId,
  int? retryAfterSeconds,
}) => ChatSendResponse._(
  request: request,
  classification: classification,
  message: message,
  messageId: messageId,
  retryAfterSeconds: retryAfterSeconds,
);

void _validateMessages(ChatFetchRequest request, List<ChatMessage> messages) {
  final ids = <int>{};
  int? previousId;
  for (final message in messages) {
    if (message.roomToken != request.roomToken) {
      _responseFailure(r'$.ocs.data[].token');
    }
    if (request.threadId != null && message.threadId != request.threadId) {
      _responseFailure(r'$.ocs.data[].threadId');
    }
    if (!ids.add(message.messageId)) {
      _responseFailure(r'$.ocs.data[].id');
    }
    if (previousId != null &&
        ((request.direction == ChatFetchDirection.history &&
                message.messageId >= previousId) ||
            (request.direction == ChatFetchDirection.future &&
                message.messageId <= previousId))) {
      _responseFailure(r'$.ocs.data');
    }
    previousId = message.messageId;
  }
}

Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidChatResponse, path);

bool _hasControlCharacter(String value) {
  return value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}

bool _hasForbiddenHeaderControl(String value) {
  return value.codeUnits.any(
    (unit) => unit == 0 || unit == 0x0a || unit == 0x0d || unit == 0x7f,
  );
}

final class _OcsEnvelope {
  const _OcsEnvelope({
    required this.status,
    required this.statusCode,
    required this.data,
  });

  final String status;
  final int statusCode;
  final Object? data;

  bool isSuccess(int expectedStatusCode) =>
      status == 'ok' && statusCode == expectedStatusCode;
}
