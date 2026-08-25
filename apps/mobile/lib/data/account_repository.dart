import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../core/giphy_reference.dart';
import 'app_database.dart';

final class AccountRepository {
  const AccountRepository(this._database);

  final AppDatabase _database;

  Stream<List<StoredAccount>> watchAccounts() {
    final query = _database.select(_database.accounts)
      ..orderBy([
        (account) => OrderingTerm.desc(account.selected),
        (account) => OrderingTerm.asc(account.createdAtMillis),
      ]);
    return query.watch();
  }

  Stream<StoredAccount?> watchSelectedAccount() {
    final query = _database.select(_database.accounts)
      ..where((account) => account.selected.equals(true))
      ..limit(1);
    return query.watchSingleOrNull();
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
            ),
          );
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
    for (final conversation in cached) {
      try {
        rooms.add(ConversationRoom.fromJson(jsonDecode(conversation.rawJson)));
      } on Object {
        invalidTokens.add(conversation.token);
      }
    }
    if (invalidTokens.isNotEmpty) {
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
        await _database
            .into(_database.cachedConversations)
            .insertOnConflictUpdate(
              CachedConversationsCompanion.insert(
                accountId: plan.accountId.value,
                token: room.token.value,
                displayName: room.displayName,
                description: room.description,
                lastActivity: room.lastActivity,
                unreadMessages: room.unreadMessages,
                favorite: room.isFavorite,
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

  Future<void> recordSyncError(String accountId, String errorCode) {
    return (_database.update(_database.accounts)
          ..where((account) => account.id.equals(accountId)))
        .write(AccountsCompanion(lastSyncError: Value(errorCode)));
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
