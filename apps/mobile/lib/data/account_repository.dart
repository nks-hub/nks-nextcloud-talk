import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../core/giphy_reference.dart';
import 'app_database.dart';

final class AccountRepository {
  const AccountRepository(this._database);

  final AppDatabase _database;

  /// Emits only when something a screen shows changed: the sync bookkeeping
  /// columns are blanked, because every sync rewrites them and would otherwise
  /// repaint the whole app. Services read them through [getAccount].
  Stream<List<StoredAccount>> watchAccounts() => _accountsQuery()
      .watch()
      .map((accounts) => accounts.map(_withoutSyncBookkeeping).toList())
      .distinct(listEquals);

  /// One-shot read of the rows [watchAccounts] streams.
  ///
  /// A caller that only needs the list once must use this rather than
  /// `watchAccounts().first`: a live Drift query resolves on its own timers,
  /// and under a widget test's fake clock those never fire, so the future
  /// never completes.
  Future<List<StoredAccount>> listAccounts() => _accountsQuery().get();

  MultiSelectable<StoredAccount> _accountsQuery() {
    return _database.select(_database.accounts)..orderBy([
      (account) => OrderingTerm.desc(account.selected),
      (account) => OrderingTerm.asc(account.createdAtMillis),
    ]);
  }

  Stream<StoredAccount?> watchSelectedAccount() {
    final query = _database.select(_database.accounts)
      ..where((account) => account.selected.equals(true))
      ..limit(1);
    return query
        .watchSingleOrNull()
        .map(
          (account) =>
              account == null ? null : _withoutSyncBookkeeping(account),
        )
        .distinct();
  }

  static StoredAccount _withoutSyncBookkeeping(StoredAccount account) =>
      account.copyWith(
        conversationCursor: const Value(null),
        conversationHash: const Value(null),
        emptyConfirmationRequestId: const Value(null),
        emptyConfirmationObservedAtMillis: const Value(null),
        lastSyncedAtMillis: const Value(null),
      );

  Stream<String?> watchSelectedThemeColor() {
    final query =
        _database.select(_database.accountThemes).join([
            innerJoin(
              _database.accounts,
              _database.accounts.id.equalsExp(
                _database.accountThemes.accountId,
              ),
            ),
          ])
          ..where(_database.accounts.selected.equals(true))
          ..limit(1);
    return query
        .watchSingleOrNull()
        .map((row) => row?.readTable(_database.accountThemes).seedColor)
        .distinct();
  }

  /// Every certificate any account trusts, grouped by lowercase host.
  ///
  /// Grouped by host rather than by account because the TLS handshake only
  /// knows which server it reached. Two accounts on one self-hosted server
  /// therefore share what either of them confirmed, while a pin still never
  /// reaches a host nobody confirmed it for.
  Future<Map<String, Set<String>>> readCertificatePins() async {
    final rows = await _database.select(_database.certificatePins).get();
    final pins = <String, Set<String>>{};
    for (final row in rows) {
      pins
          .putIfAbsent(row.host.toLowerCase(), () => <String>{})
          .add(row.fingerprint);
    }
    return pins;
  }

  Stream<List<CachedConversation>> watchConversations(String accountId) {
    final query = _database.select(_database.cachedConversations)
      ..where((conversation) => conversation.accountId.equals(accountId))
      ..orderBy([
        (conversation) => OrderingTerm.desc(conversation.favorite),
        (conversation) => OrderingTerm.desc(conversation.lastActivity),
      ]);
    return query.watch();
  }

  /// Reads one room token without opening a live query or loading room JSON.
  Future<String?> getAnyConversationToken(String accountId) async {
    final token = _database.cachedConversations.token;
    final query = _database.selectOnly(_database.cachedConversations)
      ..addColumns([token])
      ..where(_database.cachedConversations.accountId.equals(accountId))
      ..limit(1);
    return (await query.getSingleOrNull())?.read(token);
  }

