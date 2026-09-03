import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';
import 'outbox.dart';
import 'profile.dart';
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

  /// The response answered a cursor the scope has already moved past, so it
  /// carries no new authority. Discarding it is correct and is not an error.
  stale,

  /// The room is in lobby for this participant (HTTP 412). Nothing arrives
  /// and nothing is wrong; the scope stays exactly as it was.
  lobby,
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
  if (response.classification == ChatGetClassification.lobby) {
    return _lobby;
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
    // A concurrent writer, for example an attachment confirmation, already
    // advanced this cursor while the request was in flight. Applying the
    // answer would reopen a closed block, so it is discarded without error.
    return _stale;
  }

  ChatScopeState candidateScope;
  ChatMergeOutcome outcome;
  final lastCommonRead = response.request.profile.commonReadStatus
      ? response.lastCommonRead ?? scope.lastCommonRead
      : null;
  switch (response.classification) {
    case ChatGetClassification.messages:
    case ChatGetClassification.invisibleCursorAdvance:
      final cursor = response.cursor!;
      final ids = <int>{...scope.messageIds};
      ids.addAll(response.messages.map((message) => message.messageId));
      final sortedIds = ids.toList()..sort();
      final history = response.request.direction == ChatFetchDirection.history;
      // Anchor `0` is a scope that has never seen a message (a federated
      // room's preview carries no id). Its first history page is the newest
      // page: it becomes the only block, and the future cursor moves to the
      // newest id so polling continues from there instead of from nothing.
      final openAnchor = history && anchor.value == '0';
      final newest = openAnchor && sortedIds.isNotEmpty
          ? ChatCursor.parse(
              sortedIds.last.toString(),
              code: TalkProtocolErrorCode.invalidChatMerge,
            )
          : cursor;
      final newBlock = history
          ? ChatBlock(start: cursor, end: openAnchor ? newest : anchor)
          : ChatBlock(start: anchor, end: cursor);
      final keptBlocks = openAnchor
          ? scope.blocks.where((block) => block.end.value != '0')
          : scope.blocks;
      candidateScope = scope.copyWith(
        messageIds: sortedIds,
        historyCursor: history ? cursor : null,
        futureCursor: openAnchor ? newest : (history ? null : cursor),
        lastCommonRead: lastCommonRead,
        futureConverged: history ? null : false,
        blocks: mergeChatBlocks(<ChatBlock>[...keptBlocks, newBlock]),
      );
      outcome = ChatMergeOutcome.applied;
    case ChatGetClassification.commonReadOnly:
      candidateScope = scope.copyWith(lastCommonRead: lastCommonRead);
      outcome = ChatMergeOutcome.commonReadUpdated;
    case ChatGetClassification.notModified:
      if (response.request.direction == ChatFetchDirection.history) {
        candidateScope = scope.copyWith(
          lastCommonRead: lastCommonRead,
          hasHistory: false,
        );
        outcome = ChatMergeOutcome.historyExhausted;
      } else {
        candidateScope = scope.copyWith(
          lastCommonRead: lastCommonRead,
          futureConverged: true,
        );
        outcome = ChatMergeOutcome.converged;
      }
    case ChatGetClassification.reauthenticationRequired:
    case ChatGetClassification.threadNotFound:
    case ChatGetClassification.lobby:
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
  // `[0, 0]` is the block of a scope that has never seen a message. Once a
  // real range exists it is not a range of anything and would only drag the
  // history cursor back to zero wherever blocks are recombined.
  final all = blocks.toList();
  final real = all.where((block) => block.end.value != '0').toList();
  final sorted = (real.isEmpty ? all : real)
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

enum ChatForegroundPollPhase {
  catchUpRequired,
  longPollRequired,
  requestInFlight,
  waitingToRetry,
  reauthenticationRequired,
  stopped,
}

enum ChatForegroundPollOutcome {
  responseApplied,
  retryScheduled,
  reauthenticationRequired,
  terminalFailure,
}

final class ChatForegroundPollSession {
  const ChatForegroundPollSession._({
    required this.accountId,
    required this.server,
    required this.scopeKey,
    required this.profile,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.phase,
    required this.initialCatchUpCompleted,
    required this.consecutiveFailures,
    required this.nextAttemptAtMilliseconds,
    required this.pendingRequest,
  });

  final AccountId accountId;
  final ServerBase server;
  final ChatScopeKey scopeKey;
  final ChatCapabilityProfile profile;
  final int credentialGeneration;
  final int capabilityGeneration;
  final ChatForegroundPollPhase phase;
  final bool initialCatchUpCompleted;
  final int consecutiveFailures;
  final int? nextAttemptAtMilliseconds;
  final ChatFetchRequest? pendingRequest;

  ChatForegroundPollSession _copyWith({
    required ChatForegroundPollPhase phase,
    required bool initialCatchUpCompleted,
    required int consecutiveFailures,
    required int? nextAttemptAtMilliseconds,
    required ChatFetchRequest? pendingRequest,
  }) => ChatForegroundPollSession._(
    accountId: accountId,
    server: server,
    scopeKey: scopeKey,
    profile: profile,
    credentialGeneration: credentialGeneration,
    capabilityGeneration: capabilityGeneration,
    phase: phase,
    initialCatchUpCompleted: initialCatchUpCompleted,
    consecutiveFailures: consecutiveFailures,
    nextAttemptAtMilliseconds: nextAttemptAtMilliseconds,
    pendingRequest: pendingRequest,
  );

  @override
  String toString() =>
      'ChatForegroundPollSession(phase: ${phase.name}, '
      'threadScoped: ${scopeKey.threadId != null}, sensitive: <redacted>)';
}

final class ChatForegroundPollRequestPlan {
  const ChatForegroundPollRequestPlan._({
    required this._source,
    required this.request,
    required this._candidate,
  });

  final ChatForegroundPollSession _source;
  final ChatFetchRequest request;
  final ChatForegroundPollSession _candidate;

  ChatForegroundPollSession commit(ChatForegroundPollSession current) {
    if (!identical(current, _source)) {
      _pollFailure(r'$.foregroundPoll.requestPlan');
    }
    return _candidate;
  }
}

final class ChatForegroundPollCommit {
  const ChatForegroundPollCommit({
    required this.snapshot,
    required this.session,
  });

  final ChatRuntimeSnapshot snapshot;
  final ChatForegroundPollSession session;
}

final class ChatForegroundPollCompletionPlan {
  const ChatForegroundPollCompletionPlan._({
    required this._sourceSnapshot,
    required this._sourceSession,
    required this.outcome,
    required this._mergePlan,
    required this._candidateSession,
  });

  final ChatRuntimeSnapshot _sourceSnapshot;
  final ChatForegroundPollSession _sourceSession;
  final ChatMergePlan? _mergePlan;
  final ChatForegroundPollSession _candidateSession;
  final ChatForegroundPollOutcome outcome;

  ChatForegroundPollCommit commit(
    ChatRuntimeSnapshot currentSnapshot,
    ChatForegroundPollSession currentSession,
  ) {
    if (!identical(currentSnapshot, _sourceSnapshot) ||
        !identical(currentSession, _sourceSession)) {
      _pollFailure(r'$.foregroundPoll.completionPlan');
    }
    return ChatForegroundPollCommit(
      snapshot: _mergePlan?.commit(currentSnapshot) ?? currentSnapshot,
      session: _candidateSession,
    );
  }
}

ChatForegroundPollSession startChatForegroundPoll(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ServerBase server,
  required ConversationToken roomToken,
  required int? threadId,
  required ChatCapabilityProfile profile,
}) {
  final key = ChatScopeKey(roomToken: roomToken, threadId: threadId);
  final account = snapshot.accounts[accountId];
  if (account == null ||
      account.server != server ||
      account.lane != ChatAccountLane.ready ||
      !account.scopes.containsKey(key) ||
      !profile.read ||
      (threadId != null && (threadId < 1 || !profile.threadFetch))) {
    _pollFailure(r'$.foregroundPoll.binding');
  }
  return ChatForegroundPollSession._(
    accountId: accountId,
    server: server,
    scopeKey: key,
    profile: profile,
    credentialGeneration: account.credentialGeneration,
    capabilityGeneration: account.capabilityGeneration,
    phase: ChatForegroundPollPhase.catchUpRequired,
    initialCatchUpCompleted: false,
    consecutiveFailures: 0,
    nextAttemptAtMilliseconds: null,
    pendingRequest: null,
  );
}

