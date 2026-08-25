import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:talk_protocol/talk_protocol.dart';

import '../core/giphy_reference.dart';
import 'app_database.dart';

const String _rootScopeKey = 'root';

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
  }) {
    final query = _database.select(_database.cachedChatMessages)
      ..where(
        (message) =>
            message.accountId.equals(accountId) &
            message.roomToken.equals(roomToken) &
            (threadId == null
                ? (message.threadId.isNull() |
                      message.threadId.equalsExp(message.messageId))
                : (message.threadId.equals(threadId) |
                      message.messageId.equals(threadId))),
      )
      ..orderBy([(message) => OrderingTerm.asc(message.messageId)]);
    return query.watch();
  }

  Future<bool?> cachedRootIsNamedThread({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) async {
    if (threadId < 1) {
      throw ArgumentError.value(threadId, 'threadId');
    }
    final root =
        await (_database.select(_database.cachedChatMessages)..where(
              (message) =>
                  message.accountId.equals(accountId) &
                  message.roomToken.equals(roomToken) &
                  message.messageId.equals(threadId),
            ))
            .getSingleOrNull();
    if (root == null) {
      return null;
    }
    final message = ChatMessage.fromJson(jsonDecode(root.rawJson));
    if (message.messageId != threadId || message.roomToken.value != roomToken) {
      return null;
    }
    return message.isThread == true;
  }

  Stream<List<StoredTextSendOperation>> watchTextSendOperations({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    final query = _database.select(_database.textSendOperations)
      ..where(
        (operation) =>
            operation.accountId.equals(accountId) &
            operation.roomToken.equals(roomToken) &
            (threadId == null
                ? operation.replyTo.isNull() & operation.threadId.isNull()
                : operation.replyTo.equals(threadId) |
                      operation.threadId.equals(threadId)),
      )
      ..orderBy([(operation) => OrderingTerm.asc(operation.enqueueSequence)]);
    return query.watch();
  }

  Stream<List<StoredOutgoingTextMessage>> watchOutgoingTextMessages({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) {
    final operations = _database.textSendOperations;
    final messages = _database.cachedChatMessages;
    final scopes = _database.chatScopes;
    final query =
        _database.select(operations).join([
            leftOuterJoin(
              messages,
              messages.accountId.equalsExp(operations.accountId) &
                  messages.roomToken.equalsExp(operations.roomToken) &
                  messages.referenceId.equalsExp(operations.referenceId),
            ),
            leftOuterJoin(
              scopes,
              scopes.accountId.equalsExp(operations.accountId) &
                  scopes.roomToken.equalsExp(operations.roomToken) &
                  scopes.scopeKey.equals(_scopeKey(threadId)),
            ),
          ])
          ..where(
            operations.accountId.equals(accountId) &
                operations.roomToken.equals(roomToken) &
                (threadId == null
                    ? operations.replyTo.isNull() & operations.threadId.isNull()
                    : operations.replyTo.equals(threadId) |
                          operations.threadId.equals(threadId)),
          )
          ..orderBy([
            OrderingTerm.asc(operations.enqueueSequence),
            OrderingTerm.asc(messages.messageId),
          ]);
    return query.watch().map((rows) {
      final grouped = <String, _OutgoingTextMessageAccumulator>{};
      for (final row in rows) {
        final operation = row.readTable(operations);
        final scope = row.readTableOrNull(scopes);
        final accumulator = grouped.putIfAbsent(
          operation.operationId,
          () => _OutgoingTextMessageAccumulator(
            operation,
            lastCommonRead: scope == null
                ? null
                : ChatCursor.parse(
                    scope.lastCommonRead,
                    path: r'$.chatScopes.lastCommonRead',
                  ),
          ),
        );
        final message = row.readTableOrNull(messages);
        if (message != null &&
            accumulator.confirmedMessageIds.contains(message.messageId)) {
          accumulator.confirmedMessages[message.messageId] = message;
        }
      }
      return grouped.values
          .map((accumulator) => accumulator.build())
          .toList(growable: false);
    });
  }

  Stream<StoredChatScope?> watchRootScope({
    required String accountId,
    required String roomToken,
  }) => watchScope(accountId: accountId, roomToken: roomToken, threadId: null);

  Stream<StoredChatScope?> watchScope({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) {
    return (_database.select(_database.chatScopes)
          ..where(
            (scope) =>
                scope.accountId.equals(accountId) &
                scope.roomToken.equals(roomToken) &
                scope.scopeKey.equals(_scopeKey(threadId)),
          )
          ..limit(1))
        .watchSingleOrNull();
  }

  Future<CachedConversation?> getConversation({
    required String accountId,
    required String roomToken,
  }) {
    return (_database.select(_database.cachedConversations)..where(
          (conversation) =>
              conversation.accountId.equals(accountId) &
              conversation.token.equals(roomToken),
        ))
        .getSingleOrNull();
  }

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
      final existing = await _rootScope(
        accountId: account.id,
        roomToken: conversation.token,
      );
      if (existing == null) {
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
      return (await _rootScope(
        accountId: account.id,
        roomToken: conversation.token,
      ))!;
    });
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
      final snapshot = await _loadRuntime(response.request.accountId.value);
      final result = planChatGetMerge(snapshot, response);
      final plan = result.plan;
      if (plan == null) {
        return result.outcome;
      }
      final messages = plan.messageUpserts;
      final candidate = plan.commit(snapshot);
      await _persistAccount(
        candidate.accounts[response.request.accountId]!,
        messages: messages,
        syncedScope: ChatScopeKey(
          roomToken: response.request.roomToken,
          threadId: response.request.threadId,
        ),
      );
      return result.outcome;
    });
  }

  Future<TextSendOutboxOperation> admitTextSend({
    required String accountId,
    required ConversationToken roomToken,
    required ChatTextSendAuthority authority,
    required ChatOperationId operationId,
    required ChatReferenceId referenceId,
    required String message,
    int? replyTo,
    int? threadId,
    ConversationToken? parentRoomToken,
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
          replyToToken: null,
          parentRoomToken: parentRoomToken,
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
      final candidate = plan.commit(snapshot);
      await _persistAccount(
        candidate.accounts[typedAccountId]!,
        messages: response.classification == ChatSendClassification.confirmed
            ? [response.message!]
            : const [],
      );
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

  Future<void> projectNetworkScopeState({
    required String accountId,
    required String roomToken,
    required int? networkThreadId,
    required int viewThreadId,
  }) {
    if (networkThreadId == viewThreadId) {
      return Future<void>.value();
    }
    return _database.transaction(() async {
      final networkScope = await _scope(
        accountId: accountId,
        roomToken: roomToken,
        threadId: networkThreadId,
      );
      final viewScope = await _scope(
        accountId: accountId,
        roomToken: roomToken,
        threadId: viewThreadId,
      );
      if (networkScope == null || viewScope == null) {
        throw StateError('Chat scope projection is missing');
      }
      await (_database.update(_database.chatScopes)..where(
            (scope) =>
                scope.accountId.equals(accountId) &
                scope.roomToken.equals(roomToken) &
                scope.scopeKey.equals(_scopeKey(viewThreadId)),
          ))
          .write(
            ChatScopesCompanion(
              hasHistory: Value(networkScope.hasHistory),
              futureConverged: Value(networkScope.futureConverged),
              lastSyncedAtMillis: Value(networkScope.lastSyncedAtMillis),
              lastSyncError: Value(networkScope.lastSyncError),
            ),
          );
    });
  }

  @visibleForTesting
  Future<ChatRuntimeSnapshot> loadRuntimeForTesting(String accountId) {
    return _loadRuntime(accountId);
  }

  Future<ChatRuntimeSnapshot> _loadRuntime(String accountId) async {
    final account = await (_database.select(
      _database.accounts,
    )..where((row) => row.id.equals(accountId))).getSingleOrNull();
    final capability = await (_database.select(
      _database.chatCapabilities,
    )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();
    if (account == null || capability == null) {
      throw StateError('Chat account is not prepared');
    }
    final scopeRows = await (_database.select(
      _database.chatScopes,
    )..where((row) => row.accountId.equals(accountId))).get();
    final messageRows = await (_database.select(
      _database.cachedChatMessages,
    )..where((row) => row.accountId.equals(accountId))).get();
    final operationRows = await (_database.select(
      _database.textSendOperations,
    )..where((row) => row.accountId.equals(accountId))).get();

    final scopes = <ChatScopeKey, ChatScopeState>{};
    for (final row in scopeRows) {
      final key = ChatScopeKey(
        roomToken: ConversationToken.parse(
          row.roomToken,
          path: r'$.chatScopes.roomToken',
        ),
        threadId: row.threadId,
      );
      if (row.scopeKey != _scopeKey(row.threadId)) {
        throw StateError('Stored chat scope key is invalid');
      }
      final blocks = _decodeBlocks(row.blocksJson);
      final messageIds =
          messageRows
              .where((message) => message.roomToken == row.roomToken)
              .where(
                (message) => row.threadId == null
                    ? message.threadId == null ||
                          message.threadId == message.messageId
                    : message.threadId == row.threadId,
              )
              .where((message) {
                final cursor = ChatCursor.parse(message.messageId.toString());
                return blocks.any((block) => block.contains(cursor));
              })
              .map((message) => message.messageId)
              .toList()
            ..sort();
      scopes[key] = ChatScopeState(
        messageIds: messageIds,
        historyCursor: ChatCursor.parse(row.historyCursor),
        futureCursor: ChatCursor.parse(row.futureCursor),
        lastCommonRead: ChatCursor.parse(row.lastCommonRead),
        lastReadMessage: row.lastReadMessage,
        unreadMessages: row.unreadMessages,
        hasHistory: row.hasHistory,
        futureConverged: row.futureConverged,
        blocks: blocks,
      );
    }

    final operations = <ChatOperationId, TextSendOutboxOperation>{};
    for (final row in operationRows) {
      final operationId = ChatOperationId.parse(row.operationId);
      operations[operationId] = TextSendOutboxOperation(
        operationId: operationId,
        roomToken: ConversationToken.parse(
          row.roomToken,
          path: r'$.textSendOperations.roomToken',
        ),
        referenceId: ChatReferenceId.parse(row.referenceId),
        message: row.message,
        replayContractRevision: row.replayContractRevision,
        enqueueSequence: row.enqueueSequence,
        state: _outboxState(row.outboxState),
        attemptCount: row.attemptCount,
        messageIds: _decodeMessageIds(row.messageIdsJson),
        duplicateRiskAcknowledged: row.duplicateRiskAcknowledged,
        errorClass: row.errorClass,
        nextAttemptAt: row.nextAttemptAt,
        replyTo: row.replyTo,
        threadId: row.threadId,
        replyToToken: row.replyToToken == null
            ? null
            : ConversationToken.parse(
                row.replyToToken,
                path: r'$.textSendOperations.replyToToken',
              ),
        parentRoomToken: row.parentRoomToken == null
            ? null
            : ConversationToken.parse(
                row.parentRoomToken,
                path: r'$.textSendOperations.parentRoomToken',
              ),
      );
    }

    final typedAccountId = AccountId.parse(accountId);
    return ChatRuntimeSnapshot(
      accounts: {
        typedAccountId: ChatAccountState(
          accountId: typedAccountId,
          server: ServerBase.parse(account.serverUrl),
          lane: _accountLane(capability.lane),
          credentialGeneration: capability.credentialGeneration,
          capabilityGeneration: capability.generation,
          scopes: scopes,
          operations: operations,
        ),
      },
    );
  }

  Future<void> _persistAccount(
    ChatAccountState account, {
    Iterable<ChatMessage> messages = const [],
    ChatScopeKey? syncedScope,
  }) async {
    await (_database.update(
      _database.chatCapabilities,
    )..where((row) => row.accountId.equals(account.accountId.value))).write(
      ChatCapabilitiesCompanion(
        generation: Value(account.capabilityGeneration),
        credentialGeneration: Value(account.credentialGeneration),
        lane: Value(account.lane.name),
        updatedAtMillis: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
      ),
    );

    final syncedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final entry in account.scopes.entries) {
      final key = entry.key;
      final scope = entry.value;
      final wasSynced = syncedScope == key;
      await _database
          .into(_database.chatScopes)
          .insertOnConflictUpdate(
            ChatScopesCompanion.insert(
              accountId: account.accountId.value,
              roomToken: key.roomToken.value,
              scopeKey: _scopeKey(key.threadId),
              threadId: Value(key.threadId),
              historyCursor: scope.historyCursor.value,
              futureCursor: scope.futureCursor.value,
              lastCommonRead: scope.lastCommonRead.value,
              lastReadMessage: scope.lastReadMessage,
              unreadMessages: scope.unreadMessages,
              hasHistory: scope.hasHistory,
              futureConverged: scope.futureConverged,
              blocksJson: jsonEncode(
                scope.blocks
                    .map((block) => [block.start.value, block.end.value])
                    .toList(growable: false),
              ),
              lastSyncedAtMillis: wasSynced
                  ? Value(syncedAt)
                  : const Value.absent(),
              lastSyncError: wasSynced
                  ? const Value(null)
                  : const Value.absent(),
            ),
          );
    }

    for (final operation in account.operations.values) {
      final existing =
          await (_database.select(_database.textSendOperations)..where(
                (row) =>
                    row.accountId.equals(account.accountId.value) &
                    row.operationId.equals(operation.operationId.value),
              ))
              .getSingleOrNull();
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _database
          .into(_database.textSendOperations)
          .insertOnConflictUpdate(
            TextSendOperationsCompanion.insert(
              accountId: account.accountId.value,
              operationId: operation.operationId.value,
              roomToken: operation.roomToken.value,
              referenceId: operation.referenceId.value,
              message: operation.message,
              replayContractRevision: operation.replayContractRevision,
              enqueueSequence: operation.enqueueSequence,
              outboxState: operation.state.name,
              attemptCount: operation.attemptCount,
              messageIdsJson: jsonEncode(operation.messageIds),
              duplicateRiskAcknowledged: operation.duplicateRiskAcknowledged,
              errorClass: Value(operation.errorClass),
              nextAttemptAt: Value(operation.nextAttemptAt),
              replyTo: Value(operation.replyTo),
              threadId: Value(operation.threadId),
              replyToToken: Value(operation.replyToToken?.value),
              parentRoomToken: Value(operation.parentRoomToken?.value),
              createdAtMillis: existing?.createdAtMillis ?? now,
              updatedAtMillis: now,
            ),
          );
    }

    final messageList = messages.toList(growable: false);
    final threadReplyAccumulators = await _loadThreadReplyAccumulators(
      account,
      messageList,
    );
    for (final message in messageList) {
      await _refreshThreadOriginalFromNamedSend(account, message);
      await _refreshThreadOriginalFromParent(
        account,
        message,
        threadReplyAccumulators,
      );
      await _persistMessage(account, message);
    }
  }

  Future<Map<_ThreadReplyScope, _ThreadReplyAccumulator>>
  _loadThreadReplyAccumulators(
    ChatAccountState account,
    List<ChatMessage> messages,
  ) async {
    final accountId = account.accountId.value;
    final fallbackScopes = <_ThreadReplyScope>{};
    for (final message in messages) {
      final parent = _matchingThreadParent(message);
      if (parent != null && parent.message.threadReplies == null) {
        fallbackScopes.add((
          accountId: accountId,
          roomToken: message.roomToken.value,
          threadId: message.threadId!,
        ));
      }
    }
    if (fallbackScopes.isEmpty) {
      return const <_ThreadReplyScope, _ThreadReplyAccumulator>{};
    }

    final incomingReplyIds = <_ThreadReplyScope, Set<int>>{
      for (final scope in fallbackScopes) scope: <int>{},
    };
    for (final message in messages) {
      final threadId = message.threadId;
      if (threadId == null || threadId < 1 || message.messageId == threadId) {
        continue;
      }
      final scope = (
        accountId: accountId,
        roomToken: message.roomToken.value,
        threadId: threadId,
      );
      incomingReplyIds[scope]?.add(message.messageId);
    }

    final messageIdColumn = _database.cachedChatMessages.messageId;
    final rawJsonColumn = _database.cachedChatMessages.rawJson;
    final accumulators = <_ThreadReplyScope, _ThreadReplyAccumulator>{};
    for (final scope in fallbackScopes) {
      final rows =
          await (_database.selectOnly(_database.cachedChatMessages)
                ..addColumns([messageIdColumn, rawJsonColumn])
                ..where(
                  _database.cachedChatMessages.accountId.equals(
                        scope.accountId,
                      ) &
                      _database.cachedChatMessages.roomToken.equals(
                        scope.roomToken,
                      ) &
                      _database.cachedChatMessages.threadId.equals(
                        scope.threadId,
                      ),
                ))
              .get();
      final replyIds = incomingReplyIds[scope]!;
      int? cachedCountFloor;
      for (final row in rows) {
        final messageId = row.read(messageIdColumn);
        if (messageId == null) {
          continue;
        }
        if (messageId == scope.threadId) {
          final rawJson = row.read(rawJsonColumn);
          cachedCountFloor = rawJson == null
              ? null
              : _storedThreadReplyCount(rawJson);
        } else {
          replyIds.add(messageId);
        }
      }
      accumulators[scope] = _ThreadReplyAccumulator(
        replyIds: replyIds,
        cachedCountFloor: cachedCountFloor,
      );
    }
    return accumulators;
  }

  Future<void> _refreshThreadOriginalFromNamedSend(
    ChatAccountState account,
    ChatMessage message,
  ) async {
    final threadId = message.threadId;
    final threadReplies = message.threadReplies;
    if (threadId == null ||
        message.messageId == threadId ||
        message.parent != null ||
        threadReplies == null) {
      return;
    }
    final accountId = account.accountId.value;
    final root =
        await (_database.select(_database.cachedChatMessages)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.roomToken.equals(message.roomToken.value) &
                  row.messageId.equals(threadId),
            ))
            .getSingleOrNull();
    if (root == null) {
      return;
    }
    final original = ChatMessage.fromJson(jsonDecode(root.rawJson));
    if (original.messageId != threadId ||
        original.roomToken != message.roomToken) {
      return;
    }
    final originalWire = Map<String, Object?>.of(original.wire)
      ..['threadId'] = threadId
      ..['isThread'] = true
      ..['threadReplies'] = threadReplies;
    await (_database.update(_database.cachedChatMessages)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.roomToken.equals(message.roomToken.value) &
              row.messageId.equals(threadId),
        ))
        .write(
          CachedChatMessagesCompanion(
            threadId: Value(threadId),
            rawJson: Value(jsonEncode(originalWire)),
          ),
        );
  }

  Future<void> _refreshThreadOriginalFromParent(
    ChatAccountState account,
    ChatMessage message,
    Map<_ThreadReplyScope, _ThreadReplyAccumulator> replyAccumulators,
  ) async {
    final parent = _matchingThreadParent(message);
    if (parent == null) {
      return;
    }

    final accountId = account.accountId.value;
    final threadId = message.threadId!;
    final original = parent.message;
    final serverCount = original.threadReplies;
    final accumulator =
        replyAccumulators[(
          accountId: accountId,
          roomToken: message.roomToken.value,
          threadId: threadId,
        )];
    final threadReplies = serverCount == null
        ? accumulator!.resolve(null)
        : accumulator?.resolve(serverCount) ?? serverCount;
    final originalWire = Map<String, Object?>.of(original.wire)
      ..['threadReplies'] = threadReplies;
    final displayText = _displayText(account, original);
    await (_database.update(_database.cachedChatMessages)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.roomToken.equals(message.roomToken.value) &
              row.messageId.equals(threadId) &
              row.threadId.equals(threadId),
        ))
        .write(
          CachedChatMessagesCompanion(
            actorType: Value(original.actorType),
            actorId: Value(original.actorId),
            actorDisplayName: Value(original.actorDisplayName),
            timestamp: Value(original.timestamp),
            systemMessage: Value(original.systemMessage),
            messageType: Value(original.messageType),
            referenceId: Value(original.referenceId),
            displayText: Value(displayText),
            deleted: Value(original.deleted),
            threadId: Value(threadId),
            rawJson: Value(jsonEncode(originalWire)),
          ),
        );
  }

  String _displayText(ChatAccountState account, ChatMessage message) {
    if (message.deleted) {
      return '';
    }
    final displayText = renderRichChatMessage(
      message: message.message,
      markdownEnabled: message.markdown ?? false,
      parameters: message.messageParameters,
      server: account.server,
    ).root.flattenedText.trim();
    return normalizeGiphyReferencePreview(displayText);
  }

  Future<void> _persistMessage(
    ChatAccountState account,
    ChatMessage message,
  ) async {
    final displayText = _displayText(account, message);
    await _database
        .into(_database.cachedChatMessages)
        .insertOnConflictUpdate(
          CachedChatMessagesCompanion.insert(
            accountId: account.accountId.value,
            roomToken: message.roomToken.value,
            messageId: message.messageId,
            actorType: message.actorType,
            actorId: message.actorId,
            actorDisplayName: message.actorDisplayName,
            timestamp: message.timestamp,
            systemMessage: message.systemMessage,
            messageType: message.messageType,
            referenceId: message.referenceId,
            displayText: displayText,
            deleted: message.deleted,
            threadId: Value(message.threadId),
            rawJson: jsonEncode(message.wire),
          ),
        );

    final conversation = await getConversation(
      accountId: account.accountId.value,
      roomToken: message.roomToken.value,
    );
    if (conversation == null ||
        (conversation.lastMessageTimestamp ?? -1) > message.timestamp) {
      return;
    }
    await (_database.update(_database.cachedConversations)..where(
          (row) =>
              row.accountId.equals(account.accountId.value) &
              row.token.equals(message.roomToken.value),
        ))
        .write(
          CachedConversationsCompanion(
            lastActivity: Value(message.timestamp),
            lastMessageText: Value(displayText.isEmpty ? null : displayText),
            lastMessageTimestamp: Value(message.timestamp),
          ),
        );
  }

  Future<StoredChatScope?> _rootScope({
    required String accountId,
    required String roomToken,
  }) => _scope(accountId: accountId, roomToken: roomToken, threadId: null);

  Future<StoredChatScope?> _scope({
    required String accountId,
    required String roomToken,
    required int? threadId,
  }) {
    return (_database.select(_database.chatScopes)..where(
          (scope) =>
              scope.accountId.equals(accountId) &
              scope.roomToken.equals(roomToken) &
              scope.scopeKey.equals(_scopeKey(threadId)),
        ))
        .getSingleOrNull();
  }
}