  /// Unread messages per account, summed in the database so the badge does not
  /// load every conversation row (and its JSON) of every account. Accounts
  /// without conversations are absent.
  Stream<Map<String, int>> watchUnreadCounts() {
    final accountId = _database.cachedConversations.accountId;
    final unread = _database.cachedConversations.unreadMessages.sum();
    final query = _database.selectOnly(_database.cachedConversations)
      ..addColumns([accountId, unread])
      ..groupBy([accountId]);
    return query
        .watch()
        .map(
          (rows) => {
            for (final row in rows) row.read(accountId)!: row.read(unread) ?? 0,
          },
        )
        .distinct(mapEquals);
  }

  Future<CachedConversation?> getConversation({
    required String accountId,
    required String token,
  }) {
    final query = _database.select(_database.cachedConversations)
      ..where(
        (conversation) =>
            conversation.accountId.equals(accountId) &
            conversation.token.equals(token),
      );
    return query.getSingleOrNull();
  }

  /// Reads display names for several rooms without loading their JSON bodies.
  Future<Map<String, String>> getConversationNames({
    required String accountId,
    required Set<String> tokens,
  }) async {
    if (tokens.isEmpty) {
      return const <String, String>{};
    }
    const maximumTokensPerStatement = 500;
    final requested = tokens.toList(growable: false);
    final names = <String, String>{};
    for (
      var offset = 0;
      offset < requested.length;
      offset += maximumTokensPerStatement
    ) {
      final end = offset + maximumTokensPerStatement < requested.length
          ? offset + maximumTokensPerStatement
          : requested.length;
      final chunk = requested.sublist(offset, end);
      final token = _database.cachedConversations.token;
      final displayName = _database.cachedConversations.displayName;
      final rows =
          await (_database.selectOnly(_database.cachedConversations)
                ..addColumns([token, displayName])
                ..where(
                  _database.cachedConversations.accountId.equals(accountId) &
                      token.isIn(chunk),
                ))
              .get();
      for (final row in rows) {
        names[row.read(token)!] = row.read(displayName)!;
      }
    }
    return names;
  }

  /// Drops a conversation from the cache once the server no longer has it, so
  /// the list does not keep showing a room that is gone until the next sync.
  // ponytail: the conversation row only; cached chat rows for the room are
  // unreachable without it and the next full merge is what prunes them.
  Future<void> removeConversation({
    required String accountId,
    required String token,
  }) => removeConversations(accountId: accountId, tokens: [token]);

  /// Drops several conversations with bounded statements instead of one
  /// database round trip per room.
  Future<void> removeConversations({
    required String accountId,
    required Iterable<String> tokens,
  }) => _deleteConversations(accountId, tokens.toSet());

  Future<StoredAccount?> getAccount(String accountId) {
    final query = _database.select(_database.accounts)
      ..where((account) => account.id.equals(accountId));
    return query.getSingleOrNull();
  }

  Future<StoredAccount?> findByIdentity({
    required String serverUrl,
    required String loginName,
  }) {
    final query = _database.select(_database.accounts)
      ..where(
        (account) =>
            account.serverUrl.equals(serverUrl) &
            account.loginName.equals(loginName),
      );
    return query.getSingleOrNull();
  }