ChatForegroundPollRequestPlan? planNextChatForegroundPoll(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session, {
  required ChatRequestId requestId,
  required int nowMilliseconds,
}) {
  if (nowMilliseconds < 0) {
    _pollFailure(r'$.foregroundPoll.now');
  }
  if (session.phase == ChatForegroundPollPhase.requestInFlight ||
      session.phase == ChatForegroundPollPhase.reauthenticationRequired ||
      session.phase == ChatForegroundPollPhase.stopped) {
    return null;
  }
  final binding = _requirePollBinding(snapshot, session);
  if (session.phase == ChatForegroundPollPhase.waitingToRetry &&
      nowMilliseconds < session.nextAttemptAtMilliseconds!) {
    return null;
  }
  final isInitialCatchUp = !session.initialCatchUpCompleted;
  final request = ChatFetchRequest(
    accountId: session.accountId,
    requestId: requestId,
    server: session.server,
    roomToken: session.scopeKey.roomToken,
    profile: session.profile,
    direction: ChatFetchDirection.future,
    cursor: binding.scope.futureCursor,
    lastCommonRead: binding.scope.lastCommonRead ?? ChatCursor.parse('0'),
    limit: 200,
    includeLastKnown: false,
    timeoutSeconds: isInitialCatchUp ? 0 : 30,
    interactive: true,
    threadId: session.scopeKey.threadId,
    futureConverged: !isInitialCatchUp,
  );
  return ChatForegroundPollRequestPlan._(
    source: session,
    request: request,
    candidate: session._copyWith(
      phase: ChatForegroundPollPhase.requestInFlight,
      initialCatchUpCompleted: session.initialCatchUpCompleted,
      consecutiveFailures: session.consecutiveFailures,
      nextAttemptAtMilliseconds: null,
      pendingRequest: request,
    ),
  );
}

