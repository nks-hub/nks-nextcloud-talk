import 'dart:convert';
import 'dart:typed_data';

import '../chat/models.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import 'models.dart';
import 'request.dart';

enum RichChatResponseClassification {
  success,
  reauthenticationRequired,
  deterministicFailure,
  ambiguous,
  serverError,
}

/// A bounded, typed response that remains bound to its originating request.
final class RichChatResponse {
  RichChatResponse._({
    required this.request,
    required this.statusCode,
    required this.classification,
    required Iterable<RichChatMentionSuggestion> mentions,
    required Iterable<RichChatThread> threads,
    required this.reactionAggregate,
    required this.messageMutation,
    required this.reminder,
    required Iterable<RichChatScheduledMessage> scheduledMessages,
    required this.rawData,
  }) : mentions = List.unmodifiable(mentions),
       threads = List.unmodifiable(threads),
       scheduledMessages = List.unmodifiable(scheduledMessages);

  final RichChatRequest request;
  final int statusCode;
  final RichChatResponseClassification classification;
  final List<RichChatMentionSuggestion> mentions;
  final List<RichChatThread> threads;
  final RichChatReactionAggregate? reactionAggregate;
  final ChatMessage? messageMutation;
  final RichChatReminder? reminder;
  final List<RichChatScheduledMessage> scheduledMessages;
  final Object? rawData;

  bool get automaticReplayAllowed => false;

  @override
  String toString() =>
      'RichChatResponse(operation: ${request.operation.operationId}, '
      'classification: ${classification.name}, data: <redacted>)';
}

RichChatResponse decodeRichChatResponse({
  required RichChatRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  try {
    return _decodeRichChatResponse(
      request: request,
      statusCode: statusCode,
      body: body,
    );
  } on TalkProtocolException catch (error) {
    if (error.code == TalkProtocolErrorCode.invalidChatResponse) {
      protocolFailure(
        TalkProtocolErrorCode.invalidRichChatResponse,
        error.path,
      );
    }
    rethrow;
  }
}

RichChatResponse _decodeRichChatResponse({
  required RichChatRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  if (statusCode < 100 ||
      statusCode > 599 ||
      body.length > richChatMaximumResponseBytes) {
    _responseFailure(r'$.http');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body, allowMalformed: false));
  } on FormatException {
    _responseFailure(r'$.body');
  }
  final frozen = JsonFreezeSession(
    maximumDepth: richChatMaximumJsonDepth,
    maximumNodes: richChatMaximumJsonNodes,
    errorCode: TalkProtocolErrorCode.invalidRichChatResponse,
    errorPath: r'$.body',
  ).freeze(decoded);
  final envelope = requireObject(
    frozen,
    path: r'$',
    code: TalkProtocolErrorCode.invalidRichChatResponse,
  );
  final ocs = requireObject(
    envelope['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidRichChatResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidRichChatResponse,
  );
  final ocsStatus = requireString(
    meta['status'],
    path: r'$.ocs.meta.status',
    code: TalkProtocolErrorCode.invalidRichChatResponse,
  );
  final ocsStatusCode = requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: TalkProtocolErrorCode.invalidRichChatResponse,
    minimum: 0,
    maximum: 999,
  );
  if (ocsStatusCode != statusCode) {
    _responseFailure(r'$.ocs.meta.statuscode');
  }
  if (!ocs.containsKey('data')) {
    _responseFailure(r'$.ocs.data');
  }

  final classification = _classify(request.operation, statusCode, ocsStatus);
  final data = ocs['data'];
  if (classification != RichChatResponseClassification.success) {
    return RichChatResponse._(
      request: request,
      statusCode: statusCode,
      classification: classification,
      mentions: const [],
      threads: const [],
      reactionAggregate: null,
      messageMutation: null,
      reminder: null,
      scheduledMessages: const [],
      rawData: data,
    );
  }

  final parsed = _parseSuccess(request, data);
  return RichChatResponse._(
    request: request,
    statusCode: statusCode,
    classification: classification,
    mentions: parsed.mentions,
    threads: parsed.threads,
    reactionAggregate: parsed.reactionAggregate,
    messageMutation: parsed.messageMutation,
    reminder: parsed.reminder,
    scheduledMessages: parsed.scheduledMessages,
    rawData: data,
  );
}

