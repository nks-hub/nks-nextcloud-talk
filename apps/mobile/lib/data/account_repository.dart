import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../core/giphy_reference.dart';
import 'app_database.dart';

final class AccountRepository {
  const AccountRepository(this._database);

  final AppDatabase _database;

  Stream<List<StoredAccount>> watchAccounts() => _accountsQuery().watch();

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
    return query.watchSingleOrNull();
  }

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
    return query.watchSingleOrNull().map(
      (row) => row?.readTable(_database.accountThemes).seedColor,
    );
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

  /// Drops a conversation from the cache once the server no longer has it, so
  /// the list does not keep showing a room that is gone until the next sync.
  // ponytail: the conversation row only; cached chat rows for the room are
  // unreachable without it and the next full merge is what prunes them.
  Future<void> removeConversation({
    required String accountId,
    required String token,
  }) {
    return (_database.delete(_database.cachedConversations)..where(
          (conversation) =>
              conversation.accountId.equals(accountId) &
              conversation.token.equals(token),
        ))
        .go();
  }

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
    final sorted = talkFeatures.toList()..sort();
    return _database.transaction(() async {
      await (_database.update(
        _database.accounts,
      )..where((account) => account.id.equals(accountId))).write(
        AccountsCompanion(talkFeaturesJson: Value(jsonEncode(sorted))),
      );
      await _replaceThemeColor(accountId, serverThemeColor);
    });
  }

  Future<void> _replaceThemeColor(String accountId, String? color) async {
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

      await (_database.delete(
        _database.accountThemes,
      )..where((theme) => theme.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.callLifecycleSessions,
      )..where((session) => session.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.callSessions,
      )..where((session) => session.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.attachmentJobs,
      )..where((job) => job.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.attachmentRuntimeAccounts,
      )..where((runtime) => runtime.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.chatDrafts,
      )..where((draft) => draft.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.textSendOperations,
      )..where((operation) => operation.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.cachedChatMessages,
      )..where((message) => message.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.cachedThreads,
      )..where((thread) => thread.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.chatScopes,
      )..where((scope) => scope.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.chatCapabilities,
      )..where((capability) => capability.accountId.equals(accountId))).go();
      await (_database.delete(
        _database.conversationAvatars,
      )..where((avatar) => avatar.accountId.equals(accountId))).go();
      await (_database.delete(_database.cachedConversations)
            ..where((conversation) => conversation.accountId.equals(accountId)))
          .go();
      await (_database.delete(
        _database.accounts,
      )..where((account) => account.id.equals(accountId))).go();

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
      await _database.transaction(() async {
        for (final token in invalidTokens) {
          await (_database.delete(_database.cachedConversations)..where(
                (conversation) =>
                    conversation.accountId.equals(account.id) &
                    conversation.token.equals(token),
              ))
              .go();
        }
      });
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
      for (final room in plan.upserts) {
        await _upsertConversation(plan.accountId.value, room);
      }
      for (final token in plan.deleteTokens) {
        await (_database.delete(_database.cachedConversations)..where(
              (conversation) =>
                  conversation.accountId.equals(plan.accountId.value) &
                  conversation.token.equals(token.value),
            ))
            .go();
      }

      final next = plan.nextAccountState;
      await (_database.update(
        _database.accounts,
      )..where((account) => account.id.equals(plan.accountId.value))).write(
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
        .insertOnConflictUpdate(
          CachedConversationsCompanion.insert(
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
          ),
        );
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