ChatForegroundPollCompletionPlan completeChatForegroundPollHttp(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session, {
  required ChatGetResponse response,
  required int nowMilliseconds,
  required int jitterPermille,
}) {
  _requirePendingPollBinding(snapshot, session, response.request);
  final merge = planChatGetMerge(snapshot, response);
  return switch (response.classification) {
    ChatGetClassification.messages ||
    ChatGetClassification.invisibleCursorAdvance ||
    ChatGetClassification.commonReadOnly ||
    ChatGetClassification.notModified => _successfulPollCompletion(
      snapshot,
      session,
      merge,
    ),
    ChatGetClassification.reauthenticationRequired =>
      _reauthenticationPollCompletion(snapshot, session, merge),
    // A lobby is waited out like a transient failure: the room will open
    // when a moderator says so, and the backoff keeps the poll polite.
    ChatGetClassification.transientError ||
    ChatGetClassification.lobby => _retryPollCompletion(
      snapshot,
      session,
      nowMilliseconds: nowMilliseconds,
      jitterPermille: jitterPermille,
    ),
    ChatGetClassification.threadNotFound || ChatGetClassification.ocsError =>
      _terminalPollCompletion(snapshot, session),
  };
}

ChatForegroundPollCompletionPlan completeChatForegroundPollTransportFailure(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session, {
  required int nowMilliseconds,
  required int jitterPermille,
}) {
  _requirePendingPollBinding(snapshot, session, session.pendingRequest);
  return _retryPollCompletion(
    snapshot,
    session,
    nowMilliseconds: nowMilliseconds,
    jitterPermille: jitterPermille,
  );
}

ChatForegroundPollSession cancelChatForegroundPoll(
  ChatForegroundPollSession session,
) {
  if (session.phase == ChatForegroundPollPhase.stopped) {
    return session;
  }
  return session._copyWith(
    phase: ChatForegroundPollPhase.stopped,
    initialCatchUpCompleted: session.initialCatchUpCompleted,
    consecutiveFailures: 0,
    nextAttemptAtMilliseconds: null,
    pendingRequest: null,
  );
}

int chatForegroundPollBackoffMilliseconds(
  int consecutiveFailures, {
  required int jitterPermille,
}) {
  if (consecutiveFailures < 1 || jitterPermille < 0 || jitterPermille > 1000) {
    _pollFailure(r'$.foregroundPoll.backoff');
  }
  var base = 1000;
  var remainingDoublings = consecutiveFailures - 1;
  while (remainingDoublings > 0 && base < 30000) {
    base *= 2;
    if (base > 30000) {
      base = 30000;
    }
    remainingDoublings--;
  }
  final factorPermille = 800 + ((jitterPermille * 400) ~/ 1000);
  return (base * factorPermille) ~/ 1000;
}

ChatForegroundPollCompletionPlan _successfulPollCompletion(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session,
  ChatMergeResult merge,
) {
  if (!merge.canCommit) {
    _pollFailure(r'$.foregroundPoll.response');
  }
  return ChatForegroundPollCompletionPlan._(
    sourceSnapshot: snapshot,
    sourceSession: session,
    outcome: ChatForegroundPollOutcome.responseApplied,
    mergePlan: merge.plan,
    candidateSession: session._copyWith(
      phase: ChatForegroundPollPhase.longPollRequired,
      initialCatchUpCompleted: true,
      consecutiveFailures: 0,
      nextAttemptAtMilliseconds: null,
      pendingRequest: null,
    ),
  );
}

