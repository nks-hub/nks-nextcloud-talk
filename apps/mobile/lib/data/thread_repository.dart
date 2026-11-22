import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../core/giphy_reference.dart';
import 'app_database.dart';

final class ThreadRepository {
  const ThreadRepository(this._database);

  final AppDatabase _database;

  /// Whether [thread] was projected from an ordinary cached reply chain.
  ///
  /// Talk's thread metadata API only knows explicitly created named threads.
  /// An empty wire object is the repository-owned marker used when the recent
  /// list supplements that server response with a locally known reply chain.
  static bool isLocallyDerived(CachedThread thread) {
    try {
      final wire = jsonDecode(thread.rawJson);
      return wire is Map<String, Object?> && wire.isEmpty;
    } on FormatException {
      return false;
    }
  }

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
      await _projectMessages(
        accountId: accountId,
        server: server,
        values: values,
      );
      final threadRows = <CachedThreadsCompanion>[];
      for (final value in values) {
        final current = existing[value.threadId];
        threadRows.add(
          _threadCompanion(
            accountId: accountId,
            value: value,
            recent: true,
            subscribed: current?.subscribed ?? false,
            detailed: current?.detailed ?? false,
          ),
        );
      }
      await _upsertAll(threadRows);
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
    final derivedThreads = <CachedThreadsCompanion>[];
    for (final entry in roots.entries) {
      // Every message on the reference server carries `threadId` equal to its
      // own id, so a root alone means nothing - measured, and without this the
      // list filled up with one entry per message, each reading "0 replies".
      // A thread is a root that somebody answered.
      final current = listed[entry.key];
      if (_isNamedCachedRoot(entry.value) ||
          (replies[entry.key] ?? 0) == 0 ||
          current != null && !isLocallyDerived(current)) {
        continue;
      }
      derivedThreads.add(
        CachedThreadsCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          threadId: entry.key,
          // The server has no name for this thread, so the root message
          // stands in for one. Without it every derived row read just
          // "Vlákno" and two threads in the same room were impossible to
          // tell apart. A rename dialog opened on such a row starts from
          // this text, which is the label the reader already sees.
          title: _derivedThreadTitle(entry.value.displayText),
          lastMessageId: lastMessage[entry.key] ?? entry.key,
          lastActivity: lastActivity[entry.key] ?? entry.value.timestamp,
          numReplies: replies[entry.key] ?? 0,
          notificationLevel: current?.notificationLevel ?? 0,
          recent: const Value(true),
          subscribed: Value(current?.subscribed ?? false),
          detailed: Value(current?.detailed ?? false),
          // No server payload to keep: this row was derived from the
          // messages, and an empty object says so honestly instead of
          // pretending a thread object arrived.
          rawJson: '{}',
        ),
      );
    }
    await _upsertAll(derivedThreads);
  }

  static bool _isNamedCachedRoot(CachedChatMessage root) {
    try {
      return ChatMessage.fromJson(jsonDecode(root.rawJson)).isThread == true;
    } on FormatException {
      return false;
    } on TalkProtocolException {
      return false;
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
      await _projectMessages(
        accountId: accountId,
        server: server,
        values: values,
      );
      final threadRows = <CachedThreadsCompanion>[];
      for (final value in values) {
        final current = existing[(value.roomToken.value, value.threadId)];
        threadRows.add(
          _threadCompanion(
            accountId: accountId,
            value: value,
            recent: current?.recent ?? false,
            subscribed: true,
            detailed: current?.detailed ?? false,
          ),
        );
      }
      await _upsertAll(threadRows);
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
      await _projectMessages(
        accountId: accountId,
        server: server,
        values: [value],
      );
      await _upsert(
        accountId: accountId,
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
    required RichChatThread value,
    required bool recent,
    required bool subscribed,
    required bool detailed,
  }) => _database
      .into(_database.cachedThreads)
      .insertOnConflictUpdate(
        _threadCompanion(
          accountId: accountId,
          value: value,
          recent: recent,
          subscribed: subscribed,
          detailed: detailed,
        ),
      );

  CachedThreadsCompanion _threadCompanion({
    required String accountId,
    required RichChatThread value,
    required bool recent,
    required bool subscribed,
    required bool detailed,
  }) => CachedThreadsCompanion.insert(
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
  );

  Future<void> _upsertAll(List<CachedThreadsCompanion> threads) {
    if (threads.isEmpty) {
      return Future<void>.value();
    }
    return _database.batch(
      (batch) =>
          batch.insertAllOnConflictUpdate(_database.cachedThreads, threads),
    );
  }

  Future<void> _projectMessages({
    required String accountId,
    required ServerBase server,
    required List<RichChatThread> values,
  }) async {
    final valuesByRoom = <String, List<RichChatThread>>{};
    for (final value in values) {
      valuesByRoom
          .putIfAbsent(value.roomToken.value, () => <RichChatThread>[])
          .add(value);
    }
    final roomTokens = valuesByRoom.keys.toList(growable: false);
    const roomChunkSize = 8;
    for (var offset = 0; offset < roomTokens.length; offset += roomChunkSize) {
      final end = offset + roomChunkSize < roomTokens.length
          ? offset + roomChunkSize
          : roomTokens.length;
      final chunk = roomTokens.sublist(offset, end);
      final projections = {
        for (final roomToken in chunk)
          roomToken: _RoomThreadProjection(valuesByRoom[roomToken]!),
      };
      ({String roomToken, int messageId})? after;
      while (true) {
        final rows = await _loadMessagePage(
          accountId: accountId,
          roomTokens: chunk,
          after: after,
        );
        final changed = <CachedChatMessagesCompanion>[];
        for (final row in rows) {
          final roomToken = row.read<String>('room_token');
          final messageId = row.read<int>('message_id');
          final message = projections[roomToken]!.updateCached(
            messageId,
            row.read<String>('raw_json'),
          );
          if (message != null) {
            changed.add(
              _messageCompanion(
                accountId: accountId,
                server: server,
                message: message,
              ),
            );
          }
        }
        final lastPage = rows.length < _messageProjectionPageSize;
        if (lastPage) {
          // Inserting missing rows sooner would put them in the cursor's path.
          for (final projection in projections.values) {
            for (final message in projection.missingMessages) {
              changed.add(
                _messageCompanion(
                  accountId: accountId,
                  server: server,
                  message: message,
                ),
              );
              if (changed.length == _messageProjectionPageSize) {
                await _writeProjectedMessages(changed);
                changed.clear();
              }
            }
          }
        }
        await _writeProjectedMessages(changed);
        if (lastPage) {
          break;
        }
        after = (
          roomToken: rows.last.read<String>('room_token'),
          messageId: rows.last.read<int>('message_id'),
        );
      }
    }
  }

  static const _messageProjectionPageSize = 256;

  Future<List<QueryRow>> _loadMessagePage({
    required String accountId,
    required List<String> roomTokens,
    required ({String roomToken, int messageId})? after,
  }) {
    final slots = List.filled(roomTokens.length, '?').join(', ');
    // This branch lets SQLite seek to the message ID in the current room.
    final currentRoom = after == null
        ? ''
        : '''
          SELECT room_token, message_id, raw_json FROM "cached_chat_messages"
          WHERE account_id = ? AND room_token = ? AND message_id > ?
          UNION ALL
        ''';
    final laterRooms = after == null ? '' : 'AND room_token > ?';
    return _database
        .customSelect(
          '''
        $currentRoom
        SELECT room_token, message_id, raw_json FROM "cached_chat_messages"
        WHERE account_id = ? AND room_token IN ($slots) $laterRooms
        ORDER BY room_token, message_id
        LIMIT $_messageProjectionPageSize
      ''',
          variables: [
            if (after != null) ...[
              Variable.withString(accountId),
              Variable.withString(after.roomToken),
              Variable.withInt(after.messageId),
            ],
            Variable.withString(accountId),
            for (final roomToken in roomTokens) Variable.withString(roomToken),
            if (after != null) Variable.withString(after.roomToken),
          ],
          readsFrom: {_database.cachedChatMessages},
        )
        .get();
  }

  Future<void> _writeProjectedMessages(
    List<CachedChatMessagesCompanion> messages,
  ) async {
    if (messages.isNotEmpty) {
      await _database.batch(
        (batch) => batch.insertAllOnConflictUpdate(
          _database.cachedChatMessages,
          messages,
        ),
      );
    }
  }

  CachedChatMessagesCompanion _messageCompanion({
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
            ).root.plainText.trim(),
          );
    return CachedChatMessagesCompanion.insert(
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
    );
  }

  /// Collapses a root message into a one-line label for a derived thread.
  ///
  /// Kept short deliberately: the row shows one line and a long root would be
  /// clipped anyway, while the full text stays available in the thread itself.
  static String _derivedThreadTitle(String displayText) {
    final flattened = displayText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flattened.length <= _derivedTitleLimit) {
      return flattened;
    }
    return '${flattened.substring(0, _derivedTitleLimit).trimRight()}…';
  }

  static const int _derivedTitleLimit = 120;

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

