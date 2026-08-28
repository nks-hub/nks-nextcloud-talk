import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'confirmation_scope.dart';
import 'identifiers.dart';
import 'models.dart';
import 'private_reply.dart';
import 'profile.dart';
import 'response.dart';
import 'state.dart';

enum ChatOutboxOutcome {
  queued,
  sending,
  retryable,
  awaitingConfirmation,
  completed,
  failed,
  reauthenticationRequired,
  reauthenticationSucceeded,
  ambiguousMatch,
  conflictAfterCompletion,
  unchanged,
  rejected,
}

enum ChatTransportBodyState { notSent, possiblySent }

final class ChatTextSendAuthority {
  ChatTextSendAuthority({
    required this.accountId,
    required this.server,
    required this.capabilityGeneration,
    required this.profile,
    required this.replayContractRevision,
  }) {
    if (capabilityGeneration < 1 ||
        replayContractRevision.isEmpty ||
        replayContractRevision.length > 128) {
      _outboxFailure(r'$.authority');
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final int capabilityGeneration;
  final ChatCapabilityProfile profile;
  final String replayContractRevision;

  @override
  String toString() =>
      'ChatTextSendAuthority(capabilityGeneration: $capabilityGeneration, '
      'profile: $profile)';
}

final class ChatMessageConfirmation {
  const ChatMessageConfirmation({
    required this.accountId,
    required this.server,
    required this.messageId,
    required this.roomToken,
    required this.referenceId,
    required this.parentMessageId,
    required this.parentRoomToken,
    required this.parentThreadId,
    required this.parentDeleted,
    required this.replyToMessageId,
    required this.replyToRoomToken,
    required this.threadId,
  });

  factory ChatMessageConfirmation.fromMessage(
    ChatMessage message, {
    required AccountId accountId,
    required ServerBase server,
  }) {
    final scope = ChatConfirmationScope.fromMessage(message);
    return ChatMessageConfirmation(
      accountId: accountId,
      server: server,
      messageId: message.messageId,
      roomToken: message.roomToken,
      referenceId: message.referenceId,
      parentMessageId: scope.parentMessageId,
      parentRoomToken: scope.parentRoomToken,
      parentThreadId: scope.parentThreadId,
      parentDeleted: scope.parentDeleted,
      replyToMessageId: scope.replyToMessageId,
      replyToRoomToken: scope.replyToRoomToken,
      threadId: scope.threadId,
    );
  }

  final AccountId accountId;
  final ServerBase server;
  final int messageId;
  final ConversationToken roomToken;
  final String referenceId;
  final int? parentMessageId;
  final ConversationToken? parentRoomToken;
  final int? parentThreadId;
  final bool parentDeleted;
  final int? replyToMessageId;
  final String? replyToRoomToken;
  final int? threadId;

  @override
  String toString() => 'ChatMessageConfirmation(<redacted>)';
}

final class ChatOutboxPlan {
  ChatOutboxPlan._(this._source, this._candidate);

  final ChatRuntimeSnapshot _source;
  final ChatRuntimeSnapshot _candidate;
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
      protocolFailure(TalkProtocolErrorCode.invalidChatOutbox, r'$.outboxPlan');
    }
    _consumed = true;
  }

  @override
  String toString() => 'ChatOutboxPlan()';
}

final class ChatOutboxResult {
  const ChatOutboxResult._({
    required this.outcome,
    required this.operationId,
    required this.plan,
  });

  final ChatOutboxOutcome outcome;
  final ChatOperationId? operationId;
  final ChatOutboxPlan? plan;

  bool get canCommit => plan != null;

  @override
  String toString() => 'ChatOutboxResult(outcome: ${outcome.name})';
}

