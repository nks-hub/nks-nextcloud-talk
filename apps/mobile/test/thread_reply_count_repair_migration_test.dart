import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';

/// The v15 step repairs reply counts that the projection already wrote wrong.
///
/// A reaction and a deletion notice both arrive as system messages carrying
/// the thread they belong to, and the old rule counted them. The count then
/// survived every later recount because the projection reuses the stored
/// value as a floor, so the fix in the projection cannot heal a bubble that
/// already claims "1 reply".
void main() {
  test('repairs a count inflated by a reaction, leaving the real reply', () async {
    await _withDatabaseAt13((database) async {
      await _seedThread(
        database,
        threadId: 500,
        storedReplyCount: 2,
        replies: const [
          (messageId: 501, systemMessage: ''),
          (messageId: 502, systemMessage: 'reaction'),
        ],
      );
    }, (database) async {
      expect(database.schemaVersion, 18);
      expect(await _storedReplyCount(database, 500), 1);
    });
  });

  test('repairs a count left behind by a deleted message', () async {
    await _withDatabaseAt13((database) async {
      await _seedThread(
        database,
        threadId: 600,
        storedReplyCount: 1,
        replies: const [(messageId: 601, systemMessage: 'message_deleted')],
      );
    }, (database) async {
      expect(await _storedReplyCount(database, 600), 0);
    });
  });

  test('keeps a server count the cache cannot account for', () async {
    await _withDatabaseAt13((database) async {
      await _seedThread(
        database,
        threadId: 700,
        storedReplyCount: 25,
        replies: const [
          (messageId: 701, systemMessage: ''),
          (messageId: 702, systemMessage: 'reaction'),
        ],
      );
    }, (database) async {
      expect(await _storedReplyCount(database, 700), 25);
    });
  });

  test('leaves an already correct count alone', () async {
    await _withDatabaseAt13((database) async {
      await _seedThread(
        database,
        threadId: 800,
        storedReplyCount: 1,
        replies: const [(messageId: 801, systemMessage: '')],
      );
    }, (database) async {
      expect(await _storedReplyCount(database, 800), 1);
    });
  });

  test('does not touch a root without a stored count', () async {
    await _withDatabaseAt13((database) async {
      await _seedThread(
        database,
        threadId: 900,
        storedReplyCount: null,
        replies: const [(messageId: 901, systemMessage: 'reaction')],
      );
    }, (database) async {
      final raw = await _rootRawJson(database, 900);
      expect(jsonDecode(raw) as Map<String, Object?>, isNot(contains('threadReplies')));
    });
  });
}

typedef _SeedReply = ({int messageId, String systemMessage});

Future<void> _withDatabaseAt13(
  Future<void> Function(AppDatabase database) seed,
  Future<void> Function(AppDatabase database) verify,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'nctalk-thread-reply-repair-',
  );
  final file = File('${directory.path}${Platform.pathSeparator}repair.sqlite');
  AppDatabase? database;
  try {
    database = AppDatabase.forTesting(NativeDatabase(file));
    await database
        .into(database.accounts)
        .insert(
          AccountsCompanion.insert(
            id: 'account-a',
            serverUrl: 'https://cloud.example.invalid',
            loginName: 'fixture-user',
            serverProductName: 'Nextcloud',
            createdAtMillis: 1,
          ),
        );
    await seed(database);
    await database.customStatement('DROP TABLE cached_threads');
    await database.customStatement('PRAGMA user_version = 13');
    await database.close();

    database = AppDatabase.forTesting(NativeDatabase(file));
    await verify(database);
  } finally {
    await database?.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

Future<void> _seedThread(
  AppDatabase database, {
  required int threadId,
  required int? storedReplyCount,
  required List<_SeedReply> replies,
}) async {
  final rootWire = <String, Object?>{
    'id': threadId,
    'token': 'rooma123',
    'message': 'Thread root',
    'threadId': threadId,
    'isThread': true,
    'threadReplies': ?storedReplyCount,
  };
  await database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: threadId,
          actorType: 'users',
          actorId: 'fixture-user',
          actorDisplayName: 'Fixture User',
          timestamp: 1,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'root-$threadId',
          displayText: 'Thread root',
          deleted: false,
          threadId: Value(threadId),
          rawJson: jsonEncode(rootWire),
        ),
      );
  for (final reply in replies) {
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: 'account-a',
            roomToken: 'rooma123',
            messageId: reply.messageId,
            actorType: 'users',
            actorId: 'fixture-user',
            actorDisplayName: 'Fixture User',
            timestamp: 2,
            systemMessage: reply.systemMessage,
            messageType: reply.systemMessage.isEmpty ? 'comment' : 'system',
            referenceId: 'reply-${reply.messageId}',
            displayText: 'Reply ${reply.messageId}',
            deleted: false,
            threadId: Value(threadId),
            rawJson: jsonEncode(<String, Object?>{
              'id': reply.messageId,
              'token': 'rooma123',
              'threadId': threadId,
              'systemMessage': reply.systemMessage,
            }),
          ),
        );
  }
}

Future<String> _rootRawJson(AppDatabase database, int threadId) async {
  final row =
      await (database.select(database.cachedChatMessages)..where(
            (row) =>
                row.accountId.equals('account-a') &
                row.roomToken.equals('rooma123') &
                row.messageId.equals(threadId),
          ))
          .getSingle();
  return row.rawJson;
}

Future<Object?> _storedReplyCount(AppDatabase database, int threadId) async {
  final wire = jsonDecode(await _rootRawJson(database, threadId));
  return (wire as Map<String, Object?>)['threadReplies'];
}
