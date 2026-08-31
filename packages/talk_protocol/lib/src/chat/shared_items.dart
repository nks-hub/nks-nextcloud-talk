import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';
import 'response.dart';

const int sharedItemsMaximumResponseBytes = 8 * 1024 * 1024;

enum SharedItemsClassification {
  success,
  reauthenticationRequired,
  roomNotFound,
  lobbyRestricted,
  rateLimited,
  serviceUnavailable,
  ocsError,
}

final class SharedItemsOverviewResponse {
  const SharedItemsOverviewResponse._({
    required this.request,
    required this.classification,
    required this.messagesByType,
  });

  final SharedItemsOverviewRequest request;
  final SharedItemsClassification classification;
  final Map<SharedItemType, List<ChatMessage>> messagesByType;

  @override
  String toString() =>
      'SharedItemsOverviewResponse(classification: ${classification.name}, '
      'categoryCount: ${messagesByType.length})';
}

final class SharedItemsPageResponse {
  const SharedItemsPageResponse._({
    required this.request,
    required this.classification,
    required this.messages,
    required this.lastKnownMessageId,
    required this.moreItemsPossible,
  });

  final SharedItemsPageRequest request;
  final SharedItemsClassification classification;
  final List<ChatMessage> messages;
  final int? lastKnownMessageId;
  final bool moreItemsPossible;

  @override
  String toString() =>
      'SharedItemsPageResponse(classification: ${classification.name}, '
      'messageCount: ${messages.length}, '
      'moreItemsPossible: $moreItemsPossible)';
}

SharedItemsOverviewResponse decodeSharedItemsOverviewResponse({
  required SharedItemsOverviewRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final failure = _httpClassification(statusCode);
  if (failure != null) {
    return SharedItemsOverviewResponse._(
      request: request,
      classification: failure,
      messagesByType: const {},
    );
  }
  if (statusCode != 200) {
    _unsupportedStatus();
  }
  final envelope = _decodeEnvelope(body);
  if (!envelope.success) {
    return SharedItemsOverviewResponse._(
      request: request,
      classification: SharedItemsClassification.ocsError,
      messagesByType: const {},
    );
  }

  final rawTypes = requireObject(
    envelope.data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidSharedItemsResponse,
  );
  if (rawTypes.length > 32) {
    _responseFailure(r'$.ocs.data');
  }
  final parsed = <SharedItemType, List<ChatMessage>>{};
  var totalMessages = 0;
  for (final entry in rawTypes.entries) {
    if (entry.key.length > 64 || _hasControl(entry.key)) {
      _responseFailure(r'$.ocs.data.<type>');
    }
    final rawMessages = requireList(
      entry.value,
      path: r'$.ocs.data.<type>',
      code: TalkProtocolErrorCode.invalidSharedItemsResponse,
    );
    if (rawMessages.length > request.limit) {
      _responseFailure(r'$.ocs.data.<type>');
    }
    totalMessages += rawMessages.length;
    if (totalMessages > SharedItemType.values.length * request.limit) {
      _responseFailure(r'$.ocs.data');
    }
    final type = SharedItemType.fromWireName(entry.key);
    if (type == null || rawMessages.isEmpty) {
      continue;
    }
    parsed[type] = _parseMessages(
      rawMessages,
      roomToken: request.roomToken.value,
      path: r'$.ocs.data.<type>',
    );
  }

  return SharedItemsOverviewResponse._(
    request: request,
    classification: SharedItemsClassification.success,
    messagesByType: UnmodifiableMapView(parsed),
  );
}

SharedItemsPageResponse decodeSharedItemsPageResponse({
  required SharedItemsPageRequest request,
  required int statusCode,
  required Uint8List body,
  ChatResponseHeaders? headers,
}) {
  final responseHeaders = headers ?? ChatResponseHeaders.fromMap(const {});
  final failure = _httpClassification(statusCode);
  if (failure != null) {
    return _emptyPage(request, failure);
  }
  if (statusCode != 200) {
    _unsupportedStatus();
  }
  final envelope = _decodeEnvelope(body);
  if (!envelope.success) {
    return _emptyPage(request, SharedItemsClassification.ocsError);
  }

  final rawMessages = requireObject(
    envelope.data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidSharedItemsResponse,
  );
  if (rawMessages.length > request.limit) {
    _responseFailure(r'$.ocs.data');
  }
  final entries = <Object?>[];
  for (final entry in rawMessages.entries) {
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(entry.key) ||
        entry.key.length > 20) {
      _responseFailure(r'$.ocs.data.<messageId>');
    }
    final message = _parseMessage(entry.value);
    if (message.messageId.toString() != entry.key) {
      _responseFailure(r'$.ocs.data.<messageId>');
    }
    entries.add(entry.value);
  }
  final messages = _parseMessages(
    entries,
    roomToken: request.roomToken.value,
    path: r'$.ocs.data',
  );
  if (request.lastKnownMessageId > 0 &&
      messages.any(
        (message) => message.messageId >= request.lastKnownMessageId,
      )) {
    _responseFailure(r'$.ocs.data');
  }
  final rawCursor = responseHeaders.value('X-Chat-Last-Given');
  if (messages.isEmpty) {
    if (rawCursor != null) {
      _responseFailure(r'$.headers.X-Chat-Last-Given');
    }
    return SharedItemsPageResponse._(
      request: request,
      classification: SharedItemsClassification.success,
      messages: const [],
      lastKnownMessageId: null,
      moreItemsPossible: false,
    );
  }
  if (rawCursor == null ||
      !RegExp(r'^[1-9][0-9]*$').hasMatch(rawCursor) ||
      rawCursor.length > 20) {
    _responseFailure(r'$.headers.X-Chat-Last-Given');
  }
  final cursor = int.tryParse(rawCursor);
  if (cursor == null || cursor <= 0) {
    _responseFailure(r'$.headers.X-Chat-Last-Given');
  }
  final minimumMessageId = messages
      .map((message) => message.messageId)
      .reduce((left, right) => left < right ? left : right);
  if (cursor != minimumMessageId ||
      (request.lastKnownMessageId > 0 &&
          cursor >= request.lastKnownMessageId)) {
    _responseFailure(r'$.headers.X-Chat-Last-Given');
  }

  return SharedItemsPageResponse._(
    request: request,
    classification: SharedItemsClassification.success,
    messages: messages,
    lastKnownMessageId: cursor,
    moreItemsPossible: messages.length == request.limit,
  );
}