RichChatResponseClassification _classify(
  RichChatOperation operation,
  int statusCode,
  String ocsStatus,
) {
  if (_successStatuses(operation).contains(statusCode)) {
    if (ocsStatus != 'ok') {
      _responseFailure(r'$.ocs.meta.status');
    }
    return RichChatResponseClassification.success;
  }
  if (statusCode >= 200 && statusCode < 300) {
    _responseFailure(r'$.http.statusCode');
  }
  if (ocsStatus != 'failure') {
    _responseFailure(r'$.ocs.meta.status');
  }
  if (statusCode == 401) {
    return RichChatResponseClassification.reauthenticationRequired;
  }
  if (statusCode >= 400 && statusCode < 500) {
    return RichChatResponseClassification.deterministicFailure;
  }
  if (statusCode >= 500 && operation.isMutation) {
    return RichChatResponseClassification.ambiguous;
  }
  if (statusCode >= 500) {
    return RichChatResponseClassification.serverError;
  }
  _responseFailure(r'$.http.statusCode');
}

Set<int> _successStatuses(RichChatOperation operation) => switch (operation) {
  RichChatOperation.addMessageReaction => const <int>{200, 201},
  RichChatOperation.editChatMessage ||
  RichChatOperation.deleteChatMessage => const <int>{200, 202},
  RichChatOperation.setChatReminder ||
  RichChatOperation.scheduleChatMessage => const <int>{201},
  RichChatOperation.editScheduledChatMessage => const <int>{202},
  _ => const <int>{200},
};

_ParsedSuccess _parseSuccess(RichChatRequest request, Object? data) {
  switch (request.operation) {
    case RichChatOperation.getMentionSuggestions:
      final values = _list(data, r'$.ocs.data', maximum: 100);
      return _ParsedSuccess(
        mentions: values.map(RichChatMentionSuggestion.fromJson),
      );
    case RichChatOperation.getRecentThreads:
    case RichChatOperation.getSubscribedThreads:
      final values = _list(data, r'$.ocs.data', maximum: 100);
      final threads = values.map(RichChatThread.fromJson).toList();
      _validateThreadBinding(request, threads);
      return _ParsedSuccess(threads: threads);
    case RichChatOperation.getThread:
    case RichChatOperation.renameThread:
    case RichChatOperation.setThreadNotificationLevel:
      final thread = RichChatThread.fromJson(data);
      _validateThreadBinding(request, <RichChatThread>[thread]);
      return _ParsedSuccess(threads: <RichChatThread>[thread]);
    case RichChatOperation.getMessageReactions:
    case RichChatOperation.addMessageReaction:
    case RichChatOperation.deleteMessageReaction:
      final actor = request.actor;
      if (actor == null) {
        _responseFailure(r'$.request.actor');
      }
      return _ParsedSuccess(
        reactionAggregate: RichChatReactionAggregate.fromJson(
          data,
          actor: actor,
        ),
      );
    case RichChatOperation.editChatMessage:
    case RichChatOperation.deleteChatMessage:
    case RichChatOperation.pinChatMessage:
    case RichChatOperation.unpinChatMessage:
      final mutation = ChatMessage.fromJson(data);
      final parent = mutation.parent;
      if (parent is! ChatFullParent ||
          parent.messageId != request.messageId ||
          parent.roomToken != request.roomToken ||
          mutation.roomToken != request.roomToken) {
        _responseFailure(r'$.ocs.data.parent');
      }
      return _ParsedSuccess(messageMutation: mutation);
    case RichChatOperation.hidePinnedChatMessage:
    case RichChatOperation.deleteChatReminder:
    case RichChatOperation.deleteScheduledChatMessage:
      _requireEmpty(data);
      return const _ParsedSuccess();
    case RichChatOperation.getChatReminder:
    case RichChatOperation.setChatReminder:
      final reminder = RichChatReminder.fromJson(data);
      if (reminder.messageId != request.messageId ||
          reminder.roomToken != request.roomToken) {
        _responseFailure(r'$.ocs.data');
      }
      return _ParsedSuccess(reminder: reminder);
    case RichChatOperation.getScheduledChatMessages:
      final roomToken = request.roomToken;
      if (roomToken == null) {
        _responseFailure(r'$.request.roomToken');
      }
      final values = _list(data, r'$.ocs.data', maximum: 10000);
      final scheduledMessages = values
          .map(
            (value) =>
                RichChatScheduledMessage.fromJson(value, roomToken: roomToken),
          )
          .toList(growable: false);
      _validateScheduleIdentities(scheduledMessages);
      return _ParsedSuccess(scheduledMessages: scheduledMessages);
    case RichChatOperation.scheduleChatMessage:
    case RichChatOperation.editScheduledChatMessage:
      final roomToken = request.roomToken;
      if (roomToken == null) {
        _responseFailure(r'$.request.roomToken');
      }
      final scheduled = RichChatScheduledMessage.fromJson(
        data,
        roomToken: roomToken,
      );
      if (request.operation == RichChatOperation.editScheduledChatMessage &&
          scheduled.scheduleId != request.scheduleId) {
        _responseFailure(r'$.ocs.data.id');
      }
      return _ParsedSuccess(
        scheduledMessages: <RichChatScheduledMessage>[scheduled],
      );
  }
}

