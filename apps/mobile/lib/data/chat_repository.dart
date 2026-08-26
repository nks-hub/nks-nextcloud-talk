import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:talk_protocol/talk_protocol.dart';

import '../core/giphy_reference.dart';
import 'app_database.dart';

part 'chat_repository_models.dart';
part 'chat_repository_clear_history.dart';
part 'chat_repository_mutations.dart';
part 'chat_repository_projection.dart';
part 'chat_repository_queries.dart';
part 'chat_repository_read_markers.dart';

const String _rootScopeKey = 'root';
const String _networkRootScopeKey = 'network-root';

final class ClaimedTextSend {
  const ClaimedTextSend({required this.request, required this.operation});

  final ChatSendRequest request;
  final TextSendOutboxOperation operation;
}

final class StoredOutgoingTextMessage {
  StoredOutgoingTextMessage({
    required this.operation,
    required Iterable<CachedChatMessage> confirmedMessages,
    required this.lastCommonRead,
  }) : confirmedMessages = List.unmodifiable(confirmedMessages);

  final StoredTextSendOperation operation;
  final List<CachedChatMessage> confirmedMessages;
  final ChatCursor? lastCommonRead;
}

final class ChatRepository {
  const ChatRepository(this._database);

  final AppDatabase _database;

  Stream<List<CachedChatMessage>> watchMessages({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) => _watchMessagesQuery(
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
  );

  Future<bool?> cachedRootIsNamedThread({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) => _cachedRootIsNamedThreadQuery(
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
  );

  Stream<List<StoredTextSendOperation>> watchTextSendOperations({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) => _watchTextSendOperationsQuery(
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
  );

  Stream<List<StoredOutgoingTextMessage>> watchOutgoingTextMessages({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) => _watchOutgoingTextMessagesQuery(
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
  );

  Stream<StoredChatScope?> watchRootScope({
    required String accountId,
    required String roomToken,
  }) => _watchRootScopeQuery(accountId: accountId, roomToken: roomToken);

  Stream<StoredChatScope?> watchScope({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) => _watchScopeQuery(
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
  );

  Future<CachedConversation?> getConversation({
    required String accountId,
    required String roomToken,
  }) => _getConversationQuery(accountId: accountId, roomToken: roomToken);
  Future<StoredChatCapability> recordCapabilities({
    required String accountId,
    required Set<String> talkFeatures,
    required DateTime observedAt,
  }) async {
    final sortedFeatures = talkFeatures.toList()..sort();
    final fingerprint = jsonEncode(sortedFeatures);
    return _database.transaction(() async {
      final existing = await (_database.select(
        _database.chatCapabilities,
      )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();
      final observedAtMillis = observedAt.toUtc().millisecondsSinceEpoch;
      if (existing == null) {
        await _database
            .into(_database.chatCapabilities)
            .insert(
              ChatCapabilitiesCompanion.insert(
                accountId: accountId,
                fingerprint: fingerprint,
                updatedAtMillis: observedAtMillis,
              ),
            );
      } else {
        final authenticationRecovered =
            existing.lane == ChatAccountLane.reauthenticationRequired.name;
        final capabilitiesChanged = existing.fingerprint != fingerprint;
        await (_database.update(
          _database.chatCapabilities,
        )..where((row) => row.accountId.equals(accountId))).write(
          ChatCapabilitiesCompanion(
            fingerprint: Value(fingerprint),
            generation: Value(
              existing.generation +
                  (capabilitiesChanged || authenticationRecovered ? 1 : 0),
            ),
            credentialGeneration: Value(
              existing.credentialGeneration + (authenticationRecovered ? 1 : 0),
            ),
            lane: Value(ChatAccountLane.ready.name),
            updatedAtMillis: Value(observedAtMillis),
          ),
        );
      }
      return (_database.select(
        _database.chatCapabilities,
      )..where((row) => row.accountId.equals(accountId))).getSingle();
    });
  }

  Future<StoredChatScope> ensureRootScope({
    required StoredAccount account,
    required CachedConversation conversation,
  }) async {
    if (account.id != conversation.accountId) {
      throw StateError('Conversation does not belong to the account');
    }
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    if (room.token.value != conversation.token) {
      throw StateError('Conversation token does not match its payload');
    }
    final anchor = (room.lastMessage?.id ?? 0).toString();
    final commonRead = room.lastCommonReadMessage.toString();
    ChatCursor.parse(anchor);
    ChatCursor.parse(commonRead);

    return _database.transaction(() async {
      var viewScope = await _rootScope(
        accountId: account.id,
        roomToken: conversation.token,
      );
      if (viewScope == null) {
        await _database
            .into(_database.chatScopes)
            .insert(
              ChatScopesCompanion.insert(
                accountId: account.id,
                roomToken: conversation.token,
                scopeKey: _rootScopeKey,
                threadId: const Value(null),
                historyCursor: anchor,
                futureCursor: anchor,
                lastCommonRead: commonRead,
                lastReadMessage: room.lastReadMessage,
                unreadMessages: room.unreadMessages,
                hasHistory: true,
                futureConverged: true,
                blocksJson: jsonEncode([
                  [anchor, anchor],
                ]),
              ),
            );
      } else {
        await (_database.update(_database.chatScopes)..where(
              (scope) =>
                  scope.accountId.equals(account.id) &
                  scope.roomToken.equals(conversation.token) &
                  scope.scopeKey.equals(_rootScopeKey),
            ))
            .write(
              ChatScopesCompanion(
                lastCommonRead: Value(commonRead),
                lastReadMessage: Value(room.lastReadMessage),
                unreadMessages: Value(room.unreadMessages),
              ),
            );
      }
      viewScope = (await _rootScope(
        accountId: account.id,
        roomToken: conversation.token,
      ))!;

      final networkScope = await _networkScope(
        accountId: account.id,
        roomToken: conversation.token,
        threadId: null,
      );
      if (networkScope == null) {
        await _migrateLegacyThreadNetworkScopesInCurrentTransaction(
          accountId: account.id,
          roomToken: conversation.token,
        );
        await _database
            .into(_database.chatScopes)
            .insert(
              ChatScopesCompanion.insert(
                accountId: account.id,
                roomToken: conversation.token,
                scopeKey: _networkRootScopeKey,
                threadId: const Value(null),
                historyCursor: viewScope.historyCursor,
                futureCursor: viewScope.futureCursor,
                lastCommonRead: viewScope.lastCommonRead,
                lastReadMessage: viewScope.lastReadMessage,
                unreadMessages: viewScope.unreadMessages,
                hasHistory: viewScope.hasHistory,
                futureConverged: viewScope.futureConverged,
                blocksJson: viewScope.blocksJson,
                lastSyncedAtMillis: Value(viewScope.lastSyncedAtMillis),
                lastSyncError: Value(viewScope.lastSyncError),
              ),
            );
      } else {
        await (_database.update(_database.chatScopes)..where(
              (scope) =>
                  scope.accountId.equals(account.id) &
                  scope.roomToken.equals(conversation.token) &
                  scope.scopeKey.equals(_networkRootScopeKey),
            ))
            .write(
              ChatScopesCompanion(
                lastCommonRead: Value(commonRead),
                lastReadMessage: Value(room.lastReadMessage),
                unreadMessages: Value(room.unreadMessages),
              ),
            );
      }
      return viewScope;
    });
  }

  Future<void> _migrateLegacyThreadNetworkScopesInCurrentTransaction({
    required String accountId,
    required String roomToken,
  }) async {
    final legacyScopes =
        await (_database.select(_database.chatScopes)..where(
              (scope) =>
                  scope.accountId.equals(accountId) &
                  scope.roomToken.equals(roomToken) &
                  scope.threadId.isNotNull(),
            ))
            .get();
    for (final legacyScope in legacyScopes) {
      final threadId = legacyScope.threadId!;
      if (legacyScope.scopeKey != _scopeKey(threadId) ||
          await _networkScope(
                accountId: accountId,
                roomToken: roomToken,
                threadId: threadId,
              ) !=
              null) {
        continue;
      }
      final isNamedThread = await cachedRootIsNamedThread(
        accountId: accountId,
        roomToken: roomToken,
        threadId: threadId,
      );
      if (isNamedThread != true) {
        continue;
      }
      await _database
          .into(_database.chatScopes)
          .insert(
            ChatScopesCompanion.insert(
              accountId: accountId,
              roomToken: roomToken,
              scopeKey: _networkScopeKey(threadId),
              threadId: Value(threadId),
              historyCursor: legacyScope.historyCursor,
              futureCursor: legacyScope.futureCursor,
              lastCommonRead: legacyScope.lastCommonRead,
              lastReadMessage: legacyScope.lastReadMessage,
              unreadMessages: legacyScope.unreadMessages,
              hasHistory: legacyScope.hasHistory,
              futureConverged: legacyScope.futureConverged,
              blocksJson: legacyScope.blocksJson,
              lastSyncedAtMillis: Value(legacyScope.lastSyncedAtMillis),
              lastSyncError: Value(legacyScope.lastSyncError),
            ),
          );
    }
  }

  Future<StoredChatScope> ensureThreadScope({
    required StoredAccount account,
    required CachedConversation conversation,
    required int threadId,
  }) async {
    if (threadId < 1) {
      throw ArgumentError.value(threadId, 'threadId');
    }
    if (account.id != conversation.accountId) {
      throw StateError('Conversation does not belong to the account');
    }
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    if (room.token.value != conversation.token) {
      throw StateError('Conversation token does not match its payload');
    }
    final anchor = threadId.toString();
    ChatCursor.parse(anchor);
    final scopeKey = _scopeKey(threadId);
    return _database.transaction(() async {
      final existing = await _scope(
        accountId: account.id,
        roomToken: conversation.token,
        threadId: threadId,
      );
      if (existing == null) {
        await _database
            .into(_database.chatScopes)
            .insert(
              ChatScopesCompanion.insert(
                accountId: account.id,
                roomToken: conversation.token,
                scopeKey: scopeKey,
                threadId: Value(threadId),
                historyCursor: anchor,
                futureCursor: anchor,
                lastCommonRead: '0',
                lastReadMessage: 0,
                unreadMessages: 0,
                hasHistory: true,
                futureConverged: false,
                blocksJson: jsonEncode([
                  [anchor, anchor],
                ]),
              ),
            );
      }
      return (await _scope(
        accountId: account.id,
        roomToken: conversation.token,
        threadId: threadId,
      ))!;
    });
  }

  Future<StoredChatScope> ensureNamedThreadNetworkScope({
    required StoredAccount account,
    required CachedConversation conversation,
    required int threadId,
  }) async {
    if (threadId < 1) {
      throw ArgumentError.value(threadId, 'threadId');
    }
    if (account.id != conversation.accountId) {
      throw StateError('Conversation does not belong to the account');
    }
    final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    if (room.token.value != conversation.token) {
      throw StateError('Conversation token does not match its payload');
    }
    final anchor = threadId.toString();
    ChatCursor.parse(anchor);
    final scopeKey = _networkScopeKey(threadId);
    return _database.transaction(() async {
      final existing = await _networkScope(
        accountId: account.id,
        roomToken: conversation.token,
        threadId: threadId,
      );
      if (existing == null) {
        await _database
            .into(_database.chatScopes)
            .insert(
              ChatScopesCompanion.insert(
                accountId: account.id,
                roomToken: conversation.token,
                scopeKey: scopeKey,
                threadId: Value(threadId),
                historyCursor: anchor,
                futureCursor: anchor,
                lastCommonRead: '0',
                lastReadMessage: 0,
                unreadMessages: 0,
                hasHistory: true,
                futureConverged: false,
                blocksJson: jsonEncode([
                  [anchor, anchor],
                ]),
              ),
            );
      }
      return (await _networkScope(
        accountId: account.id,
        roomToken: conversation.token,
        threadId: threadId,
      ))!;
    });
  }

  Future<void> retireNamedThreadNetworkScope({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) {
    return (_database.delete(_database.chatScopes)..where(
          (scope) =>
              scope.accountId.equals(accountId) &
              scope.roomToken.equals(roomToken) &
              scope.scopeKey.equals(_networkScopeKey(threadId)),
        ))
        .go();
  }

  Future<String?> readDraft({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) async {
    final row =
        await (_database.select(_database.chatDrafts)..where(
              (draft) =>
                  draft.accountId.equals(accountId) &
                  draft.roomToken.equals(roomToken) &
                  draft.scopeKey.equals(_scopeKey(threadId)),
            ))
            .getSingleOrNull();
    final text = row?.draftText;
    return text == null || text.isEmpty ? null : text;
  }

  /// Stores composer text that is not admitted to the outbox yet. Empty text
  /// removes the row so an abandoned draft never resurfaces.
  Future<void> saveDraft({
    required String accountId,
    required String roomToken,
    required String text,
    int? threadId,
  }) async {
    final scopeKey = _scopeKey(threadId);
    if (text.isEmpty) {
      await (_database.delete(_database.chatDrafts)..where(
            (draft) =>
                draft.accountId.equals(accountId) &
                draft.roomToken.equals(roomToken) &
                draft.scopeKey.equals(scopeKey),
          ))
          .go();
      return;
    }
    await _database
        .into(_database.chatDrafts)
        .insertOnConflictUpdate(
          ChatDraftsCompanion.insert(
            accountId: accountId,
            roomToken: roomToken,
            scopeKey: scopeKey,
            draftText: text,
            updatedAtMillis: DateTime.now().toUtc().millisecondsSinceEpoch,
          ),
        );
  }

  Future<StoredChatScope?> getRootScope({
    required String accountId,
    required String roomToken,
  }) => getScope(accountId: accountId, roomToken: roomToken, threadId: null);

  Future<StoredChatScope?> getScope({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) => _scope(accountId: accountId, roomToken: roomToken, threadId: threadId);

  Future<StoredChatScope?> getNetworkScope({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) => _networkScope(
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
  );

  Future<bool> isCapabilityGenerationCurrent({
    required String accountId,
    required int generation,
  }) async {
    final capability =
        await (_database.select(_database.chatCapabilities)
              ..where((row) => row.accountId.equals(accountId))
              ..limit(1))
            .getSingleOrNull();
    return capability != null &&
        capability.generation == generation &&
        capability.lane == ChatAccountLane.ready.name;
  }

  Future<StoredChatCapability?> getReadyCapabilitySnapshot(
    String accountId,
  ) async {
    final capability =
        await (_database.select(_database.chatCapabilities)
              ..where((row) => row.accountId.equals(accountId))
              ..limit(1))
            .getSingleOrNull();
    if (capability?.lane != ChatAccountLane.ready.name) {
      return null;
    }
    return capability;
  }

  Future<void> markReauthenticationRequired(String accountId) {
    return (_database.update(
      _database.chatCapabilities,
    )..where((row) => row.accountId.equals(accountId))).write(
      ChatCapabilitiesCompanion(
        lane: Value(ChatAccountLane.reauthenticationRequired.name),
        updatedAtMillis: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
      ),
    );
  }

  Future<ChatMergeOutcome> applyChatGetResponse(ChatGetResponse response) {
    return _database.transaction(() async {
      final rootBackedViewThreadIds =
          response.request.threadId == null &&
              response.classification == ChatGetClassification.messages
          ? await _rootBackedViewThreadIdsInCurrentTransaction(
              accountId: response.request.accountId.value,
              roomToken: response.request.roomToken.value,
            )
          : const <int>{};
      final snapshot = await _loadRuntime(response.request.accountId.value);
      final result = planChatGetMerge(snapshot, response);
      final plan = result.plan;
      if (plan != null) {
        await _persistChatGetCandidate(
          response: response,
          outcome: result.outcome,
          candidate: plan.commit(snapshot),
          messages: plan.messageUpserts,
        );
      }
      if (result.outcome != ChatMergeOutcome.rejected &&
          result.outcome != ChatMergeOutcome.reauthenticationRequired) {
        final threadId = response.request.threadId;
        if (threadId == null) {
          await _projectRootNetworkStateToViewsInCurrentTransaction(
            accountId: response.request.accountId.value,
            roomToken: response.request.roomToken.value,
            preservedViewThreadIds: rootBackedViewThreadIds,
          );
        } else {
          await _projectNamedNetworkStateToViewInCurrentTransaction(
            accountId: response.request.accountId.value,
            roomToken: response.request.roomToken.value,
            threadId: threadId,
          );
        }
      }
      return result.outcome;
    });
  }

  Future<ChatMergeOutcome> applyChatReadResponse(ChatReadResponse response) =>
      _applyChatReadResponse(response);

  Future<TextSendOutboxOperation> admitTextSend({
    required String accountId,
    required ConversationToken roomToken,
    required ChatTextSendAuthority authority,
    required ChatOperationId operationId,
    required ChatReferenceId referenceId,
    required String message,
    int? replyTo,
    int? threadId,
    ConversationToken? replyToToken,
    ConversationToken? parentRoomToken,
    PrivateReplyEligibilitySnapshot? privateReplyEligibility,
  }) {
    return _database.transaction(() async {
      final snapshot = await _loadRuntime(accountId);
      final account = snapshot.accounts[AccountId.parse(accountId)];
      if (account == null) {
        throw StateError('Chat account does not exist');
      }
      final sequence =
          account.operations.values
              .where((operation) => operation.roomToken == roomToken)
              .fold<int>(0, (value, operation) {
                return operation.enqueueSequence > value
                    ? operation.enqueueSequence
                    : value;
              }) +
          1;
      final result = admitTextSendOperation(
        snapshot,
        accountId: account.accountId,
        authority: authority,
        draft: TextSendOutboxDraft(
          operationId: operationId,
          operationKind: 'textSend',
          roomToken: roomToken,
          referenceId: referenceId,
          message: message,
          replayContractRevision: textSendReplayContractRevision,
          enqueueSequence: sequence,
          replyTo: replyTo,
          threadId: threadId,
          replyToToken: replyToToken,
          parentRoomToken: parentRoomToken,
          privateReplyEligibility: privateReplyEligibility,
        ),
      );
      final plan = result.plan;
      if (result.outcome != ChatOutboxOutcome.queued || plan == null) {
        throw StateError('Text send was not admitted');
      }
      final candidate = plan.commit(snapshot);
      final candidateAccount = candidate.accounts[account.accountId]!;
      await _persistAccount(candidateAccount);
      return candidateAccount.operations[operationId]!;
    });
  }

  Future<ClaimedTextSend?> claimNextTextSend({
    required String accountId,
    required ConversationToken roomToken,
    required ChatTextSendAuthority authority,
    required ChatRequestId requestId,
    required int now,
  }) {
    return _database.transaction(() async {
      final snapshot = await _loadRuntime(accountId);
      final account = snapshot.accounts[AccountId.parse(accountId)];
      if (account == null) {
        return null;
      }
      final candidates =
          account.operations.values
              .where((operation) => operation.roomToken == roomToken)
              .where(
                (operation) =>
                    operation.state == TextSendOutboxState.queued ||
                    operation.state == TextSendOutboxState.retryable,
              )
              .toList()
            ..sort(
              (left, right) =>
                  left.enqueueSequence.compareTo(right.enqueueSequence),
            );
      for (final operation in candidates) {
        final result = claimTextSendOperation(
          snapshot,
          accountId: account.accountId,
          authority: authority,
          operationId: operation.operationId,
          now: now,
        );
        final plan = result.plan;
        if (result.outcome != ChatOutboxOutcome.sending || plan == null) {
          continue;
        }
        final candidate = plan.commit(snapshot);
        final candidateAccount = candidate.accounts[account.accountId]!;
        final claimed = candidateAccount.operations[operation.operationId]!;
        await _persistAccount(candidateAccount);
        return ClaimedTextSend(
          request: _restoreSendRequest(
            account: candidateAccount,
            operation: claimed,
            authority: authority,
            requestId: requestId,
          ),
          operation: claimed,
        );
      }
      return null;
    });
  }

  Future<ClaimedTextSend?> manuallyResend({
    required String accountId,
    required ChatOperationId operationId,
    required ChatTextSendAuthority authority,
    required ChatRequestId requestId,
  }) {
    return _database.transaction(() async {
      final snapshot = await _loadRuntime(accountId);
      final typedAccountId = AccountId.parse(accountId);
      final result = manuallyResendTextSend(
        snapshot,
        accountId: typedAccountId,
        authority: authority,
        operationId: operationId,
        duplicateRiskAcknowledged: true,
      );
      final plan = result.plan;
      if (result.outcome != ChatOutboxOutcome.sending || plan == null) {
        return null;
      }
      final candidate = plan.commit(snapshot);
      final account = candidate.accounts[typedAccountId]!;
      final operation = account.operations[operationId]!;
      await _persistAccount(account);
      return ClaimedTextSend(
        request: _restoreSendRequest(
          account: account,
          operation: operation,
          authority: authority,
          requestId: requestId,
        ),
        operation: operation,
      );
    });
  }

  Future<ChatOutboxOutcome> applyTextSendResponse({
    required String accountId,
    required ChatOperationId operationId,
    required ChatSendResponse response,
    required int now,
  }) {
    return _database.transaction(() async {
      final snapshot = await _loadRuntime(accountId);
      final typedAccountId = AccountId.parse(accountId);
      final result = applyTextSendHttpResponse(
        snapshot,
        accountId: typedAccountId,
        operationId: operationId,
        response: response,
        now: now,
      );
      final plan = result.plan;
      if (plan == null) {
        return result.outcome;
      }
      final sourceAccount = snapshot.accounts[typedAccountId]!;
      final sourceOperation = sourceAccount.operations[operationId];
      final candidate = plan.commit(snapshot);
      await _persistAccount(
        candidate.accounts[typedAccountId]!,
        messages: response.classification == ChatSendClassification.confirmed
            ? [response.message!]
            : const [],
      );
      if (result.outcome == ChatOutboxOutcome.completed &&
          sourceOperation != null &&
          response.message != null) {
        await _appendConfirmedMessageToViewInCurrentTransaction(
          accountId: accountId,
          operation: sourceOperation,
          message: response.message!,
        );
      }
      return result.outcome;
    });
  }

  Future<ChatOutboxOutcome> recordTextSendFailure({
    required String accountId,
    required ChatOperationId operationId,
    required ChatTransportBodyState bodyState,
    int? nextAttemptAt,
  }) {
    return _database.transaction(() async {
      final snapshot = await _loadRuntime(accountId);
      final typedAccountId = AccountId.parse(accountId);
      final result = recordTextSendTransportFailure(
        snapshot,
        accountId: typedAccountId,
        operationId: operationId,
        bodyState: bodyState,
        nextAttemptAt: nextAttemptAt,
      );
      final plan = result.plan;
      if (plan == null) {
        return result.outcome;
      }
      final candidate = plan.commit(snapshot);
      await _persistAccount(candidate.accounts[typedAccountId]!);
      return result.outcome;
    });
  }

  Future<void> recoverInterruptedTextSends(String accountId) {
    return _database.transaction(() async {
      var snapshot = await _loadRuntime(accountId);
      final typedAccountId = AccountId.parse(accountId);
      final sending = snapshot.accounts[typedAccountId]!.operations.values
          .where((operation) => operation.state == TextSendOutboxState.sending)
          .map((operation) => operation.operationId)
          .toList(growable: false);
      var changed = false;
      for (final operationId in sending) {
        final result = recoverTextSendAfterRestart(
          snapshot,
          accountId: typedAccountId,
          operationId: operationId,
        );
        final plan = result.plan;
        if (plan != null) {
          snapshot = plan.commit(snapshot);
          changed = true;
        }
      }
      if (changed) {
        await _persistAccount(snapshot.accounts[typedAccountId]!);
      }
    });
  }

  /// Drops a pending text send from the outbox for good.
  ///
  /// Only an operation the client can prove never reached the server may be
  /// removed; see the outbox state table in
  /// `docs/architecture/chat-messages-api.md`. Returns `false` without
  /// touching anything when the send may already exist on the server, so the
  /// caller can say so instead of reporting a cancellation that never
  /// happened. The check and the delete share one transaction, so a claim
  /// that starts transmitting in parallel cannot slip past the gate.
  Future<bool> cancelTextSend({
    required String accountId,
    required String operationId,
  }) {
    return _database.transaction(() async {
      final rows = _database.textSendOperations;
      final row =
          await (_database.select(rows)..where(
                (operation) =>
                    operation.accountId.equals(accountId) &
                    operation.operationId.equals(operationId),
              ))
              .getSingleOrNull();
      if (row == null) {
        // Already gone, so a repeated cancel is not a failure.
        return true;
      }
      if (!_isCancellableTextSend(row)) {
        return false;
      }
      await (_database.delete(rows)..where(
            (operation) =>
                operation.accountId.equals(accountId) &
                operation.operationId.equals(operationId),
          ))
          .go();
      return true;
    });
  }

  Future<void> recordRoomError({
    required String accountId,
    required String roomToken,
    required int? threadId,
    required String errorCode,
  }) {
    return (_database.update(_database.chatScopes)..where(
          (scope) =>
              scope.accountId.equals(accountId) &
              scope.roomToken.equals(roomToken) &
              scope.scopeKey.equals(_scopeKey(threadId)),
        ))
        .write(ChatScopesCompanion(lastSyncError: Value(errorCode)));
  }

  Future<void> clearRoomError({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) {
    return (_database.update(_database.chatScopes)..where(
          (scope) =>
              scope.accountId.equals(accountId) &
              scope.roomToken.equals(roomToken) &
              scope.scopeKey.equals(_scopeKey(threadId)),
        ))
        .write(const ChatScopesCompanion(lastSyncError: Value(null)));
  }

  @visibleForTesting
  Future<ChatRuntimeSnapshot> loadRuntimeForTesting(String accountId) {
    return _loadRuntime(accountId);
  }

  /// Looks up a single cached message, e.g. to merge a fresh reaction
  /// aggregate onto it before persisting the result.
  Future<CachedChatMessage?> getMessage({
    required String accountId,
    required String roomToken,
    required int messageId,
  }) {
    return (_database.select(_database.cachedChatMessages)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.roomToken.equals(roomToken) &
              row.messageId.equals(messageId),
        ))
        .getSingleOrNull();
  }

  /// Persists an authoritative edit, delete, or reaction mutation.
  Future<void> applyMessageMutation({
    required String accountId,
    required ServerBase server,
    required ChatMessage message,
  }) => _applyMessageMutation(
    accountId: accountId,
    server: server,
    message: message,
  );
}