final class TextSendOutboxDraft {
  TextSendOutboxDraft({
    required this.operationId,
    required this.operationKind,
    required this.roomToken,
    required this.referenceId,
    required this.message,
    required this.replayContractRevision,
    required this.enqueueSequence,
    required this.replyTo,
    required this.threadId,
    required this.replyToToken,
    required this.parentRoomToken,
    this.silent = false,
    this.privateReplyEligibility,
  }) {
    if (operationKind.isEmpty ||
        operationKind.length > 128 ||
        replayContractRevision.isEmpty ||
        replayContractRevision.length > 256 ||
        enqueueSequence < 1 ||
        message.trim().isEmpty) {
      _outboxFailure(r'$.operation');
    }
    if (replyTo == null) {
      if (replyToToken != null || parentRoomToken != null) {
        _outboxFailure(r'$.operation.replyTo');
      }
    } else {
      if (replyTo! < 1 || parentRoomToken == null) {
        _outboxFailure(r'$.operation.replyTo');
      }
      final crossRoom = parentRoomToken != roomToken;
      if (crossRoom != (replyToToken != null) ||
          (replyToToken != null && replyToToken != parentRoomToken)) {
        _outboxFailure(r'$.operation.replyToToken');
      }
    }
    if (threadId != null && (threadId! < 1 || replyTo != null)) {
      _outboxFailure(r'$.operation.threadId');
    }
    if (privateReplyEligibility != null &&
        (replyTo == null || parentRoomToken == roomToken)) {
      _outboxFailure(r'$.operation.privateReplyEligibility');
    }
  }

  final ChatOperationId operationId;
  final String operationKind;
  final ConversationToken roomToken;
  final ChatReferenceId referenceId;
  final String message;
  final String replayContractRevision;
  final bool silent;
  final int enqueueSequence;
  final int? replyTo;
  final int? threadId;
  final ConversationToken? replyToToken;
  final ConversationToken? parentRoomToken;
  final PrivateReplyEligibilitySnapshot? privateReplyEligibility;

  @override
  String toString() =>
      'TextSendOutboxDraft(kind: $operationKind, message: <redacted>, '
      'referenceId: <redacted>)';
}

ChatOutboxResult admitTextSendOperation(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ChatTextSendAuthority authority,
  required TextSendOutboxDraft draft,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      account.lane != ChatAccountLane.ready ||
      !_authorityMatchesAccount(account, authority) ||
      !authority.profile.sendText ||
      draft.operationKind != 'textSend' ||
      draft.replayContractRevision != authority.replayContractRevision ||
      account.operations.containsKey(draft.operationId) ||
      account.operations.values.any(
        (operation) => operation.referenceId == draft.referenceId,
      ) ||
      account.operations.values.any(
        (operation) =>
            operation.roomToken == draft.roomToken &&
            operation.enqueueSequence >= draft.enqueueSequence,
      ) ||
      (draft.replyTo != null &&
          (draft.parentRoomToken == draft.roomToken
              ? !authority.profile.reply || draft.replyToToken != null
              : !_privateReplyAdmissionMatches(authority, draft))) ||
      (draft.threadId != null && !authority.profile.threadFetch)) {
    return _result(ChatOutboxOutcome.rejected);
  }
  final operation = TextSendOutboxOperation(
    operationId: draft.operationId,
    roomToken: draft.roomToken,
    referenceId: draft.referenceId,
    message: draft.message,
    replayContractRevision: draft.replayContractRevision,
    enqueueSequence: draft.enqueueSequence,
    state: TextSendOutboxState.queued,
    attemptCount: 0,
    messageIds: const [],
    duplicateRiskAcknowledged: false,
    errorClass: null,
    nextAttemptAt: null,
    replyTo: draft.replyTo,
    threadId: draft.threadId,
    replyToToken: draft.replyToToken,
    parentRoomToken: draft.parentRoomToken,
    silent: draft.silent,
  );
  return _replaceOperation(
    snapshot,
    account,
    operation,
    ChatOutboxOutcome.queued,
  );
}

bool _privateReplyAdmissionMatches(
  ChatTextSendAuthority authority,
  TextSendOutboxDraft draft,
) {
  final eligibility = draft.privateReplyEligibility;
  final sourceRoomToken = draft.parentRoomToken;
  final parentMessageId = draft.replyTo;
  return authority.profile.privateReply &&
      eligibility != null &&
      sourceRoomToken != null &&
      parentMessageId != null &&
      draft.replyToToken == sourceRoomToken &&
      eligibility.matchesAdmission(
        accountId: authority.accountId,
        server: authority.server,
        capabilityGeneration: authority.capabilityGeneration,
        sourceRoomToken: sourceRoomToken,
        targetRoomToken: draft.roomToken,
        parentMessageId: parentMessageId,
      );
}

