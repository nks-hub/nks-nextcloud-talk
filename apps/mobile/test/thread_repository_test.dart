import 'dart:convert';

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
    'recent replacement is room scoped and preserves subscriptions',
    () async {
      await threads.replaceSubscribed(
        accountId: 'account-a',
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Subscribed'),
          _thread(roomToken: 'roomb123', threadId: 20, title: 'Other room'),
        ],
      );
      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Recent title'),
          _thread(roomToken: 'rooma123', threadId: 11, title: 'Recent only'),
        ],
      );

      await threads.replaceRecent(
        accountId: 'account-a',
        roomToken: 'rooma123',
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
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Recent'),
        ],
      );
      await threads.replaceSubscribed(
        accountId: 'account-a',
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Both'),
          _thread(roomToken: 'roomb123', threadId: 20, title: 'Subscribed'),
        ],
      );

      await threads.replaceSubscribed(
        accountId: 'account-a',
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
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Before'),
        ],
      );

      await threads.upsertDetail(
        accountId: 'account-a',
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
      values: <RichChatThread>[
        _thread(roomToken: 'roomb123', threadId: 20, title: 'Recent'),
      ],
    );
    await threads.replaceSubscribed(
      accountId: 'account-a',
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
        values: <RichChatThread>[
          _thread(roomToken: 'rooma123', threadId: 10, title: 'Account A'),
        ],
      );
      await threads.replaceSubscribed(
        accountId: 'account-b',
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
