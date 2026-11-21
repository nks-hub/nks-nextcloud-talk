import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/thread_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ThreadRepository threads;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    threads = ThreadRepository(database);
    await _insertAccount(accounts, 'account-a');
    await _insertAccount(accounts, 'account-b');
  });

  tearDown(() => database.close());

  test(
    'a thread started by replying shows up even when the server omits it',
    () async {
      // Measured on the reference server: `threads/recent` lists only threads
      // that were given a name. Three replies under root 77777 left it
      // returning nothing while every message carried `threadId: 77777`, so the
      // screen was empty for somebody who demonstrably had thread replies.
      for (final row in <({int id, int thread, String text, String system})>[
        (id: 500, thread: 500, text: 'Root of an unnamed thread', system: ''),
        (id: 501, thread: 500, text: 'First reply', system: ''),
        (id: 502, thread: 500, text: 'Second reply', system: ''),
        (id: 503, thread: 500, text: '', system: 'reaction'),
        // Every message on the reference server carries its own id as threadId,
        // so a root nobody answered must not become an entry of its own.
        (id: 600, thread: 600, text: 'A message nobody replied to', system: ''),
      ]) {
        await database
            .into(database.cachedChatMessages)
            .insert(
              CachedChatMessagesCompanion.insert(
                accountId: 'account-a',
                roomToken: 'rooma123',
                messageId: row.id,
                actorType: 'users',
                actorId: 'someone',
                actorDisplayName: 'Someone',
                timestamp: 1724300000 + row.id,
                systemMessage: row.system,
                messageType: 'comment',
                referenceId: 'reference-${row.id}',
                displayText: row.text,
                deleted: false,
                threadId: Value(row.thread),
                rawJson: '{}',
              ),
            );
      }

      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: const <RichChatThread>[],
      );

      final recent = await threads
          .watchRecent(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      expect(
        recent.map((thread) => thread.threadId),
        <int>[500],
        reason: 'a root nobody answered is not a thread',
      );
      expect(
        recent.single.numReplies,
        2,
        reason: 'a reaction carries the thread but is not a reply',
      );
      expect(
        recent.single.title,
        'Root of an unnamed thread',
        reason: 'the root message stands in for the name the server lacks',
      );
      expect(ThreadRepository.isLocallyDerived(recent.single), isTrue);
    },
  );

  test(
    'a derived title collapses whitespace and stays one short line',
    () async {
      final root = 'Koren  s\n  vice radky ${'a' * 200}';
      for (final row in <({int id, int thread, String text})>[
        (id: 700, thread: 700, text: root),
        (id: 701, thread: 700, text: 'Odpoved'),
      ]) {
        await database
            .into(database.cachedChatMessages)
            .insert(
              CachedChatMessagesCompanion.insert(
                accountId: 'account-a',
                roomToken: 'rooma123',
                messageId: row.id,
                actorType: 'users',
                actorId: 'someone',
                actorDisplayName: 'Someone',
                timestamp: 1724300000 + row.id,
                systemMessage: '',
                messageType: 'comment',
                referenceId: 'reference-${row.id}',
                displayText: row.text,
                deleted: false,
                threadId: Value(row.thread),
                rawJson: '{}',
              ),
            );
      }

      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: const <RichChatThread>[],
      );

      final title =
          (await threads
                  .watchRecent(accountId: 'account-a', roomToken: 'rooma123')
                  .first)
              .singleWhere((thread) => thread.threadId == 700)
              .title;
      expect(title.contains('\n'), isFalse, reason: 'the row shows one line');
      expect(title.startsWith('Koren s vice radky'), isTrue);
      expect(
        title.length,
        lessThanOrEqualTo(121),
        reason: 'capped at 120 plus the ellipsis',
      );
      expect(title.endsWith('…'), isTrue);
    },
  );

  test(
    'repeated recent refresh keeps an ordinary reply thread listed',
    () async {
      await _insertThreadMessages(
        database,
        title: 'Ordinary thread',
        named: false,
      );

      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: const <RichChatThread>[],
      );
      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: const <RichChatThread>[],
      );

      final recent = await threads
          .watchRecent(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      expect(recent.map((thread) => thread.threadId), <int>[100]);
      expect(ThreadRepository.isLocallyDerived(recent.single), isTrue);
    },
  );

  test(
    'a named root omitted from recent is not degraded to ordinary',
    () async {
      await _insertThreadMessages(database, title: 'Named thread');

      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: const <RichChatThread>[],
      );

      final recent = await threads
          .watchRecent(accountId: 'account-a', roomToken: 'rooma123')
          .first;
      expect(recent, isEmpty);
      expect(
        await threads.get(
          accountId: 'account-a',
          roomToken: 'rooma123',
          threadId: 100,
        ),
        equals(null),
      );
    },
  );

  test(
    'recent replacement is room scoped and preserves subscriptions',
    () async {
      await threads.replaceSubscribed(
        accountId: 'account-a',
        server: _serverFor('account-a'),
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Subscribed'),
          _thread(roomToken: 'roomb123', threadId: 20, title: 'Other room'),
        ],
      );
      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Recent title'),
          _thread(roomToken: 'rooma123', threadId: 11, title: 'Recent only'),
        ],
      );

      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 11, title: 'Newest'),
        ],
      );

      final all = await threads.listAccount('account-a');
      expect(
        all.map(
          (row) => (row.roomToken, row.threadId, row.recent, row.subscribed),
        ),
        containsAll(<(String, int, bool, bool)>[
          ('rooma123', 10, false, true),
          ('rooma123', 11, true, false),
          ('roomb123', 20, false, true),
        ]),
      );
      expect(all.singleWhere((row) => row.threadId == 11).title, 'Newest');
    },
  );

  test(
    'subscription replacement removes only stale subscription-only rows',
    () async {
      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Recent'),
        ],
      );
      await threads.replaceSubscribed(
        accountId: 'account-a',
        server: _serverFor('account-a'),
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Both'),
          _thread(roomToken: 'roomb123', threadId: 20, title: 'Subscribed'),
        ],
      );

      await threads.replaceSubscribed(
        accountId: 'account-a',
        server: _serverFor('account-a'),
        values: const <RichChatThread>[],
      );

      final all = await threads.listAccount('account-a');
      expect(all, hasLength(1));
      expect(all.single.threadId, 10);
      expect(all.single.recent, isTrue);
      expect(all.single.subscribed, isFalse);
    },
  );

  test(
    'authoritative detail updates metadata without changing list flags',
    () async {
      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        server: _serverFor('account-a'),
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Before'),
        ],
      );

      await threads.upsertDetail(
        accountId: 'account-a',
        server: _serverFor('account-a'),
        value: _thread(
          roomToken: 'rooma123',
          threadId: 10,
          title: 'After',
          notificationLevel: 3,
        ),
      );

      final stored = await threads.get(
        accountId: 'account-a',
        roomToken: 'rooma123',
        threadId: 10,
      );
      expect(stored!.title, 'After');
      expect(stored.notificationLevel, 3);
      expect(stored.recent, isTrue);
      expect(stored.subscribed, isFalse);
      expect(stored.detailed, isTrue);
    },
  );

  test('detail-only metadata survives unrelated list replacement', () async {
    await threads.upsertDetail(
      accountId: 'account-a',
      server: _serverFor('account-a'),
      value: _thread(
        roomToken: 'rooma123',
        threadId: 10,
        title: 'Detail only',
        notificationLevel: 2,
      ),
    );

    await threads.replaceRecent(
      accountId: 'account-a',
      roomToken: 'roomb123',
      server: _serverFor('account-a'),
      values: <RichChatThread>[
        _thread(roomToken: 'roomb123', threadId: 20, title: 'Recent'),
      ],
    );
    await threads.replaceSubscribed(
      accountId: 'account-a',
      server: _serverFor('account-a'),
      values: const <RichChatThread>[],
    );

    final stored = await threads.get(
      accountId: 'account-a',
      roomToken: 'rooma123',
      threadId: 10,
    );
    expect(stored, isNotNull);
    expect(stored!.title, 'Detail only');
    expect(stored.notificationLevel, 2);
    expect(stored.recent, isFalse);
    expect(stored.subscribed, isFalse);
    expect(stored.detailed, isTrue);
  });

  test(
    'thread cache is isolated by account and purged with its account',
    () async {
      await threads.replaceSubscribed(
        accountId: 'account-a',
        server: _serverFor('account-a'),
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Account A'),
        ],
      );
      await threads.replaceSubscribed(
        accountId: 'account-b',
        server: _serverFor('account-b'),
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Account B'),
        ],
      );

      await accounts.purgeAccount('account-a');

      expect(await threads.listAccount('account-a'), isEmpty);
      expect(
        (await threads.listAccount('account-b')).single.title,
        'Account B',
      );
    },
  );

  test(
    'detail atomically projects canonical title into cached messages',
    () async {
      await _insertThreadMessages(database, title: 'Before');

      await threads.upsertDetail(
        accountId: 'account-a',
        server: _serverFor('account-a'),
        value: _threadWithMessages(title: 'After'),
      );

      final rows =
          await (database.select(database.cachedChatMessages)
                ..where((row) => row.accountId.equals('account-a'))
                ..orderBy([(row) => OrderingTerm.asc(row.messageId)]))
              .get();
      final root = ChatMessage.fromJson(jsonDecode(rows.first.rawJson));
      final reply = ChatMessage.fromJson(jsonDecode(rows.last.rawJson));
      expect(root.threadTitle, 'After');
      expect(reply.threadTitle, 'After');
      expect((reply.parent as ChatFullParent).message.threadTitle, 'After');
      expect(
        (jsonDecode(rows.last.rawJson) as Map<String, Object?>)['threadTitle'],
        'After',
      );
    },
  );

  test('detail projection batches cached message writes', () async {
    await database.close();
    final counter = _CachedMessageSelectCounter();
    database = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(counter),
    );
    accounts = AccountRepository(database);
    threads = ThreadRepository(database);
    await _insertAccount(accounts, 'account-a');
    await _insertThreadMessages(database, title: 'Before', replyCount: 39);
    counter.enabled = true;

    await threads.upsertDetail(
      accountId: 'account-a',
      server: _serverFor('account-a'),
      value: _threadWithMessages(title: 'After'),
    );

    expect(counter.directMessageInserts, 0);
    expect(counter.messageBatchExecutions, 1);
    final rows = await database.select(database.cachedChatMessages).get();
    expect(rows, hasLength(40));
    expect(
      rows.every(
        (row) =>
            ChatMessage.fromJson(jsonDecode(row.rawJson)).threadTitle ==
            'After',
      ),
      isTrue,
    );
  });

  test('metadata write failure rolls back chat title projection', () async {
    await _insertThreadMessages(database, title: 'Before');
    await database.customStatement('''
      CREATE TRIGGER reject_cached_thread
      BEFORE INSERT ON cached_threads
      BEGIN
        SELECT RAISE(ABORT, 'fixture rejection');
      END
    ''');

    await expectLater(
      threads.upsertDetail(
        accountId: 'account-a',
        server: _serverFor('account-a'),
        value: _threadWithMessages(title: 'After'),
      ),
      throwsA(anything),
    );

    final root =
        await (database.select(database.cachedChatMessages)..where(
              (row) =>
                  row.accountId.equals('account-a') & row.messageId.equals(100),
            ))
            .getSingle();
    expect(
      ChatMessage.fromJson(jsonDecode(root.rawJson)).threadTitle,
      'Before',
    );
    expect(await threads.listAccount('account-a'), isEmpty);
  });

  test(
    'subscription refresh batches rows and reads messages once per room',
    () async {
      await database.close();
      final counter = _CachedMessageSelectCounter();
      database = AppDatabase.forTesting(
        NativeDatabase.memory().interceptWith(counter),
      );
      accounts = AccountRepository(database);
      threads = ThreadRepository(database);
      await _insertAccount(accounts, 'account-a');
      final values = <RichChatThread>[
        for (var room = 0; room < 2; room++)
          for (var thread = 0; thread < 20; thread++)
            _thread(
              roomToken: 'room${room}abc',
              threadId: 1000 + (room * 1000) + thread,
              title: 'Thread $room-$thread',
            ),
      ];
      counter.enabled = true;

      await threads.replaceSubscribed(
        accountId: 'account-a',
        server: _serverFor('account-a'),
        values: values,
      );

      expect(counter.selects, 2);
      expect(counter.threadBatchExecutions, 1);
      expect(counter.directThreadInserts, 0);
      expect(await threads.listAccount('account-a'), hasLength(40));
    },
  );
}