ChatOutboxResult claimTextSendOperation(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ChatTextSendAuthority authority,
  required ChatOperationId operationId,
  required int now,
}) {
  if (now < 0) {
    _outboxFailure(r'$.now');
  }
  final binding = _operation(snapshot, accountId, operationId);
  if (binding == null ||
      !<TextSendOutboxState>{
        TextSendOutboxState.queued,
        TextSendOutboxState.retryable,
      }.contains(binding.operation.state) ||
      (binding.operation.nextAttemptAt != null &&
          now < binding.operation.nextAttemptAt!) ||
      !_canReplayTextSend(binding.account, authority, binding.operation)) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  final account = _quarantineObsoleteReplayPredecessors(
    binding.account,
    authority,
    binding.operation,
  );
  if (_sendStartIsBlocked(
    account,
    binding.operation.operationId,
    binding.operation,
  )) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  return _replaceOperation(
    snapshot,
    account,
    binding.operation.copyWith(
      state: TextSendOutboxState.sending,
      attemptCount: binding.operation.attemptCount + 1,
      errorClass: null,
      nextAttemptAt: null,
    ),
    ChatOutboxOutcome.sending,
  );
}

ChatOutboxResult applyTextSendHttpResponse(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ChatOperationId operationId,
  required ChatSendResponse response,
  int? now,
}) {
  final binding = _operation(snapshot, accountId, operationId);
  if (binding == null ||
      !_responseMatches(binding.account, binding.operation, response)) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  final operation = binding.operation;
  if (operation.state == TextSendOutboxState.completed &&
      response.classification == ChatSendClassification.confirmed) {
    final same =
        operation.messageIds.length == 1 &&
        operation.messageIds.single == response.messageId;
    return _result(
      same
          ? ChatOutboxOutcome.unchanged
          : ChatOutboxOutcome.conflictAfterCompletion,
      operationId: operationId,
    );
  }
  if (operation.state != TextSendOutboxState.sending) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }

  switch (response.classification) {
    case ChatSendClassification.confirmed:
      return _replaceOperation(
        snapshot,
        binding.account,
        operation.copyWith(
          state: TextSendOutboxState.completed,
          messageIds: <int>[response.messageId!],
          errorClass: null,
          nextAttemptAt: null,
        ),
        ChatOutboxOutcome.completed,
      );
    case ChatSendClassification.unconfirmed:
      return _replaceOperation(
        snapshot,
        binding.account,
        operation.copyWith(
          state: TextSendOutboxState.awaitingConfirmation,
          messageIds: const <int>[],
          errorClass: 'unconfirmed-response',
          nextAttemptAt: null,
        ),
        ChatOutboxOutcome.awaitingConfirmation,
      );
    case ChatSendClassification.deterministicFailure:
      return _replaceOperation(
        snapshot,
        binding.account,
        operation.copyWith(
          state: TextSendOutboxState.failed,
          messageIds: const <int>[],
          errorClass: 'deterministic-rejection',
          nextAttemptAt: null,
        ),
        ChatOutboxOutcome.failed,
      );
    case ChatSendClassification.rateLimited:
      if (now == null || now < 0) {
        _outboxFailure(r'$.now');
      }
      final delay =
          response.retryAfterSeconds ?? _localRateLimitDelay(operation);
      return _replaceOperation(
        snapshot,
        binding.account,
        operation.copyWith(
          state: TextSendOutboxState.retryable,
          messageIds: const <int>[],
          errorClass: 'rate-limited',
          nextAttemptAt: now + delay,
        ),
        ChatOutboxOutcome.retryable,
      );
    case ChatSendClassification.reauthenticationRequired:
      final updated = operation.copyWith(
        state: TextSendOutboxState.retryable,
        errorClass: 'reauth',
        nextAttemptAt: null,
      );
      return _replaceOperation(
        snapshot,
        binding.account.copyWith(
          lane: ChatAccountLane.reauthenticationRequired,
        ),
        updated,
        ChatOutboxOutcome.reauthenticationRequired,
      );
    case ChatSendClassification.ambiguous:
    case ChatSendClassification.serverError:
      return _replaceOperation(
        snapshot,
        binding.account,
        operation.copyWith(
          state: TextSendOutboxState.awaitingConfirmation,
          messageIds: const <int>[],
          errorClass: 'ambiguous-response',
          nextAttemptAt: null,
        ),
        ChatOutboxOutcome.awaitingConfirmation,
      );
  }
}