  Future<StoredAccount> upsertAccount({
    required String accountId,
    required String serverUrl,
    required String loginName,
    required String serverProductName,
    required DateTime createdAt,
    Set<String> talkFeatures = const {},
    String? serverThemeColor,
    String? certificateFingerprint,
  }) async {
    final sortedTalkFeatures = talkFeatures.toList()..sort();
    return _database.transaction(() async {
      await _database
          .update(_database.accounts)
          .write(const AccountsCompanion(selected: Value(false)));
      await _database
          .into(_database.accounts)
          .insertOnConflictUpdate(
            AccountsCompanion.insert(
              id: accountId,
              serverUrl: serverUrl,
              loginName: loginName,
              serverProductName: serverProductName,
              talkFeaturesJson: Value(jsonEncode(sortedTalkFeatures)),
              selected: const Value(true),
              createdAtMillis: createdAt.toUtc().millisecondsSinceEpoch,
              lastSyncError: const Value(null),
            ),
          );
      await _replaceThemeColor(accountId, serverThemeColor);
      if (certificateFingerprint != null) {
        final host = Uri.parse(serverUrl).host.toLowerCase();
        if (host.isNotEmpty) {
          await _database
              .into(_database.certificatePins)
              .insertOnConflictUpdate(
                CertificatePinsCompanion.insert(
                  accountId: accountId,
                  host: host,
                  fingerprint: certificateFingerprint,
                ),
              );
        }
      }
      final account = await getAccount(accountId);
      if (account == null) {
        throw StateError('Upserted account is missing');
      }
      return account;
    });
  }

  Future<void> updateTalkFeatures(String accountId, Set<String> talkFeatures) {
    final sorted = talkFeatures.toList()..sort();
    return (_database.update(_database.accounts)
          ..where((account) => account.id.equals(accountId)))
        .write(AccountsCompanion(talkFeaturesJson: Value(jsonEncode(sorted))));
  }

  Future<void> updateCapabilities(
    String accountId,
    Set<String> talkFeatures, {
    required String? serverThemeColor,
  }) {
    final json = jsonEncode(talkFeatures.toList()..sort());
    return _database.transaction(() async {
      // Called on every sync; an unchanged write would still wake every
      // account watcher.
      final stored = await getAccount(accountId);
      if (stored != null && stored.talkFeaturesJson != json) {
        await (_database.update(_database.accounts)
              ..where((account) => account.id.equals(accountId)))
            .write(AccountsCompanion(talkFeaturesJson: Value(json)));
      }
      await _replaceThemeColor(accountId, serverThemeColor);
    });
  }

  Future<void> _replaceThemeColor(String accountId, String? color) async {
    final stored = await (_database.select(
      _database.accountThemes,
    )..where((theme) => theme.accountId.equals(accountId))).getSingleOrNull();
    if (stored?.seedColor == color) {
      return;
    }
    if (color == null) {
      await (_database.delete(
        _database.accountThemes,
      )..where((theme) => theme.accountId.equals(accountId))).go();
      return;
    }
    await _database
        .into(_database.accountThemes)
        .insertOnConflictUpdate(
          AccountThemesCompanion.insert(accountId: accountId, seedColor: color),
        );
  }

  Future<void> selectAccount(String accountId) async {
    await _database.transaction(() async {
      final exists = await getAccount(accountId);
      if (exists == null) {
        throw StateError('Account does not exist');
      }
      await _database
          .update(_database.accounts)
          .write(const AccountsCompanion(selected: Value(false)));
      await (_database.update(_database.accounts)
            ..where((account) => account.id.equals(accountId)))
          .write(const AccountsCompanion(selected: Value(true)));
    });
  }