final class _RoomThreadProjection {
  _RoomThreadProjection(List<RichChatThread> threads)
    : _values = [
        for (final thread in threads)
          (
            thread: thread,
            authoritative: {
              for (final message in [thread.firstMessage, thread.lastMessage])
                if (message != null)
                  message.messageId: message.projectThreadTitle(
                    roomToken: thread.roomToken,
                    threadId: thread.threadId,
                    threadTitle: thread.title,
                  ),
            },
          ),
      ],
      _threadIds = {for (final thread in threads) thread.threadId} {
    _authoritativeIds = {
      for (final value in _values) ...value.authoritative.keys,
    };
    _missingIds = _authoritativeIds.toSet();
  }

  final List<({RichChatThread thread, Map<int, ChatMessage> authoritative})>
  _values;
  final Set<int> _threadIds;
  late final Set<int> _authoritativeIds;
  late final Set<int> _missingIds;

  ChatMessage? updateCached(int messageId, String rawJson) {
    final isAuthoritative = _authoritativeIds.contains(messageId);
    final ChatMessage cached;
    try {
      final wire = jsonDecode(rawJson);
      if (!isAuthoritative &&
          wire is Map<String, Object?> &&
          wire['parent'] == null &&
          !_threadIds.contains(wire['threadId'])) {
        // Use the wire scope here: older cache rows can have a stale column.
        return null;
      }
      cached = ChatMessage.fromJson(wire);
    } on FormatException {
      return null;
    } on TalkProtocolException {
      return null;
    }
    _missingIds.remove(messageId);
    final parent = cached.parent;
    if (!isAuthoritative &&
        !_threadIds.contains(cached.threadId) &&
        (parent is! ChatFullParent ||
            !_authoritativeIds.contains(parent.messageId))) {
      return null;
    }
    final updated = _project(messageId, cached);
    return identical(updated, cached) ? null : updated;
  }

  Iterable<ChatMessage> get missingMessages =>
      _missingIds.map((id) => _project(id, null)!);

  ChatMessage? _project(int messageId, ChatMessage? cached) {
    var projected = cached;
    for (final value in _values) {
      final incoming = value.authoritative[messageId];
      final current = projected;
      if (current == null) {
        // A new row only receives parent updates from later thread entries.
        projected = incoming;
        continue;
      }
      var updated =
          incoming ??
          current.projectThreadTitle(
            roomToken: value.thread.roomToken,
            threadId: value.thread.threadId,
            threadTitle: value.thread.title,
          );
      for (final parent in value.authoritative.values) {
        updated = updated.replaceParentMessageIfMatching(parent);
      }
      projected = updated;
    }
    return projected;
  }
}