ChatOutboxResult recordTextSendTransportFailure(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ChatOperationId operationId,
  required ChatTransportBodyState bodyState,
  int? nextAttemptAt,
}) {
  final binding = _operation(snapshot, accountId, operationId);
  if (binding == null ||
      binding.operation.state != TextSendOutboxState.sending) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  if (bodyState == ChatTransportBodyState.notSent) {
    if (nextAttemptAt == null || nextAttemptAt < 0) {
      _outboxFailure(r'$.nextAttemptAt');
    }
    return _replaceOperation(
      snapshot,
      binding.account,
      binding.operation.copyWith(
        state: TextSendOutboxState.retryable,
        errorClass: 'transport-before-send',
        nextAttemptAt: nextAttemptAt,
      ),
      ChatOutboxOutcome.retryable,
    );
  }
  return _replaceOperation(
    snapshot,
    binding.account,
    binding.operation.copyWith(
      state: TextSendOutboxState.awaitingConfirmation,
      errorClass: 'ambiguous-transport',
      nextAttemptAt: null,
    ),
    ChatOutboxOutcome.awaitingConfirmation,
  );
}

ChatOutboxResult recoverTextSendAfterRestart(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ChatOperationId operationId,
}) {
  final binding = _operation(snapshot, accountId, operationId);
  if (binding == null) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  if (binding.operation.state != TextSendOutboxState.sending) {
    return _result(ChatOutboxOutcome.unchanged, operationId: operationId);
  }
  return _replaceOperation(
    snapshot,
    binding.account,
    binding.operation.copyWith(
      state: TextSendOutboxState.awaitingConfirmation,
      errorClass: 'process-interrupted',
      nextAttemptAt: null,
    ),
    ChatOutboxOutcome.awaitingConfirmation,
  );
}

ChatOutboxResult reconcileTextSendConfirmation(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ChatOperationId operationId,
  required Iterable<ChatMessageConfirmation> confirmations,
}) {
  final binding = _operation(snapshot, accountId, operationId);
  if (binding == null) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  final transition = _reconcileOperation(
    binding.account,
    binding.operation,
    confirmations,
  );
  if (transition.operation == null) {
    return _result(transition.outcome, operationId: operationId);
  }
  return _replaceOperation(
    snapshot,
    binding.account,
    transition.operation!,
    transition.outcome,
  );
}

ChatOutboxResult manuallyResendTextSend(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ChatTextSendAuthority authority,
  required ChatOperationId operationId,
  required bool duplicateRiskAcknowledged,
}) {
  final binding = _operation(snapshot, accountId, operationId);
  if (binding == null ||
      binding.operation.state != TextSendOutboxState.awaitingConfirmation ||
      binding.operation.messageIds.isNotEmpty ||
      !duplicateRiskAcknowledged ||
      !_canReplayTextSend(binding.account, authority, binding.operation)) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  final account = _quarantineObsoleteReplayPredecessors(
    binding.account,
    authority,
    binding.operation,
  );
  if (_sendStartIsBlocked(
    account,
    binding.operation.operationId,
    binding.operation,
  )) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  return _replaceOperation(
    snapshot,
    account,
    binding.operation.copyWith(
      state: TextSendOutboxState.sending,
      attemptCount: binding.operation.attemptCount + 1,
      duplicateRiskAcknowledged: true,
      messageIds: const <int>[],
      errorClass: null,
      nextAttemptAt: null,
    ),
    ChatOutboxOutcome.sending,
  );
}

ChatOutboxResult markChatAccountAuthenticationFailure(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required ChatOperationId operationId,
}) {
  final binding = _operation(snapshot, accountId, operationId);
  if (binding == null) {
    return _result(ChatOutboxOutcome.rejected, operationId: operationId);
  }
  return _replaceAccount(
    snapshot,
    binding.account.copyWith(lane: ChatAccountLane.reauthenticationRequired),
    ChatOutboxOutcome.reauthenticationRequired,
    operationId: operationId,
  );
}

ChatOutboxResult completeChatAccountReauthentication(
  ChatRuntimeSnapshot snapshot, {
  required AccountId accountId,
  required int credentialGeneration,
  required int capabilityGeneration,
}) {
  final account = snapshot.accounts[accountId];
  if (account == null ||
      account.lane != ChatAccountLane.reauthenticationRequired ||
      credentialGeneration <= account.credentialGeneration ||
      capabilityGeneration <= account.capabilityGeneration) {
    return _result(ChatOutboxOutcome.rejected);
  }
  return _replaceAccount(
    snapshot,
    account.copyWith(
      lane: ChatAccountLane.ready,
      credentialGeneration: credentialGeneration,
      capabilityGeneration: capabilityGeneration,
    ),
    ChatOutboxOutcome.reauthenticationSucceeded,
  );
}

