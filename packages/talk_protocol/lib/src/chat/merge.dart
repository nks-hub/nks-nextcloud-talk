import '../identifiers.dart';
import '../protocol_exception.dart';
import 'identifiers.dart';
import 'models.dart';
import 'outbox.dart';
import 'request.dart';
import 'response.dart';
import 'state.dart';

enum ChatMergeOutcome {
  applied,
  commonReadUpdated,
  historyExhausted,
  converged,
  readApplied,
  unreadApplied,
  reauthenticationRequired,
  rejected,
}

final class ChatMergePlan {
  ChatMergePlan._(
    this._source,
    this._candidate, {
    required this.messageUpserts,
  });

  final ChatRuntimeSnapshot _source;
  final ChatRuntimeSnapshot _candidate;
  final List<ChatMessage> messageUpserts;
  bool _consumed = false;

  ChatRuntimeSnapshot commit(ChatRuntimeSnapshot current) {
    _consume(current);
    return _candidate;
  }

  ChatRuntimeSnapshot discard(ChatRuntimeSnapshot current) {
    _consume(current);
    return current;
  }

  void _consume(ChatRuntimeSnapshot current) {
    if (_consumed || !identical(current, _source)) {
      protocolFailure(TalkProtocolErrorCode.invalidChatMerge, r'$.mergePlan');
    }
    _consumed = true;
  }

  @override
  String toString() =>
      'ChatMergePlan(messageUpsertCount: ${messageUpserts.length})';
}

final class ChatMergeResult {
  const ChatMergeResult._({required this.outcome, required this.plan});

  final ChatMergeOutcome outcome;
  final ChatMergePlan? plan;

  bool get canCommit => plan != null;

  @override
  String toString() => 'ChatMergeResult(outcome: ${outcome.name})';
}

ChatMergeResult planChatGetMerge(
  ChatRuntimeSnapshot snapshot,
  ChatGetResponse response,
) {
  final binding = _bind(
    snapshot,
    response.request.accountId,
    response.request.server,
  );
  if (binding == null) {
    return _rejected;
  }
  if (response.classification ==
      ChatGetClassification.reauthenticationRequired) {
    final account = binding.account.copyWith(
      lane: ChatAccountLane.reauthenticationRequired,
    );
    return _planned(
      snapshot,
      snapshot.replaceAccount(account),
      ChatMergeOutcome.reauthenticationRequired,
    );
  }
  if (<ChatGetClassification>{
    ChatGetClassification.ocsError,
    ChatGetClassification.threadNotFound,
    ChatGetClassification.transientError,
  }.contains(response.classification)) {
    return _rejected;
  }

  final key = ChatScopeKey(
    roomToken: response.request.roomToken,
    threadId: response.request.threadId,
  );
  final scope = binding.account.scopes[key];
  if (scope == null) {
    return _rejected;
  }
  final anchor = response.request.direction == ChatFetchDirection.history
      ? scope.historyCursor
      : scope.futureCursor;
  if (anchor != response.request.cursor) {
    return _rejected;
  }

  ChatScopeState candidateScope;
  ChatMergeOutcome outcome;
  switch (response.classification) {
    case ChatGetClassification.messages:
    case ChatGetClassification.invisibleCursorAdvance:
      final cursor = response.cursor!;
      final ids = <int>{...scope.messageIds};
      ids.addAll(response.messages.map((message) => message.messageId));
      final sortedIds = ids.toList()..sort();
      final newBlock = response.request.direction == ChatFetchDirection.history
          ? ChatBlock(start: cursor, end: anchor)
          : ChatBlock(start: anchor, end: cursor);
      candidateScope = scope.copyWith(
        messageIds: sortedIds,
        historyCursor: response.request.direction == ChatFetchDirection.history
            ? cursor
            : null,
        futureCursor: response.request.direction == ChatFetchDirection.future
            ? cursor
            : null,
        lastCommonRead: response.lastCommonRead,
        futureConverged: response.request.direction == ChatFetchDirection.future
            ? false
            : null,
        blocks: mergeChatBlocks(<ChatBlock>[...scope.blocks, newBlock]),
      );
      outcome = ChatMergeOutcome.applied;
    case ChatGetClassification.commonReadOnly:
      candidateScope = scope.copyWith(lastCommonRead: response.lastCommonRead);
      outcome = ChatMergeOutcome.commonReadUpdated;
    case ChatGetClassification.notModified:
      if (response.request.direction == ChatFetchDirection.history) {
        candidateScope = scope.copyWith(hasHistory: false);
        outcome = ChatMergeOutcome.historyExhausted;
      } else {
        candidateScope = scope.copyWith(futureConverged: true);
        outcome = ChatMergeOutcome.converged;
      }
    case ChatGetClassification.reauthenticationRequired:
    case ChatGetClassification.threadNotFound:
    case ChatGetClassification.transientError:
    case ChatGetClassification.ocsError:
      return _rejected;
  }

  final scopes = Map<ChatScopeKey, ChatScopeState>.of(binding.account.scopes);
  scopes[key] = candidateScope;
  var candidateAccount = binding.account.copyWith(scopes: scopes);
  candidateAccount = reconcileTextSendOperations(
    candidateAccount,
    response.messages.map(
      (message) => ChatMessageConfirmation.fromMessage(
        message,
        accountId: response.request.accountId,
        server: response.request.server,
      ),
    ),
  );
  return _planned(
    snapshot,
    snapshot.replaceAccount(candidateAccount),
    outcome,
    messageUpserts: response.messages,
  );
}

