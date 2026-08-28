import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';

const String textSendReplayContractRevision =
    'talk-chat-text-send-f2958bb-f9b9e947-r2';

enum ChatAccountLane { ready, reauthenticationRequired }

enum TextSendOutboxState {
  queued,
  sending,
  retryable,
  awaitingConfirmation,
  failed,
  completed,
}

final class ChatBlock {
  ChatBlock({required this.start, required this.end}) {
    if (start.compareTo(end) > 0) {
      _stateFailure(r'$.blocks');
    }
  }

  final ChatCursor start;
  final ChatCursor end;

  bool contains(ChatCursor cursor) =>
      start.compareTo(cursor) <= 0 && end.compareTo(cursor) >= 0;

  @override
  bool operator ==(Object other) =>
      other is ChatBlock && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ChatBlock(<redacted>)';
}

final class ChatScopeKey {
  const ChatScopeKey({required this.roomToken, required this.threadId});

  final ConversationToken roomToken;
  final int? threadId;

  @override
  bool operator ==(Object other) =>
      other is ChatScopeKey &&
      other.roomToken == roomToken &&
      other.threadId == threadId;

  @override
  int get hashCode => Object.hash(roomToken, threadId);

  @override
  String toString() =>
      'ChatScopeKey(room: <redacted>, threadScoped: ${threadId != null})';
}

final class ChatScopeState {
  ChatScopeState({
    required Iterable<int> messageIds,
    required this.historyCursor,
    required this.futureCursor,
    required this.lastCommonRead,
    required this.lastReadMessage,
    required this.unreadMessages,
    required this.hasHistory,
    required this.futureConverged,
    required Iterable<ChatBlock> blocks,
  }) : messageIds = List.unmodifiable(messageIds),
       blocks = List.unmodifiable(blocks) {
    _validate();
  }

  final List<int> messageIds;
  final ChatCursor historyCursor;
  final ChatCursor futureCursor;
  final ChatCursor? lastCommonRead;
  final int lastReadMessage;
  final int unreadMessages;
  final bool hasHistory;
  final bool futureConverged;
  final List<ChatBlock> blocks;

  ChatScopeState copyWith({
    Iterable<int>? messageIds,
    ChatCursor? historyCursor,
    ChatCursor? futureCursor,
    Object? lastCommonRead = _unchanged,
    int? lastReadMessage,
    int? unreadMessages,
    bool? hasHistory,
    bool? futureConverged,
    Iterable<ChatBlock>? blocks,
  }) => ChatScopeState(
    messageIds: messageIds ?? this.messageIds,
    historyCursor: historyCursor ?? this.historyCursor,
    futureCursor: futureCursor ?? this.futureCursor,
    lastCommonRead: identical(lastCommonRead, _unchanged)
        ? this.lastCommonRead
        : lastCommonRead as ChatCursor?,
    lastReadMessage: lastReadMessage ?? this.lastReadMessage,
    unreadMessages: unreadMessages ?? this.unreadMessages,
    hasHistory: hasHistory ?? this.hasHistory,
    futureConverged: futureConverged ?? this.futureConverged,
    blocks: blocks ?? this.blocks,
  );

  void _validate() {
    if (historyCursor.compareTo(futureCursor) > 0 ||
        lastReadMessage < -2 ||
        unreadMessages < 0 ||
        blocks.isEmpty) {
      _stateFailure(r'$.scopes');
    }
    var previousId = 0;
    for (final messageId in messageIds) {
      if (messageId < 1 || messageId <= previousId) {
        _stateFailure(r'$.scopes.messageIds');
      }
      previousId = messageId;
    }
    ChatBlock? previousBlock;
    for (final block in blocks) {
      if (previousBlock != null &&
          previousBlock.end.compareTo(block.start) >= 0) {
        _stateFailure(r'$.scopes.blocks');
      }
      previousBlock = block;
    }
    if (blocks.first.start != historyCursor ||
        blocks.last.end != futureCursor) {
      _stateFailure(r'$.scopes.blocks');
    }
    for (final messageId in messageIds) {
      final cursor = ChatCursor.parse(
        messageId.toString(),
        code: TalkProtocolErrorCode.invalidChatState,
      );
      if (!blocks.any((block) => block.contains(cursor))) {
        _stateFailure(r'$.scopes.messageIds');
      }
    }
  }