Future<void> _insertAccount(AccountRepository accounts, String accountId) {
  return accounts.upsertAccount(
    accountId: accountId,
    serverUrl: 'https://$accountId.example.invalid',
    loginName: '$accountId-user',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 8, 26),
  );
}

ServerBase _serverFor(String accountId) =>
    ServerBase.parse('https://$accountId.example.invalid');

RichChatThread _thread({
  required String roomToken,
  required int threadId,
  required String title,
  int notificationLevel = 1,
}) {
  return RichChatThread.fromJson(
    jsonDecode(
      jsonEncode(<String, Object?>{
        'thread': <String, Object?>{
          'id': threadId,
          'roomToken': roomToken,
          'title': title,
          'lastMessageId': threadId,
          'lastActivity': 1724300000 + threadId,
          'numReplies': 0,
        },
        'attendee': <String, Object?>{'notificationLevel': notificationLevel},
        'first': null,
        'last': null,
      }),
    ),
  );
}

RichChatThread _threadWithMessages({required String title}) {
  final root = _messageWire(
    id: 100,
    title: title,
    isRoot: true,
    message: 'Root message',
  );
  final reply = _messageWire(
    id: 101,
    title: title,
    message: 'Reply message',
    parent: root,
  );
  return RichChatThread.fromJson(<String, Object?>{
    'thread': <String, Object?>{
      'id': 100,
      'roomToken': 'rooma123',
      'title': title,
      'lastMessageId': 101,
      'lastActivity': 1724300101,
      'numReplies': 1,
    },
    'attendee': const <String, Object?>{'notificationLevel': 1},
    'first': root,
    'last': reply,
  });
}