SharedItemsPageResponse _emptyPage(
  SharedItemsPageRequest request,
  SharedItemsClassification classification,
) => SharedItemsPageResponse._(
  request: request,
  classification: classification,
  messages: const [],
  lastKnownMessageId: null,
  moreItemsPossible: false,
);

List<ChatMessage> _parseMessages(
  Iterable<Object?> rawMessages, {
  required String roomToken,
  required String path,
}) {
  final messages = <ChatMessage>[];
  final ids = <int>{};
  for (final raw in rawMessages) {
    final message = _parseMessage(raw);
    if (message.roomToken.value != roomToken || !ids.add(message.messageId)) {
      _responseFailure(path);
    }
    messages.add(message);
  }
  messages.sort((left, right) => right.messageId.compareTo(left.messageId));
  return List.unmodifiable(messages);
}

ChatMessage _parseMessage(Object? raw) {
  try {
    return ChatMessage.fromJson(raw);
  } on TalkProtocolException catch (error) {
    protocolFailure(
      TalkProtocolErrorCode.invalidSharedItemsResponse,
      error.path,
    );
  }
}

SharedItemsClassification? _httpClassification(int statusCode) =>
    switch (statusCode) {
      401 => SharedItemsClassification.reauthenticationRequired,
      404 => SharedItemsClassification.roomNotFound,
      412 => SharedItemsClassification.lobbyRestricted,
      429 => SharedItemsClassification.rateLimited,
      503 => SharedItemsClassification.serviceUnavailable,
      _ => null,
    };

_SharedItemsEnvelope _decodeEnvelope(Uint8List body) {
  if (body.isEmpty || body.length > sharedItemsMaximumResponseBytes) {
    _responseFailure(r'$.body');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body, allowMalformed: false));
  } on FormatException {
    _responseFailure(r'$.body');
  }
  final frozen = JsonFreezeSession(
    maximumDepth: chatJsonMaximumDepth,
    maximumNodes: chatJsonMaximumNodes,
    errorCode: TalkProtocolErrorCode.invalidSharedItemsResponse,
    errorPath: r'$.body',
  ).freeze(decoded);
  final root = requireObject(
    frozen,
    path: r'$',
    code: TalkProtocolErrorCode.invalidSharedItemsResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidSharedItemsResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidSharedItemsResponse,
  );
  final status = requireString(
    meta['status'],
    path: r'$.ocs.meta.status',
    code: TalkProtocolErrorCode.invalidSharedItemsResponse,
    minLength: 1,
    maxLength: 16,
  );
  final statusCode = requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: TalkProtocolErrorCode.invalidSharedItemsResponse,
    minimum: 0,
  );
  requireString(
    meta['message'],
    path: r'$.ocs.meta.message',
    code: TalkProtocolErrorCode.invalidSharedItemsResponse,
    maxLength: 4096,
  );
  return _SharedItemsEnvelope(
    success: status == 'ok' && statusCode == 200,
    data: ocs['data'],
  );
}

final class _SharedItemsEnvelope {
  const _SharedItemsEnvelope({required this.success, required this.data});

  final bool success;
  final Object? data;
}

bool _hasControl(String value) =>
    value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSharedItemsResponse, path);

Never _unsupportedStatus() => throw const TalkProtocolException(
  TalkProtocolErrorCode.unsupportedHttpStatus,
  path: r'$.statusCode',
);