  @override
  String toString() =>
      'ChatScopeState(messageCount: ${messageIds.length}, '
      'blockCount: ${blocks.length}, hasHistory: $hasHistory, '
      'futureConverged: $futureConverged)';
}

final class TextSendOutboxOperation {
  TextSendOutboxOperation({
    required this.operationId,
    required this.roomToken,
    required this.referenceId,
    required this.message,
    required this.replayContractRevision,
    required this.enqueueSequence,
    required this.state,
    required this.attemptCount,
    required Iterable<int> messageIds,
    required this.duplicateRiskAcknowledged,
    required this.errorClass,
    required this.nextAttemptAt,
    required this.replyTo,
    required this.threadId,
    required this.replyToToken,
    required this.parentRoomToken,
    this.silent = false,
  }) : messageIds = List.unmodifiable(messageIds) {
    _validate();
  }

  final ChatOperationId operationId;
  final ConversationToken roomToken;
  final ChatReferenceId referenceId;
  final String message;
  final String replayContractRevision;
  final int enqueueSequence;
  final TextSendOutboxState state;
  final int attemptCount;
  final List<int> messageIds;
  final bool duplicateRiskAcknowledged;
  final String? errorClass;
  final int? nextAttemptAt;
  final int? replyTo;
  final int? threadId;
  final ConversationToken? replyToToken;
  final ConversationToken? parentRoomToken;

  /// Whether delivery must raise no notification. Survives a replay because
  /// it is stored with the operation, not held in the composer.
  final bool silent;

  TextSendOutboxOperation copyWith({
    TextSendOutboxState? state,
    int? attemptCount,
    Iterable<int>? messageIds,
    bool? duplicateRiskAcknowledged,
    Object? errorClass = _unchanged,
    Object? nextAttemptAt = _unchanged,
    int? replyTo,
    Object? replyToToken = _unchanged,
    Object? parentRoomToken = _unchanged,
  }) => TextSendOutboxOperation(
    operationId: operationId,
    roomToken: roomToken,
    referenceId: referenceId,
    message: message,
    replayContractRevision: replayContractRevision,
    enqueueSequence: enqueueSequence,
    state: state ?? this.state,
    attemptCount: attemptCount ?? this.attemptCount,
    messageIds: messageIds ?? this.messageIds,
    duplicateRiskAcknowledged:
        duplicateRiskAcknowledged ?? this.duplicateRiskAcknowledged,
    errorClass: identical(errorClass, _unchanged)
        ? this.errorClass
        : errorClass as String?,
    nextAttemptAt: identical(nextAttemptAt, _unchanged)
        ? this.nextAttemptAt
        : nextAttemptAt as int?,
    replyTo: replyTo ?? this.replyTo,
    threadId: threadId,
    silent: silent,
    replyToToken: identical(replyToToken, _unchanged)
        ? this.replyToToken
        : replyToToken as ConversationToken?,
    parentRoomToken: identical(parentRoomToken, _unchanged)
        ? this.parentRoomToken
        : parentRoomToken as ConversationToken?,
  );

  void _validate() {
    if (message.trim().isEmpty ||
        replayContractRevision.isEmpty ||
        enqueueSequence < 1 ||
        attemptCount < 0 ||
        (nextAttemptAt != null && nextAttemptAt! < 0)) {
      _outboxFailure(r'$.operations');
    }
    var previousId = 0;
    for (final messageId in messageIds) {
      if (messageId < 1 || messageId <= previousId) {
        _outboxFailure(r'$.operations.messageIds');
      }
      previousId = messageId;
    }
    if (threadId != null && (threadId! < 1 || replyTo != null)) {
      _outboxFailure(r'$.operations.threadId');
    }
    if (replyTo == null) {
      if (replyToToken != null || parentRoomToken != null) {
        _outboxFailure(r'$.operations.replyTo');
      }
    } else if (replyTo! < 1 || parentRoomToken == null) {
      _outboxFailure(r'$.operations.replyTo');
    }
    if (replyToToken != null && replyToToken != parentRoomToken) {
      _outboxFailure(r'$.operations.replyToToken');
    }
    if (replyTo != null) {
      final crossRoom = parentRoomToken != roomToken;
      if (crossRoom != (replyToToken != null)) {
        _outboxFailure(r'$.operations.replyToToken');
      }
    }
    if (<TextSendOutboxState>{
          TextSendOutboxState.sending,
          TextSendOutboxState.retryable,
          TextSendOutboxState.awaitingConfirmation,
        }.contains(state) &&
        attemptCount < 1) {
      _outboxFailure(r'$.operations.attemptCount');
    }
    if (state == TextSendOutboxState.completed && messageIds.isEmpty) {
      _outboxFailure(r'$.operations.messageIds');
    }
    if (nextAttemptAt != null && state != TextSendOutboxState.retryable) {
      _outboxFailure(r'$.operations.nextAttemptAt');
    }
  }

