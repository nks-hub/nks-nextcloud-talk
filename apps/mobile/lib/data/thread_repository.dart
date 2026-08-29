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
      await _mergeCachedRootsInCurrentTransaction(accountId, roomToken);
      await _deleteUnlisted(accountId);
    });
  }

  /// Adds the threads the server's recent list leaves out.
  ///
  /// `GET /chat/{token}/threads/recent` only reports threads that were given
  /// a name. A thread started by replying to a message carries its `threadId`
  /// on every message and is a thread everywhere else in Talk, but never
  /// appears in that list - measured on the reference server, where three
  /// replies under root 77777 left `threads/recent` returning nothing while
  /// the messages themselves all carried `threadId: 77777`. The screen then
  /// showed an empty list to somebody who demonstrably had thread replies.
  ///
  /// Rows the server did list are left exactly as they are; this only fills
  /// the gap, and the count comes from the cached messages, so it is a floor
  /// rather than the server's total.
  Future<void> _mergeCachedRootsInCurrentTransaction(
    String accountId,
    String roomToken,
  ) async {
    final messages = _database.cachedChatMessages;
    final rows =
        await (_database.select(messages)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.roomToken.equals(roomToken) &
                  row.threadId.isNotNull() &
                  row.deleted.equals(false),
            ))
            .get();
    if (rows.isEmpty) {
      return;
    }
    final roots = <int, CachedChatMessage>{};
    final replies = <int, int>{};
    final lastActivity = <int, int>{};
    final lastMessage = <int, int>{};
    for (final row in rows) {
      final threadId = row.threadId!;
      if (threadId < 1) {
        continue;
      }
      if (row.messageId == threadId) {
        roots[threadId] = row;
      } else if (row.systemMessage.isEmpty) {
        // Same rule as the reply count elsewhere: a reaction or a deletion
        // notice carries the thread it belongs to but is not a reply.
        replies[threadId] = (replies[threadId] ?? 0) + 1;
      }
      if (row.timestamp > (lastActivity[threadId] ?? 0)) {
        lastActivity[threadId] = row.timestamp;
        lastMessage[threadId] = row.messageId;
      }
    }
    final listed = await _rowsForRoom(accountId, roomToken);
    for (final entry in roots.entries) {
      // Every message on the reference server carries `threadId` equal to its
      // own id, so a root alone means nothing - measured, and without this the
      // list filled up with one entry per message, each reading "0 replies".
      // A thread is a root that somebody answered.
      if (listed.containsKey(entry.key) || (replies[entry.key] ?? 0) == 0) {
        continue;
      }
      await _database
          .into(_database.cachedThreads)
          .insertOnConflictUpdate(
            CachedThreadsCompanion.insert(
              accountId: accountId,
              roomToken: roomToken,
              threadId: entry.key,
              title: '',
              lastMessageId: lastMessage[entry.key] ?? entry.key,
              lastActivity: lastActivity[entry.key] ?? entry.value.timestamp,
              numReplies: replies[entry.key] ?? 0,
              notificationLevel: 0,
              recent: const Value(true),
              // No server payload to keep: this row was derived from the
              // messages, and an empty object says so honestly instead of
              // pretending a thread object arrived.
              rawJson: '{}',
            ),
          );
    }
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