ChatAccountState reconcileTextSendOperations(
  ChatAccountState account,
  Iterable<ChatMessageConfirmation> confirmations,
) {
  final values = confirmations.toList(growable: false);
  final operations = Map<ChatOperationId, TextSendOutboxOperation>.of(
    account.operations,
  );
  var changed = false;
  for (final entry in operations.entries.toList(growable: false)) {
    final transition = _reconcileOperation(account, entry.value, values);
    if (transition.operation != null) {
      operations[entry.key] = transition.operation!;
      changed = true;
    }
  }
  return changed ? account.copyWith(operations: operations) : account;
}

_Reconciliation _reconcileOperation(
  ChatAccountState account,
  TextSendOutboxOperation operation,
  Iterable<ChatMessageConfirmation> confirmations,
) {
  final matches =
      confirmations
          .where(
            (message) =>
                _authoritativeConfirmationMatches(account, operation, message),
          )
          .map((message) => message.messageId)
          .toSet()
          .toList()
        ..sort();
  if (operation.state == TextSendOutboxState.completed) {
    if (matches.isEmpty || _sameIds(operation.messageIds, matches)) {
      return const _Reconciliation(ChatOutboxOutcome.unchanged, null);
    }
    return const _Reconciliation(
      ChatOutboxOutcome.conflictAfterCompletion,
      null,
    );
  }
  if (matches.isEmpty) {
    return const _Reconciliation(ChatOutboxOutcome.unchanged, null);
  }
  if (matches.length > 1) {
    return _Reconciliation(
      ChatOutboxOutcome.ambiguousMatch,
      operation.copyWith(
        state: TextSendOutboxState.awaitingConfirmation,
        messageIds: matches,
        errorClass: 'multiple-reference-matches',
        nextAttemptAt: null,
      ),
    );
  }
  return _Reconciliation(
    ChatOutboxOutcome.completed,
    operation.copyWith(
      state: TextSendOutboxState.completed,
      messageIds: matches,
      errorClass: null,
      nextAttemptAt: null,
    ),
  );
}

bool _authoritativeConfirmationMatches(
  ChatAccountState account,
  TextSendOutboxOperation operation,
  ChatMessageConfirmation message,
) {
  if (message.accountId != account.accountId ||
      message.server != account.server ||
      message.roomToken != operation.roomToken ||
      message.referenceId != operation.referenceId.value) {
    return false;
  }
  return matchesAuthoritativeChatConfirmationScope(
    confirmation: ChatConfirmationScope(
      messageId: message.messageId,
      parentMessageId: message.parentMessageId,
      parentRoomToken: message.parentRoomToken,
      parentThreadId: message.parentThreadId,
      parentDeleted: message.parentDeleted,
      replyToMessageId: message.replyToMessageId,
      replyToRoomToken: message.replyToRoomToken,
      threadId: message.threadId,
    ),
    roomToken: operation.roomToken,
    replyTo: operation.replyTo,
    replyToToken: operation.replyToToken,
    parentRoomToken: operation.parentRoomToken,
    threadId: operation.threadId,
  );
}

bool _responseMatches(
  ChatAccountState account,
  TextSendOutboxOperation operation,
  ChatSendResponse response,
) {
  final request = response.request;
  return request.accountId == account.accountId &&
      request.server == account.server &&
      request.operationId == operation.operationId &&
      request.roomToken == operation.roomToken &&
      request.referenceId == operation.referenceId &&
      request.replyTo == operation.replyTo &&
      request.threadId == operation.threadId &&
      request.replyToToken == operation.replyToToken &&
      request.parentRoomToken == operation.parentRoomToken;
}

bool _canReplayTextSend(
  ChatAccountState account,
  ChatTextSendAuthority authority,
  TextSendOutboxOperation operation,
) {
  if (!_authorityMatchesAccount(account, authority) ||
      operation.replayContractRevision != authority.replayContractRevision ||
      !authority.profile.sendText) {
    return false;
  }
  if (operation.threadId != null) {
    return authority.profile.threadFetch;
  }
  if (operation.replyTo == null) {
    return true;
  }
  if (operation.parentRoomToken == operation.roomToken) {
    return authority.profile.reply && operation.replyToToken == null;
  }
  return authority.profile.privateReply &&
      operation.replyToToken == operation.parentRoomToken;
}