  /// Deletes every row belonging to [accountId] and returns the durable
  /// attachment source handles the removed upload jobs pointed at, so the
  /// caller can drop the copied files those handles still keep on disk.
  ///
  /// Every account-scoped table is listed here on purpose instead of relying
  /// on `ON DELETE CASCADE`. Two of them ([AttachmentRuntimeAccounts] and
  /// [AttachmentJobs]) have no cascade at all, `PRAGMA foreign_keys` is off in
  /// tests, and a future table added without a cascade would otherwise leak an
  /// account's data silently. A removal that misses a table is a broken
  /// security promise, not a stale cache.
  ///
  /// If the removed account was the selected one and others remain, the oldest
  /// survivor is selected so the app never ends up with accounts but no active
  /// one. Removing the last account deliberately leaves nothing selected: that
  /// is what returns the shell to onboarding.
  Future<List<String>> purgeAccount(String accountId) {
    return _database.transaction(() async {
      final sourceHandles =
          await (_database.selectOnly(_database.attachmentJobs)
                ..addColumns([_database.attachmentJobs.sourceHandle])
                ..where(_database.attachmentJobs.accountId.equals(accountId)))
              .map((row) => row.read(_database.attachmentJobs.sourceHandle)!)
              .get();

      final wasSelected = (await getAccount(accountId))?.selected ?? false;

      await _database.batch((batch) {
        batch.deleteWhere(
          _database.accountThemes,
          (theme) => theme.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.callLifecycleSessions,
          (session) => session.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.callSessions,
          (session) => session.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.attachmentJobs,
          (job) => job.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.attachmentRuntimeAccounts,
          (runtime) => runtime.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.chatDrafts,
          (draft) => draft.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.textSendOperations,
          (operation) => operation.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.cachedChatMessages,
          (message) => message.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.cachedThreads,
          (thread) => thread.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.chatScopes,
          (scope) => scope.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.chatCapabilities,
          (capability) => capability.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.conversationAvatars,
          (avatar) => avatar.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.cachedConversations,
          (conversation) => conversation.accountId.equals(accountId),
        );
        batch.deleteWhere(
          _database.accounts,
          (account) => account.id.equals(accountId),
        );
      });

      if (wasSelected) {
        final successor =
            await (_database.select(_database.accounts)
                  ..orderBy([
                    (account) => OrderingTerm.asc(account.createdAtMillis),
                  ])
                  ..limit(1))
                .getSingleOrNull();
        if (successor != null) {
          await (_database.update(_database.accounts)
                ..where((account) => account.id.equals(successor.id)))
              .write(const AccountsCompanion(selected: Value(true)));
        }
      }

      return sourceHandles;
    });
  }

  Future<ConversationAccountState> loadConversationState(
    StoredAccount account,
  ) async {
    final cached =
        await (_database.select(_database.cachedConversations)..where(
              (conversation) => conversation.accountId.equals(account.id),
            ))
            .get();
    return _conversationStateFromRows(account, cached);
  }

  /// Conversation sync metadata without reading or decoding cached rooms.
  ///
  /// Incremental responses can be empty, in which case the merge only moves
  /// the cursor and hash. Loading every room before that response made each
  /// foreground poll scale with the account's lifetime room count.
  Future<ConversationAccountState> loadConversationSyncMetadata(
    StoredAccount account,
  ) => _conversationStateFromRows(account, const <CachedConversation>[]);

  /// Sync state containing only the cached rooms named by [tokens].
  ///
  /// A non-empty incremental response needs prior values only for the rooms it
  /// updates (notably to preserve user status omitted by a delta). Full syncs
  /// continue to use [loadConversationState] for authoritative deletion and
  /// suspicious-empty protection.
  Future<ConversationAccountState> loadConversationStateForTokens(
    StoredAccount account,
    Iterable<String> tokens, {
    ConversationAccountState? metadata,
  }) async {
    const maximumTokensPerStatement = 500;
    final remaining = tokens.toSet();
    final cached = <CachedConversation>[];
    while (remaining.isNotEmpty) {
      final chunk = remaining
          .take(maximumTokensPerStatement)
          .toList(growable: false);
      remaining.removeAll(chunk);
      cached.addAll(
        await (_database.select(_database.cachedConversations)..where(
              (conversation) =>
                  conversation.accountId.equals(account.id) &
                  conversation.token.isIn(chunk),
            ))
            .get(),
      );
    }
    return _conversationStateFromRows(account, cached, metadata: metadata);
  }