ChatMergeResult planChatReadMerge(
  ChatRuntimeSnapshot snapshot,
  ChatReadResponse response,
) {
  final request = response.request;
  final binding = _bind(snapshot, request.accountId, request.server);
  if (binding == null) {
    return _rejected;
  }
  if (response.classification ==
      ChatReadClassification.reauthenticationRequired) {
    return _planned(
      snapshot,
      snapshot.replaceAccount(
        binding.account.copyWith(
          lane: ChatAccountLane.reauthenticationRequired,
        ),
      ),
      ChatMergeOutcome.reauthenticationRequired,
    );
  }
  if (response.classification == ChatReadClassification.ocsError) {
    return _rejected;
  }
  final key = ChatScopeKey(roomToken: request.roomToken, threadId: null);
  final scope = binding.account.scopes[key];
  final marker = response.marker;
  if (scope == null || marker == null) {
    return _rejected;
  }
  final candidateScope = scope.copyWith(
    lastCommonRead: ChatCursor.parse(
      marker.lastCommonReadMessage.toString(),
      code: TalkProtocolErrorCode.invalidChatMerge,
    ),
    lastReadMessage: marker.lastReadMessage,
    unreadMessages: marker.unreadMessages,
  );
  final scopes = Map<ChatScopeKey, ChatScopeState>.of(binding.account.scopes);
  scopes[key] = candidateScope;
  return _planned(
    snapshot,
    snapshot.replaceAccount(binding.account.copyWith(scopes: scopes)),
    response.classification == ChatReadClassification.readConfirmed
        ? ChatMergeOutcome.readApplied
        : ChatMergeOutcome.unreadApplied,
  );
}

List<ChatBlock> mergeChatBlocks(Iterable<ChatBlock> blocks) {
  final sorted = blocks.toList()
    ..sort((left, right) => left.start.compareTo(right.start));
  if (sorted.isEmpty) {
    protocolFailure(TalkProtocolErrorCode.invalidChatState, r'$.blocks');
  }
  final result = <ChatBlock>[];
  var current = sorted.first;
  for (final next in sorted.skip(1)) {
    final overlaps = next.start.compareTo(current.end) <= 0;
    final adjacent = next.start.value == _incrementDecimal(current.end.value);
    if (overlaps || adjacent) {
      if (next.end.compareTo(current.end) > 0) {
        current = ChatBlock(start: current.start, end: next.end);
      }
      continue;
    }
    result.add(current);
    current = next;
  }
  result.add(current);
  return List.unmodifiable(result);
}

ChatMergeResult _planned(
  ChatRuntimeSnapshot source,
  ChatRuntimeSnapshot candidate,
  ChatMergeOutcome outcome, {
  Iterable<ChatMessage> messageUpserts = const [],
}) => ChatMergeResult._(
  outcome: outcome,
  plan: ChatMergePlan._(
    source,
    candidate,
    messageUpserts: List.unmodifiable(messageUpserts),
  ),
);

_AccountBinding? _bind(
  ChatRuntimeSnapshot snapshot,
  AccountId accountId,
  Object server,
) {
  final account = snapshot.accounts[accountId];
  if (account == null || account.server != server) {
    return null;
  }
  return _AccountBinding(account);
}

String _incrementDecimal(String value) {
  final digits = value.codeUnits.toList();
  var carry = 1;
  for (var index = digits.length - 1; index >= 0 && carry == 1; index--) {
    if (digits[index] == 0x39) {
      digits[index] = 0x30;
    } else {
      digits[index]++;
      carry = 0;
    }
  }
  if (carry == 1) {
    digits.insert(0, 0x31);
  }
  return String.fromCharCodes(digits);
}

const ChatMergeResult _rejected = ChatMergeResult._(
  outcome: ChatMergeOutcome.rejected,
  plan: null,
);

final class _AccountBinding {
  const _AccountBinding(this.account);

  final ChatAccountState account;
}
