import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
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

/// How long a delivered text send stays in the outbox table.
///
/// A completed row only feeds the delivery tick of its own message, and the
/// timeline derives the same tick from the server once the row is gone.
const Duration _completedTextSendRetention = Duration(days: 7);

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
  ChatRepository(this._database);

  final AppDatabase _database;
  bool _completedTextSendsPruned = false;

  /// Messages of a room, or of one thread when [threadId] is given.
  ///
  /// The server files every reply under a thread. [includeThreadReplies]
  /// keeps those replies in the room timeline as well, which is the classic
  /// quoted-reply layout; without it the room shows only thread roots and
  /// plain messages.
  Stream<List<CachedChatMessage>> watchMessages({
    required String accountId,
    required String roomToken,
    int? threadId,
    bool includeThreadReplies = false,
  }) => _watchMessagesQuery(
    accountId: accountId,
    roomToken: roomToken,
    threadId: threadId,
    includeThreadReplies: includeThreadReplies,
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

  /// Rooms that still hold a text send the outbox may deliver on its own:
  /// `queued`, `retryable` and `sending` (the last one is recovered before
  /// replay), and an ambiguous one a chat read may still prove absent from
  /// the server. Other ambiguous rows and failed ones wait for the sender.
  Future<List<({String accountId, String roomToken})>>
  roomsWithPendingTextSends() async {
    final operations = _database.textSendOperations;
    final rows =
        await (_database.selectOnly(operations, distinct: true)
              ..addColumns([operations.accountId, operations.roomToken])
              ..where(
                operations.outboxState.isIn(const [
                      'queued',
                      'retryable',
                      'sending',
                    ]) |
                    (operations.outboxState.equals(
                          TextSendOutboxState.awaitingConfirmation.name,
                        ) &
                        operations.nextAttemptAt.isNotNull() &
                        operations.messageIdsJson.equals('[]') &
                        operations.automaticResendCount.isSmallerThanValue(
                          textSendMaximumAutomaticResends,
                        )),
              ))
            .get();
    return [
      for (final row in rows)
        (
          accountId: row.read(operations.accountId)!,
          roomToken: row.read(operations.roomToken)!,
        ),
    ];
  }

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
      } else if (!await _adoptConversationReadState(
        viewScope,
        room,
        commonRead,
      )) {
        // Nothing was written, so the row just read is the row to return.
        return _ensureNetworkRootScope(viewScope, room, commonRead);
      }
      viewScope = (await _rootScope(
        accountId: account.id,
        roomToken: conversation.token,
      ))!;
      return _ensureNetworkRootScope(viewScope, room, commonRead);
    });
  }

  /// The network twin of the root scope, created from it on first use and
  /// kept on the conversation's read state afterwards.
  Future<StoredChatScope> _ensureNetworkRootScope(
    StoredChatScope viewScope,
    ConversationRoom room,
    String commonRead,
  ) async {
    final networkScope = await _networkScope(
      accountId: viewScope.accountId,
      roomToken: viewScope.roomToken,
      threadId: null,
    );
    if (networkScope == null) {
      await _migrateLegacyThreadNetworkScopesInCurrentTransaction(
        accountId: viewScope.accountId,
        roomToken: viewScope.roomToken,
      );
      await _database
          .into(_database.chatScopes)
          .insert(
            ChatScopesCompanion.insert(
              accountId: viewScope.accountId,
              roomToken: viewScope.roomToken,
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
      await _adoptConversationReadState(networkScope, room, commonRead);
    }
    return viewScope;
  }

  /// Copies the conversation's read state onto a root scope, writing only
  /// when something differs so an unchanged room wakes no watcher.
  ///
  /// The conversation row is refreshed less often than the chat itself, so its
  /// common-read marker can be older than the one a chat response has already
  /// stored. That marker never moves backwards: it would turn the read ticks
  /// of the user's own messages back into sent ones.
  Future<bool> _adoptConversationReadState(
    StoredChatScope scope,
    ConversationRoom room,
    String commonRead,
  ) async {
    final commonReadAdvanced =
        ChatCursor.parse(
          commonRead,
        ).compareTo(ChatCursor.parse(scope.lastCommonRead)) >
        0;
    if (!commonReadAdvanced &&
        scope.lastReadMessage == room.lastReadMessage &&
        scope.unreadMessages == room.unreadMessages) {
      return false;
    }
    await (_database.update(_database.chatScopes)..where(
          (row) =>
              row.accountId.equals(scope.accountId) &
              row.roomToken.equals(scope.roomToken) &
              row.scopeKey.equals(scope.scopeKey),
        ))
        .write(
          ChatScopesCompanion(
            lastCommonRead: commonReadAdvanced
                ? Value(commonRead)
                : const Value.absent(),
            lastReadMessage: Value(room.lastReadMessage),
            unreadMessages: Value(room.unreadMessages),
          ),
        );
    return true;
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
    bool silent = false,
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
          silent: silent,
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
      var snapshot = await _loadRuntime(accountId);
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
        if (result.outcome == ChatOutboxOutcome.failed && plan != null) {
          // Ended for good instead of claimed; the next candidate is tried
          // against the outbox without it.
          snapshot = plan.commit(snapshot);
          await _persistAccount(snapshot.accounts[account.accountId]!);
          continue;
        }
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
    int absenceGraceSeconds = textSendAbsenceGraceSeconds,
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
        absenceGraceSeconds: absenceGraceSeconds,
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
        messagesAreSendResponse: true,
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

  /// Stores a message the server returned for a POST that is not a text send,
  /// a shared location for one, and extends the view it was posted into.
  /// [threadId] is the named thread it went to, null for the room itself.
  ///
  /// Without this the message exists on the server and nowhere on screen
  /// until the next read of the room.
  Future<void> recordPostedMessage({
    required String accountId,
    required ChatMessage message,
    int? threadId,
  }) {
    return _database.transaction(() async {
      final account = await (_database.select(
        _database.accounts,
      )..where((row) => row.id.equals(accountId))).getSingleOrNull();
      if (account == null) {
        return;
      }
      await _applyMessageMutation(
        accountId: accountId,
        server: ServerBase.parse(account.serverUrl),
        message: message,
      );
      await _appendPostedMessageToViewInCurrentTransaction(
        accountId: accountId,
        roomToken: message.roomToken,
        replyTo: null,
        namedThreadId: threadId,
        message: message,
      );
    });
  }

  /// [now] is when the attempt ended. A body that may have left starts its
  /// grace period there; without it the send waits for the sender for good.
  Future<ChatOutboxOutcome> recordTextSendFailure({
    required String accountId,
    required ChatOperationId operationId,
    required ChatTransportBodyState bodyState,
    int? nextAttemptAt,
    int? now,
    int absenceGraceSeconds = textSendAbsenceGraceSeconds,
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
        now: now,
        absenceGraceSeconds: absenceGraceSeconds,
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

  /// Converts the sends a killed process left in `sending`.
  ///
  /// [inFlight] names the operations this process is transmitting right now,
  /// in any room of the account: those are not interrupted, and disowning
  /// one would leave its outcome with nowhere to be recorded. The set is read
  /// inside the transaction, so it may be the caller's live one.
  ///
  /// [now] starts the grace period of the converted sends; without it they
  /// wait for the sender for good.
  Future<void> recoverInterruptedTextSends(
    String accountId, {
    Set<ChatOperationId> inFlight = const <ChatOperationId>{},
    int? now,
    int absenceGraceSeconds = textSendAbsenceGraceSeconds,
  }) async {
    // Every sync asks, and almost none has anything to recover: one keyed
    // lookup answers that without loading the account's runtime.
    if (_completedTextSendsPruned &&
        !await _hasInterruptedTextSend(accountId, inFlight)) {
      return;
    }
    return _database.transaction(() async {
      // Before the snapshot is read, or a later persist would write the
      // pruned rows straight back.
      await _pruneCompletedTextSendsOnce();
      if (!await _hasInterruptedTextSend(accountId, inFlight)) {
        return;
      }
      var snapshot = await _loadRuntime(accountId);
      final typedAccountId = AccountId.parse(accountId);
      final sending = snapshot.accounts[typedAccountId]!.operations.values
          .where(
            (operation) =>
                operation.state == TextSendOutboxState.sending &&
                !inFlight.contains(operation.operationId),
          )
          .map((operation) => operation.operationId)
          .toList(growable: false);
      var changed = false;
      for (final operationId in sending) {
        final result = recoverTextSendAfterRestart(
          snapshot,
          accountId: typedAccountId,
          operationId: operationId,
          now: now,
          absenceGraceSeconds: absenceGraceSeconds,
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

  Future<bool> _hasInterruptedTextSend(
    String accountId,
    Set<ChatOperationId> inFlight,
  ) async {
    final rows = _database.textSendOperations;
    final sending =
        await (_database.selectOnly(rows)
              ..addColumns([rows.operationId])
              ..where(
                rows.accountId.equals(accountId) &
                    rows.outboxState.equals(TextSendOutboxState.sending.name),
              ))
            .map((row) => row.read(rows.operationId)!)
            .get();
    return sending.any((id) => !inFlight.contains(ChatOperationId.parse(id)));
  }

  /// The ambiguous send a chat read may still prove absent from the server,
  /// if that is what heads the room's outbox: the thread the read has to
  /// cover (null for the room itself) and the second it may start after.
  Future<({int? threadId, int verifiableAt})?> pendingAbsenceVerification({
    required String accountId,
    required String roomToken,
  }) async {
    final head = await _absenceVerificationHead(accountId, roomToken);
    return head == null
        ? null
        : (threadId: head.threadId, verifiableAt: head.nextAttemptAt!);
  }

  Future<StoredTextSendOperation?> _absenceVerificationHead(
    String accountId,
    String roomToken,
  ) async {
    final head =
        await (_database.select(_database.textSendOperations)
              ..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.roomToken.equals(roomToken) &
                    row.outboxState.isIn(const [
                      'queued',
                      'retryable',
                      'sending',
                      'awaitingConfirmation',
                    ]),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.enqueueSequence)])
              ..limit(1))
            .getSingleOrNull();
    if (head == null ||
        head.outboxState != TextSendOutboxState.awaitingConfirmation.name ||
        head.nextAttemptAt == null ||
        head.messageIdsJson != '[]' ||
        head.automaticResendCount >= textSendMaximumAutomaticResends) {
      return null;
    }
    return head;
  }

  /// Queues the room's ambiguous head-of-line send again after an HTTP read
  /// of [threadId]'s scope, begun at [readStartedAt], reached the server's
  /// newest message without it. Returns whether it was queued.
  ///
  /// Every cached message carrying the operation's reference goes to the
  /// state machine inside the same transaction, so a copy that did arrive
  /// completes the operation or stops the resend and can never lose to it.
  Future<bool> resendVerifiedAbsentTextSend({
    required String accountId,
    required ConversationToken roomToken,
    required int? threadId,
    required ChatTextSendAuthority authority,
    required int readStartedAt,
    required int now,
  }) async {
    // Every converged read asks, and almost none has such a send.
    if (await _absenceVerificationHead(accountId, roomToken.value) == null) {
      return false;
    }
    return _database.transaction(() async {
      final head = await _absenceVerificationHead(accountId, roomToken.value);
      if (head == null) {
        return false;
      }
      final snapshot = await _loadRuntime(accountId);
      final typedAccountId = AccountId.parse(accountId);
      final account = snapshot.accounts[typedAccountId]!;
      final cached =
          await (_database.select(_database.cachedChatMessages)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.roomToken.equals(roomToken.value) &
                    row.referenceId.equals(head.referenceId),
              ))
              .get();
      final List<ChatMessageConfirmation> known;
      try {
        known = [
          for (final message in cached)
            ChatMessageConfirmation.fromMessage(
              ChatMessage.fromJson(jsonDecode(message.rawJson)),
              accountId: typedAccountId,
              server: account.server,
            ),
        ];
      } on Object {
        // A copy exists and cannot be read: not a proven absence.
        return false;
      }
      final result = resendTextSendAfterVerifiedAbsence(
        snapshot,
        accountId: typedAccountId,
        authority: authority,
        operationId: ChatOperationId.parse(head.operationId),
        readThreadId: threadId,
        readStartedAt: readStartedAt,
        now: now,
        knownMessages: known,
      );
      final plan = result.plan;
      if (plan == null) {
        return false;
      }
      await _persistAccount(plan.commit(snapshot).accounts[typedAccountId]!);
      return result.outcome == ChatOutboxOutcome.queued;
    });
  }

  /// Makes the sends that never left the device due at once, for a wake that
  /// says the network may be back. A pause the server asked for is left alone.
  Future<void> expediteUnsentTextSends() {
    final rows = _database.textSendOperations;
    return (_database.update(rows)..where(
          (row) =>
              row.outboxState.equals(TextSendOutboxState.retryable.name) &
              row.errorClass.equals('transport-before-send') &
              row.nextAttemptAt.isNotNull(),
        ))
        .write(const TextSendOperationsCompanion(nextAttemptAt: Value(null)));
  }

  Future<void> _pruneCompletedTextSendsOnce() async {
    if (_completedTextSendsPruned) {
      return;
    }
    _completedTextSendsPruned = true;
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(_completedTextSendRetention)
        .millisecondsSinceEpoch;
    await (_database.delete(_database.textSendOperations)..where(
          (operation) =>
              operation.outboxState.equals(TextSendOutboxState.completed.name) &
              operation.updatedAtMillis.isSmallerThanValue(cutoff),
        ))
        .go();
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
              scope.scopeKey.equals(_scopeKey(threadId)) &
              scope.lastSyncError.isNotNull(),
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