Future<void> _insertThreadMessages(
  AppDatabase database, {
  required String title,
  bool named = true,
  int replyCount = 1,
}) async {
  final root = _messageWire(
    id: 100,
    title: title,
    isRoot: named,
    message: 'Root message',
  );
  final wires = <Map<String, Object?>>[
    root,
    for (var index = 0; index < replyCount; index++)
      _messageWire(
        id: 101 + index,
        title: title,
        message: 'Reply message $index',
        parent: root,
      ),
  ];
  await database.batch((batch) {
    for (final wire in wires) {
      final id = wire['id']! as int;
      batch.insert(
        database.cachedChatMessages,
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: 'rooma123',
          messageId: id,
          actorType: 'users',
          actorId: 'account-a-user',
          actorDisplayName: 'Account A',
          timestamp: 1724300000 + id,
          systemMessage: '',
          messageType: 'comment',
          referenceId: 'reference-$id',
          displayText: wire['message']! as String,
          deleted: false,
          threadId: const Value(100),
          rawJson: jsonEncode(wire),
        ),
      );
    }
  });
}

Map<String, Object?> _messageWire({
  required int id,
  required String title,
  required String message,
  bool isRoot = false,
  Map<String, Object?>? parent,
}) {
  return <String, Object?>{
    'id': id,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': 'account-a-user',
    'actorDisplayName': 'Account A',
    'timestamp': 1724300000 + id,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$id',
    'message': message,
    'messageParameters': const <String, Object?>{},
    'markdown': false,
    'reactions': const <String, Object?>{},
    'reactionsSelf': const <Object?>[],
    'threadId': 100,
    'isThread': isRoot,
    'threadTitle': title,
    'threadReplies': 1,
    'parent': ?parent,
  };
}

final class _CachedMessageSelectCounter extends QueryInterceptor {
  bool enabled = false;
  int selects = 0;
  int threadBatchExecutions = 0;
  int directThreadInserts = 0;
  int messageBatchExecutions = 0;
  int directMessageInserts = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (enabled &&
        statement.toLowerCase().contains('from "cached_chat_messages"')) {
      selects++;
    }
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    if (enabled &&
        statements.statements.any(
          (statement) =>
              statement.toLowerCase().contains('into "cached_threads"'),
        )) {
      threadBatchExecutions++;
    }
    if (enabled &&
        statements.statements.any(
          (statement) =>
              statement.toLowerCase().contains('into "cached_chat_messages"'),
        )) {
      messageBatchExecutions++;
    }
    return super.runBatched(executor, statements);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (enabled && statement.toLowerCase().contains('into "cached_threads"')) {
      directThreadInserts++;
    }
    if (enabled &&
        statement.toLowerCase().contains('into "cached_chat_messages"')) {
      directMessageInserts++;
    }
    return super.runInsert(executor, statement, args);
  }
}