bool _authorityMatchesAccount(
  ChatAccountState account,
  ChatTextSendAuthority authority,
) =>
    authority.accountId == account.accountId &&
    authority.server == account.server &&
    authority.capabilityGeneration == account.capabilityGeneration &&
    authority.replayContractRevision == textSendReplayContractRevision;

ChatAccountState _quarantineObsoleteReplayPredecessors(
  ChatAccountState account,
  ChatTextSendAuthority authority,
  TextSendOutboxOperation operation,
) {
  Map<ChatOperationId, TextSendOutboxOperation>? operations;
  for (final entry in account.operations.entries) {
    final other = entry.value;
    if (entry.key == operation.operationId ||
        other.roomToken != operation.roomToken ||
        other.enqueueSequence >= operation.enqueueSequence ||
        other.replayContractRevision == authority.replayContractRevision ||
        !<TextSendOutboxState>{
          TextSendOutboxState.queued,
          TextSendOutboxState.retryable,
          TextSendOutboxState.awaitingConfirmation,
        }.contains(other.state)) {
      continue;
    }
    operations ??= Map<ChatOperationId, TextSendOutboxOperation>.of(
      account.operations,
    );
    operations[entry.key] = other.copyWith(
      state: TextSendOutboxState.failed,
      errorClass: 'obsolete-replay-contract',
      nextAttemptAt: null,
    );
  }
  return operations == null
      ? account
      : account.copyWith(operations: operations);
}

bool _sendStartIsBlocked(
  ChatAccountState account,
  ChatOperationId operationId,
  TextSendOutboxOperation operation,
) {
  if (account.lane != ChatAccountLane.ready) {
    return true;
  }
  for (final entry in account.operations.entries) {
    final other = entry.value;
    if (entry.key == operationId || other.roomToken != operation.roomToken) {
      continue;
    }
    if (other.state == TextSendOutboxState.sending) {
      return true;
    }
    if (other.enqueueSequence < operation.enqueueSequence &&
        <TextSendOutboxState>{
          TextSendOutboxState.queued,
          TextSendOutboxState.retryable,
          TextSendOutboxState.awaitingConfirmation,
        }.contains(other.state)) {
      return true;
    }
  }
  return false;
}

int _localRateLimitDelay(TextSendOutboxOperation operation) {
  final exponent = (operation.attemptCount - 1).clamp(0, 6);
  final delay = 5 * (1 << exponent);
  return delay > 300 ? 300 : delay;
}

ChatOutboxResult _replaceOperation(
  ChatRuntimeSnapshot snapshot,
  ChatAccountState account,
  TextSendOutboxOperation operation,
  ChatOutboxOutcome outcome,
) {
  final operations = Map<ChatOperationId, TextSendOutboxOperation>.of(
    account.operations,
  );
  operations[operation.operationId] = operation;
  return _replaceAccount(
    snapshot,
    account.copyWith(operations: operations),
    outcome,
    operationId: operation.operationId,
  );
}

ChatOutboxResult _replaceAccount(
  ChatRuntimeSnapshot snapshot,
  ChatAccountState account,
  ChatOutboxOutcome outcome, {
  ChatOperationId? operationId,
}) => ChatOutboxResult._(
  outcome: outcome,
  operationId: operationId,
  plan: ChatOutboxPlan._(snapshot, snapshot.replaceAccount(account)),
);

ChatOutboxResult _result(
  ChatOutboxOutcome outcome, {
  ChatOperationId? operationId,
}) =>
    ChatOutboxResult._(outcome: outcome, operationId: operationId, plan: null);

_OperationBinding? _operation(
  ChatRuntimeSnapshot snapshot,
  AccountId accountId,
  ChatOperationId operationId,
) {
  final account = snapshot.accounts[accountId];
  final operation = account?.operations[operationId];
  return account == null || operation == null
      ? null
      : _OperationBinding(account, operation);
}

bool _sameIds(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

Never _outboxFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidChatOutbox, path);

final class _OperationBinding {
  const _OperationBinding(this.account, this.operation);

  final ChatAccountState account;
  final TextSendOutboxOperation operation;
}

final class _Reconciliation {
  const _Reconciliation(this.outcome, this.operation);

  final ChatOutboxOutcome outcome;
  final TextSendOutboxOperation? operation;
}