void _validateThreadBinding(
  RichChatRequest request,
  Iterable<RichChatThread> threads,
) {
  final expectedThreadId = switch (request.operation) {
    RichChatOperation.getThread ||
    RichChatOperation.renameThread => request.threadId,
    RichChatOperation.setThreadNotificationLevel => request.messageId,
    _ => null,
  };
  final identities = <(Object, int)>{};
  for (final thread in threads) {
    if ((request.roomToken != null && thread.roomToken != request.roomToken) ||
        (expectedThreadId != null && thread.threadId != expectedThreadId) ||
        !identities.add((thread.roomToken, thread.threadId))) {
      _responseFailure(r'$.ocs.data.thread');
    }
  }
}

void _validateScheduleIdentities(
  Iterable<RichChatScheduledMessage> scheduledMessages,
) {
  final identities = <Object>{};
  for (final message in scheduledMessages) {
    if (!identities.add(message.scheduleId)) {
      _responseFailure(r'$.ocs.data.id');
    }
  }
}

List<Object?> _list(Object? value, String path, {required int maximum}) {
  final result = requireList(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidRichChatResponse,
  );
  if (result.length > maximum) {
    _responseFailure(path);
  }
  return result;
}

void _requireEmpty(Object? data) {
  if (data == null) {
    return;
  }
  final list = requireList(
    data,
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidRichChatResponse,
  );
  if (list.isNotEmpty) {
    _responseFailure(r'$.ocs.data');
  }
}

final class _ParsedSuccess {
  const _ParsedSuccess({
    this.mentions = const [],
    this.threads = const [],
    this.reactionAggregate,
    this.messageMutation,
    this.reminder,
    this.scheduledMessages = const [],
  });

  final Iterable<RichChatMentionSuggestion> mentions;
  final Iterable<RichChatThread> threads;
  final RichChatReactionAggregate? reactionAggregate;
  final ChatMessage? messageMutation;
  final RichChatReminder? reminder;
  final Iterable<RichChatScheduledMessage> scheduledMessages;
}

Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidRichChatResponse, path);