  Future<ConversationAccountState> _conversationStateFromRows(
    StoredAccount account,
    List<CachedConversation> cached, {
    ConversationAccountState? metadata,
  }) async {
    final rooms = <ConversationRoom>[];
    final invalidTokens = <String>[];
    Object? firstFailure;
    for (final conversation in cached) {
      try {
        rooms.add(ConversationRoom.fromJson(jsonDecode(conversation.rawJson)));
      } on Object catch (error) {
        firstFailure ??= error;
        invalidTokens.add(conversation.token);
      }
    }
    if (invalidTokens.isNotEmpty) {
      // Loudly, because the next line DELETES these rows. One damaged row is
      // ordinary; a change to what `ConversationRoom.fromJson` accepts fails
      // every row at once and empties the whole cache, and from the outside
      // that looks like "the sync returns nothing" rather than like a parser
      // that stopped agreeing with the database. The count is what tells the
      // two apart, so it is logged with the first reason.
      debugPrint(
        '[accounts] dropping ${invalidTokens.length} of ${cached.length} '
        'cached conversations for ${account.id}: $firstFailure',
      );
      await _database.transaction(
        () => _deleteConversations(account.id, invalidTokens),
      );
    }

    if (metadata != null) {
      return ConversationAccountState(
        server: metadata.server,
        rooms: rooms,
        cursor: metadata.cursor,
        configurationHash: metadata.configurationHash,
        emptyConfirmation: metadata.emptyConfirmation,
        capabilityRefreshRequired: metadata.capabilityRefreshRequired,
      );
    }
    try {
      return ConversationAccountState(
        server: ServerBase.parse(account.serverUrl),
        rooms: rooms,
        cursor: account.conversationCursor == null
            ? null
            : ConversationCursor.parse(
                account.conversationCursor,
                path: r'$.cursor',
              ),
        configurationHash: account.conversationHash == null
            ? null
            : ConversationConfigurationHash.parse(
                account.conversationHash,
                path: r'$.configurationHash',
              ),
        emptyConfirmation:
            account.emptyConfirmationRequestId == null ||
                account.emptyConfirmationObservedAtMillis == null
            ? null
            : ConversationEmptyConfirmation(
                requestId: ConversationRequestId.parse(
                  account.emptyConfirmationRequestId,
                ),
                observedAt: DateTime.fromMillisecondsSinceEpoch(
                  account.emptyConfirmationObservedAtMillis!,
                  isUtc: true,
                ),
              ),
      );
    } on TalkProtocolException {
      await clearConversationSyncMetadata(account.id);
      return ConversationAccountState(
        server: ServerBase.parse(account.serverUrl),
        rooms: rooms,
      );
    }
  }

  Future<void> applyConversationMerge(ConversationMergePlan plan) async {
    await _database.transaction(() async {
      final accountId = plan.accountId.value;
      if (plan.upserts.isNotEmpty) {
        await _database.batch((batch) {
          batch.insertAllOnConflictUpdate(_database.cachedConversations, [
            for (final room in plan.upserts)
              _conversationCompanion(accountId, room),
          ]);
        });
      }
      if (plan.deleteTokens.isNotEmpty) {
        await _deleteConversations(
          accountId,
          plan.deleteTokens.map((token) => token.value),
        );
      }

      final next = plan.nextAccountState;
      await (_database.update(
        _database.accounts,
      )..where((account) => account.id.equals(accountId))).write(
        AccountsCompanion(
          conversationCursor: Value(next.cursor?.value),
          conversationHash: Value(next.configurationHash?.value),
          emptyConfirmationRequestId: Value(
            next.emptyConfirmation?.requestId.value,
          ),
          emptyConfirmationObservedAtMillis: Value(
            next.emptyConfirmation?.observedAt.millisecondsSinceEpoch,
          ),
          lastSyncedAtMillis: plan.outcome == ConversationMergeOutcome.applied
              ? Value(DateTime.now().toUtc().millisecondsSinceEpoch)
              : const Value.absent(),
          lastSyncError: plan.outcome == ConversationMergeOutcome.applied
              ? const Value(null)
              : const Value.absent(),
        ),
      );
    });
  }

  /// Persists one room returned by an authoritative mutation response without
  /// changing the conversation-list cursor or hash.
  Future<void> applyAuthoritativeConversation(
    String accountId,
    ConversationRoom room,
  ) async {
    if (room.token.value.isEmpty) {
      throw const FormatException('Invalid conversation token');
    }
    await _database.transaction(() => _upsertConversation(accountId, room));
  }