typedef _ThreadReplyScope = ({
  String accountId,
  String roomToken,
  int threadId,
});

final class _ThreadReplyAccumulator {
  _ThreadReplyAccumulator({
    required this.replyIds,
    required this.cachedCountFloor,
  });

  final Set<int> replyIds;
  int? cachedCountFloor;

  int resolve(int? serverCount) {
    if (serverCount != null) {
      cachedCountFloor = serverCount;
      return serverCount;
    }
    final floor = cachedCountFloor;
    final resolved = floor != null && floor > replyIds.length
        ? floor
        : replyIds.length;
    cachedCountFloor = resolved;
    return resolved;
  }
}

ChatFullParent? _matchingThreadParent(ChatMessage message) {
  final threadId = message.threadId;
  final parent = message.parent;
  if (threadId == null ||
      threadId < 1 ||
      parent is! ChatFullParent ||
      parent.messageId != threadId ||
      parent.roomToken != message.roomToken ||
      parent.message.threadId != threadId) {
    return null;
  }
  return parent;
}

int? _storedThreadReplyCount(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is Map<String, Object?>) {
      final value = decoded['threadReplies'];
      if (value is int && value >= 0) {
        return value;
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

ChatSendRequest _restoreSendRequest({
  required ChatAccountState account,
  required TextSendOutboxOperation operation,
  required ChatTextSendAuthority authority,
  required ChatRequestId requestId,
}) {
  return ChatSendRequest.restored(
    accountId: account.accountId,
    requestId: requestId,
    server: account.server,
    roomToken: operation.roomToken,
    operationId: operation.operationId,
    profile: authority.profile,
    message: operation.message,
    referenceId: operation.referenceId,
    replyTo: operation.replyTo,
    threadId: operation.threadId,
    parentRoomToken: operation.parentRoomToken,
    replyToToken: operation.replyToToken,
  );
}

List<ChatBlock> _decodeBlocks(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! List<Object?> || decoded.isEmpty) {
    throw StateError('Stored chat blocks are invalid');
  }
  return decoded
      .map((raw) {
        if (raw is! List<Object?> || raw.length != 2) {
          throw StateError('Stored chat block is invalid');
        }
        return ChatBlock(
          start: ChatCursor.parse(raw[0]),
          end: ChatCursor.parse(raw[1]),
        );
      })
      .toList(growable: false);
}

List<int> _decodeMessageIds(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! List<Object?> || decoded.any((value) => value is! int)) {
    throw StateError('Stored outbox message IDs are invalid');
  }
  return decoded.cast<int>();
}