ChatForegroundPollCompletionPlan _reauthenticationPollCompletion(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session,
  ChatMergeResult merge,
) {
  if (!merge.canCommit ||
      merge.outcome != ChatMergeOutcome.reauthenticationRequired) {
    _pollFailure(r'$.foregroundPoll.response');
  }
  return ChatForegroundPollCompletionPlan._(
    sourceSnapshot: snapshot,
    sourceSession: session,
    outcome: ChatForegroundPollOutcome.reauthenticationRequired,
    mergePlan: merge.plan,
    candidateSession: session._copyWith(
      phase: ChatForegroundPollPhase.reauthenticationRequired,
      initialCatchUpCompleted: session.initialCatchUpCompleted,
      consecutiveFailures: 0,
      nextAttemptAtMilliseconds: null,
      pendingRequest: null,
    ),
  );
}

ChatForegroundPollCompletionPlan _retryPollCompletion(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session, {
  required int nowMilliseconds,
  required int jitterPermille,
}) {
  if (nowMilliseconds < 0) {
    _pollFailure(r'$.foregroundPoll.now');
  }
  final failures = session.consecutiveFailures + 1;
  final delay = chatForegroundPollBackoffMilliseconds(
    failures,
    jitterPermille: jitterPermille,
  );
  return ChatForegroundPollCompletionPlan._(
    sourceSnapshot: snapshot,
    sourceSession: session,
    outcome: ChatForegroundPollOutcome.retryScheduled,
    mergePlan: null,
    candidateSession: session._copyWith(
      phase: ChatForegroundPollPhase.waitingToRetry,
      initialCatchUpCompleted: session.initialCatchUpCompleted,
      consecutiveFailures: failures,
      nextAttemptAtMilliseconds: nowMilliseconds + delay,
      pendingRequest: null,
    ),
  );
}

ChatForegroundPollCompletionPlan _terminalPollCompletion(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session,
) => ChatForegroundPollCompletionPlan._(
  sourceSnapshot: snapshot,
  sourceSession: session,
  outcome: ChatForegroundPollOutcome.terminalFailure,
  mergePlan: null,
  candidateSession: session._copyWith(
    phase: ChatForegroundPollPhase.stopped,
    initialCatchUpCompleted: session.initialCatchUpCompleted,
    consecutiveFailures: 0,
    nextAttemptAtMilliseconds: null,
    pendingRequest: null,
  ),
);

_ChatPollBinding _requirePollBinding(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session,
) {
  final account = snapshot.accounts[session.accountId];
  final scope = account?.scopes[session.scopeKey];
  if (account == null ||
      scope == null ||
      account.server != session.server ||
      account.lane != ChatAccountLane.ready ||
      account.credentialGeneration != session.credentialGeneration ||
      account.capabilityGeneration != session.capabilityGeneration) {
    _pollFailure(r'$.foregroundPoll.binding');
  }
  return _ChatPollBinding(account: account, scope: scope);
}

void _requirePendingPollBinding(
  ChatRuntimeSnapshot snapshot,
  ChatForegroundPollSession session,
  ChatFetchRequest? request,
) {
  final pending = session.pendingRequest;
  if (session.phase != ChatForegroundPollPhase.requestInFlight ||
      pending == null ||
      request == null ||
      !identical(pending, request)) {
    _pollFailure(r'$.foregroundPoll.pendingRequest');
  }
  final binding = _requirePollBinding(snapshot, session);
  if (pending.accountId != session.accountId ||
      pending.server != session.server ||
      pending.roomToken != session.scopeKey.roomToken ||
      pending.threadId != session.scopeKey.threadId ||
      pending.direction != ChatFetchDirection.future ||
      pending.cursor != binding.scope.futureCursor) {
    _pollFailure(r'$.foregroundPoll.binding');
  }
}

final class _ChatPollBinding {
  const _ChatPollBinding({required this.account, required this.scope});

  final ChatAccountState account;
  final ChatScopeState scope;
}

Never _pollFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidChatMerge, path);

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

const ChatMergeResult _stale = ChatMergeResult._(
  outcome: ChatMergeOutcome.stale,
  plan: null,
);

const ChatMergeResult _lobby = ChatMergeResult._(
  outcome: ChatMergeOutcome.lobby,
  plan: null,
);

final class _AccountBinding {
  const _AccountBinding(this.account);

  final ChatAccountState account;
}