  Future<void> _upsertConversation(String accountId, ConversationRoom room) {
    return _database
        .into(_database.cachedConversations)
        .insertOnConflictUpdate(_conversationCompanion(accountId, room));
  }

  Future<void> _deleteConversations(
    String accountId,
    Iterable<String> tokens,
  ) async {
    // Keep the account id plus token binds below legacy SQLite limits.
    const maximumTokensPerStatement = 500;
    final chunk = <String>[];
    for (final token in tokens) {
      chunk.add(token);
      if (chunk.length == maximumTokensPerStatement) {
        await _deleteConversationChunk(accountId, chunk);
        chunk.clear();
      }
    }
    if (chunk.isNotEmpty) {
      await _deleteConversationChunk(accountId, chunk);
    }
  }

  Future<void> _deleteConversationChunk(String accountId, List<String> tokens) {
    return (_database.delete(_database.cachedConversations)..where(
          (conversation) =>
              conversation.accountId.equals(accountId) &
              conversation.token.isIn(tokens),
        ))
        .go();
  }

  Future<void> recordSyncError(String accountId, String errorCode) {
    return (_database.update(_database.accounts)
          ..where((account) => account.id.equals(accountId)))
        .write(AccountsCompanion(lastSyncError: Value(errorCode)));
  }

  Future<void> clearSyncError(String accountId) {
    return (_database.update(_database.accounts)
          ..where((account) => account.id.equals(accountId)))
        .write(const AccountsCompanion(lastSyncError: Value(null)));
  }

  Future<void> clearConversationSyncMetadata(String accountId) {
    return (_database.update(
      _database.accounts,
    )..where((account) => account.id.equals(accountId))).write(
      const AccountsCompanion(
        conversationCursor: Value(null),
        conversationHash: Value(null),
        emptyConfirmationRequestId: Value(null),
        emptyConfirmationObservedAtMillis: Value(null),
      ),
    );
  }
}

CachedConversationsCompanion _conversationCompanion(
  String accountId,
  ConversationRoom room,
) {
  return CachedConversationsCompanion.insert(
    accountId: accountId,
    token: room.token.value,
    displayName: room.displayName,
    description: room.description,
    lastActivity: room.lastActivity,
    unreadMessages: room.unreadMessages,
    favorite: room.isFavorite,
    isArchived: Value(room.isArchived),
    readOnly: Value(room.readOnly),
    roomType: Value(room.type),
    roomName: Value(room.name),
    objectType: Value(room.objectType),
    avatarVersion: Value(room.avatarVersion),
    isCustomAvatar: Value(room.isCustomAvatar),
    peerStatus: Value(room.status),
    peerStatusIcon: Value(room.statusIcon),
    peerStatusMessage: Value(room.statusMessage),
    peerStatusClearAt: Value(room.statusClearAt),
    lastMessageText: Value(_safePreview(room)),
    lastMessageTimestamp: Value(room.lastMessage?.timestamp),
    rawJson: jsonEncode(room.wire),
  );
}

String? _safePreview(ConversationRoom room) {
  final preview = room.lastMessage;
  if (preview == null) {
    return null;
  }
  var unknownParameter = false;
  final expanded = preview.message.replaceAllMapped(
    RegExp(r'\{([A-Za-z0-9_.-]+)\}'),
    (match) {
      final parameter = preview.messageParameters[match.group(1)];
      final replacement = parameter?.name ?? parameter?.id;
      if (replacement == null || replacement.isEmpty) {
        unknownParameter = true;
        return '';
      }
      return replacement;
    },
  );
  if (unknownParameter || expanded.contains('{') || expanded.contains('}')) {
    return null;
  }
  final normalized = expanded.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) {
    return null;
  }
  final previewText = normalizeGiphyReferencePreview(normalized);
  return String.fromCharCodes(previewText.runes.take(512));
}