TextSendOutboxState _outboxState(String value) {
  return TextSendOutboxState.values.firstWhere(
    (state) => state.name == value,
    orElse: () => throw StateError('Stored outbox state is invalid'),
  );
}

final class _OutgoingTextMessageAccumulator {
  _OutgoingTextMessageAccumulator(
    this.operation, {
    required this.lastCommonRead,
  }) : confirmedMessageIds = _decodeMessageIds(
         operation.messageIdsJson,
       ).toSet();

  final StoredTextSendOperation operation;
  final ChatCursor? lastCommonRead;
  final Set<int> confirmedMessageIds;
  final Map<int, CachedChatMessage> confirmedMessages = {};

  StoredOutgoingTextMessage build() {
    final messages = confirmedMessages.values.toList(growable: false)
      ..sort((left, right) => left.messageId.compareTo(right.messageId));
    return StoredOutgoingTextMessage(
      operation: operation,
      confirmedMessages: messages,
      lastCommonRead: lastCommonRead,
    );
  }
}

ChatAccountLane _accountLane(String value) {
  return ChatAccountLane.values.firstWhere(
    (lane) => lane.name == value,
    orElse: () => throw StateError('Stored chat account lane is invalid'),
  );
}

String _scopeKey(int? threadId) =>
    threadId == null ? _rootScopeKey : 'thread:$threadId';