  @override
  String toString() =>
      'TextSendOutboxOperation(state: ${state.name}, '
      'attemptCount: $attemptCount, namedThread: ${threadId != null}, '
      'message: <redacted>, '
      'referenceId: <redacted>)';
}

final class ChatAccountState {
  ChatAccountState({
    required this.accountId,
    required this.server,
    required this.lane,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required Map<ChatScopeKey, ChatScopeState> scopes,
    required Map<ChatOperationId, TextSendOutboxOperation> operations,
  }) : scopes = UnmodifiableMapView(Map.of(scopes)),
       operations = UnmodifiableMapView(Map.of(operations)) {
    if (credentialGeneration < 1 ||
        capabilityGeneration < 1 ||
        scopes.keys.any((key) => key.threadId != null && key.threadId! < 1)) {
      _stateFailure(r'$.accounts');
    }
    for (final entry in operations.entries) {
      if (entry.key != entry.value.operationId) {
        _stateFailure(r'$.accounts.operations');
      }
    }
    final references = <ChatReferenceId>{};
    final sequences = <(ConversationToken, int)>{};
    final sendingRooms = <ConversationToken>{};
    for (final operation in operations.values) {
      if (!references.add(operation.referenceId) ||
          !sequences.add((operation.roomToken, operation.enqueueSequence)) ||
          (operation.state == TextSendOutboxState.sending &&
              !sendingRooms.add(operation.roomToken))) {
        _stateFailure(r'$.accounts.operations');
      }
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final ChatAccountLane lane;
  final int credentialGeneration;
  final int capabilityGeneration;
  final Map<ChatScopeKey, ChatScopeState> scopes;
  final Map<ChatOperationId, TextSendOutboxOperation> operations;

  ChatAccountState copyWith({
    ChatAccountLane? lane,
    int? credentialGeneration,
    int? capabilityGeneration,
    Map<ChatScopeKey, ChatScopeState>? scopes,
    Map<ChatOperationId, TextSendOutboxOperation>? operations,
  }) => ChatAccountState(
    accountId: accountId,
    server: server,
    lane: lane ?? this.lane,
    credentialGeneration: credentialGeneration ?? this.credentialGeneration,
    capabilityGeneration: capabilityGeneration ?? this.capabilityGeneration,
    scopes: scopes ?? this.scopes,
    operations: operations ?? this.operations,
  );

  @override
  String toString() =>
      'ChatAccountState(lane: ${lane.name}, scopeCount: ${scopes.length}, '
      'operationCount: ${operations.length})';
}

final class ChatRuntimeSnapshot {
  ChatRuntimeSnapshot({required Map<AccountId, ChatAccountState> accounts})
    : accounts = UnmodifiableMapView(Map.of(accounts)) {
    for (final entry in accounts.entries) {
      if (entry.key != entry.value.accountId) {
        _stateFailure(r'$.accounts');
      }
    }
  }

  final Map<AccountId, ChatAccountState> accounts;

  ChatRuntimeSnapshot replaceAccount(ChatAccountState account) {
    final result = Map<AccountId, ChatAccountState>.of(accounts);
    result[account.accountId] = account;
    return ChatRuntimeSnapshot(accounts: result);
  }

  @override
  String toString() => 'ChatRuntimeSnapshot(accountCount: ${accounts.length})';
}

const Object _unchanged = Object();

Never _outboxFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidChatOutbox, path);

Never _stateFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidChatState, path);
