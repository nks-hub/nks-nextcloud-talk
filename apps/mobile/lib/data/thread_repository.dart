import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../core/giphy_reference.dart';
import 'app_database.dart';

final class ThreadRepository {
  const ThreadRepository(this._database);

  final AppDatabase _database;

  Stream<List<CachedThread>> watchRecent({
    required String accountId,
    required String roomToken,
  }) {
    return (_database.select(_database.cachedThreads)
          ..where(
            (thread) =>
                thread.accountId.equals(accountId) &
                thread.roomToken.equals(roomToken) &
                thread.recent.equals(true),
          )
          ..orderBy([
            (thread) => OrderingTerm.desc(thread.lastActivity),
            (thread) => OrderingTerm.desc(thread.threadId),
          ]))
        .watch();
  }

  Stream<List<CachedThread>> watchSubscribed(String accountId) {
    return (_database.select(_database.cachedThreads)
          ..where(
            (thread) =>
                thread.accountId.equals(accountId) &
                thread.subscribed.equals(true),
          )
          ..orderBy([
            (thread) => OrderingTerm.desc(thread.lastActivity),
            (thread) => OrderingTerm.desc(thread.threadId),
          ]))
        .watch();
  }

  Stream<CachedThread?> watch({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) {
    return (_database.select(_database.cachedThreads)..where(
          (thread) =>
              thread.accountId.equals(accountId) &
              thread.roomToken.equals(roomToken) &
              thread.threadId.equals(threadId),
        ))
        .watchSingleOrNull();
  }

  Future<List<CachedThread>> listAccount(String accountId) {
    return (_database.select(_database.cachedThreads)
          ..where((thread) => thread.accountId.equals(accountId))
          ..orderBy([
            (thread) => OrderingTerm.asc(thread.roomToken),
            (thread) => OrderingTerm.asc(thread.threadId),
          ]))
        .get();
  }

  Future<CachedThread?> get({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) {
    return (_database.select(_database.cachedThreads)..where(
          (thread) =>
              thread.accountId.equals(accountId) &
              thread.roomToken.equals(roomToken) &
              thread.threadId.equals(threadId),
        ))
        .getSingleOrNull();
  }

  Future<void> replaceRecent({
    required String accountId,
    required String roomToken,
    required ServerBase server,
    required List<RichChatThread> values,
  }) {
    if (values.any((thread) => thread.roomToken.value != roomToken)) {
      throw const FormatException('Recent thread room mismatch');
    }
    return _database.transaction(() async {
      final existing = await _rowsForRoom(accountId, roomToken);
      await (_database.update(_database.cachedThreads)..where(
            (thread) =>
                thread.accountId.equals(accountId) &
                thread.roomToken.equals(roomToken),
          ))
          .write(const CachedThreadsCompanion(recent: Value(false)));
      for (final value in values) {
        final current = existing[value.threadId];
        await _upsert(
          accountId: accountId,
          server: server,
          value: value,
          recent: true,
          subscribed: current?.subscribed ?? false,
          detailed: current?.detailed ?? false,
        );
      }
      await _deleteUnlisted(accountId);
    });
  }

  Future<void> replaceSubscribed({
    required String accountId,
    required ServerBase server,
    required List<RichChatThread> values,
  }) {
    return _database.transaction(() async {
      final existing = await _rowsForAccount(accountId);
      await (_database.update(_database.cachedThreads)
            ..where((thread) => thread.accountId.equals(accountId)))
          .write(const CachedThreadsCompanion(subscribed: Value(false)));
      for (final value in values) {
        final current = existing[(value.roomToken.value, value.threadId)];
        await _upsert(
          accountId: accountId,
          server: server,
          value: value,
          recent: current?.recent ?? false,
          subscribed: true,
          detailed: current?.detailed ?? false,
        );
      }
      await _deleteUnlisted(accountId);
    });
  }

  Future<void> upsertDetail({
    required String accountId,
    required ServerBase server,
    required RichChatThread value,
  }) {
    return _database.transaction(() async {
      final current = await get(
        accountId: accountId,
        roomToken: value.roomToken.value,
        threadId: value.threadId,
      );
      await _upsert(
        accountId: accountId,
        server: server,
        value: value,
        recent: current?.recent ?? false,
        subscribed: current?.subscribed ?? false,
        detailed: true,
      );
    });
  }

  Future<Map<int, CachedThread>> _rowsForRoom(
    String accountId,
    String roomToken,
  ) async {
    final rows =
        await (_database.select(_database.cachedThreads)..where(
              (thread) =>
                  thread.accountId.equals(accountId) &
                  thread.roomToken.equals(roomToken),
            ))
            .get();
    return <int, CachedThread>{for (final row in rows) row.threadId: row};
  }

  Future<Map<(String, int), CachedThread>> _rowsForAccount(
    String accountId,
  ) async {
    final rows = await (_database.select(
      _database.cachedThreads,
    )..where((thread) => thread.accountId.equals(accountId))).get();
    return <(String, int), CachedThread>{
      for (final row in rows) (row.roomToken, row.threadId): row,
    };
  }

  Future<void> _upsert({
    required String accountId,
    required ServerBase server,
    required RichChatThread value,
    required bool recent,
    required bool subscribed,
    required bool detailed,
  }) async {
    await _projectMessages(accountId: accountId, server: server, value: value);
    await _database
        .into(_database.cachedThreads)
        .insertOnConflictUpdate(
          CachedThreadsCompanion.insert(
            accountId: accountId,
            roomToken: value.roomToken.value,
            threadId: value.threadId,
            title: value.title,
            lastMessageId: value.lastMessageId,
            lastActivity: value.lastActivity,
            numReplies: value.numReplies,
            notificationLevel: value.notificationLevel,
            recent: Value(recent),
            subscribed: Value(subscribed),
            detailed: Value(detailed),
            rawJson: jsonEncode(value.wire),
          ),
        );
  }

  Future<void> _projectMessages({
    required String accountId,
    required ServerBase server,
    required RichChatThread value,
  }) async {
    final roomToken = value.roomToken.value;
    final authoritative = <int, ChatMessage>{};
    for (final message in <ChatMessage?>[
      value.firstMessage,
      value.lastMessage,
    ]) {
      if (message == null) {
        continue;
      }
      authoritative[message.messageId] = message.projectThreadTitle(
        roomToken: value.roomToken,
        threadId: value.threadId,
        threadTitle: value.title,
      );
    }

    final rows =
        await (_database.select(_database.cachedChatMessages)..where(
              (message) =>
                  message.accountId.equals(accountId) &
                  message.roomToken.equals(roomToken),
            ))
            .get();
    final persisted = <int>{};
    for (final row in rows) {
      final ChatMessage cached;
      try {
        cached = ChatMessage.fromJson(jsonDecode(row.rawJson));
      } on FormatException {
        continue;
      } on TalkProtocolException {
        continue;
      }
      var updated =
          authoritative[row.messageId] ??
          cached.projectThreadTitle(
            roomToken: value.roomToken,
            threadId: value.threadId,
            threadTitle: value.title,
          );
      for (final message in authoritative.values) {
        updated = updated.replaceParentMessageIfMatching(message);
      }
      if (!identical(updated, cached)) {
        await _persistMessage(
          accountId: accountId,
          server: server,
          message: updated,
        );
      }
      persisted.add(row.messageId);
    }
    for (final message in authoritative.values) {
      if (persisted.contains(message.messageId)) {
        continue;
      }
      await _persistMessage(
        accountId: accountId,
        server: server,
        message: message,
      );
    }
  }

  Future<void> _persistMessage({
    required String accountId,
    required ServerBase server,
    required ChatMessage message,
  }) {
    final displayText = message.deleted
        ? ''
        : normalizeGiphyReferencePreview(
            renderRichChatMessage(
              message: message.message,
              markdownEnabled: message.markdown ?? false,
              parameters: message.messageParameters,
              server: server,
            ).root.flattenedText.trim(),
          );
    return _database
        .into(_database.cachedChatMessages)
        .insertOnConflictUpdate(
          CachedChatMessagesCompanion.insert(
            accountId: accountId,
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
  }

  Future<void> _deleteUnlisted(String accountId) {
    return (_database.delete(_database.cachedThreads)..where(
          (thread) =>
              thread.accountId.equals(accountId) &
              thread.recent.equals(false) &
              thread.subscribed.equals(false) &
              thread.detailed.equals(false),
        ))
        .go();
  }
}
