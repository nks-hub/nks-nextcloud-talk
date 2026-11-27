import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';

import 'test_support.dart';

void main() {
  test(
    'failed draft writes survive navigation and account removal clears disk and memory',
    () async {
      final db = openTestDatabase();
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      final accounts = container.read(accountRepositoryProvider);
      Future<StoredAccount> login() => accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user',
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: DateTime.now(),
      );
      await login();
      final store = container.read(recoverableTextDraftStoreProvider);
      final chat = container.read(chatRepositoryProvider);
      const disk = RefusedTextDraft(
        accountId: 'account-a',
        roomToken: 'rooma123',
        draftId: 'a',
        message: 'in room',
        silent: false,
        createdAtMillis: 100,
      );
      final memory = disk.copyWith(
        draftId: 'b',
        message: 'in thread',
        threadId: const Value(123),
      );
      await chat.saveDraft(
        accountId: 'account-a',
        roomToken: 'rooma123',
        text: 'earlier revision',
      );
      final edited = disk.copyWith(
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      store.begin(edited);
      await store.checkpoint(edited, fromComposer: true);
      expect(
        await chat.readDraft(accountId: 'account-a', roomToken: 'rooma123'),
        isNull,
      );
      store.end(disk.draftId);
      expect(await store.watch('account-a', 'rooma123', null).first, [edited]);
      expect(await store.watch('account-a', 'rooma123', 123).first, isEmpty);
      await db.customStatement('PRAGMA query_only = ON');
      store.begin(memory);
      await expectLater(store.checkpoint(memory), throwsA(anything));
      store.end(memory.draftId);
      await store.saveComposer(
        chat,
        'account-a',
        'rooma123',
        123,
        'newer line',
      );
      expect(store.volatileDrafts('account-a', 'rooma123', 123), [memory]);
      expect(store.volatileDrafts('account-a', 'rooma123', null), isEmpty);
      expect(
        await store.readComposer(chat, 'account-a', 'rooma123', 123),
        'newer line',
      );
      await db.customStatement('PRAGMA query_only = OFF');
      await accounts.purgeAccount('account-a');
      await login();
      expect(store.volatileDrafts('account-a', 'rooma123', 123), isEmpty);
      expect(
        await store.readComposer(chat, 'account-a', 'rooma123', 123),
        isNull,
      );
      expect(await db.select(db.refusedTextDrafts).get(), isEmpty);
    },
  );
}
