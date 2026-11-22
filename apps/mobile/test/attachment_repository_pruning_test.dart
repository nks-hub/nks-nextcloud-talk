import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'pending_attachment_fixture.dart';
import 'test_support.dart';

void main() {
  test(
    'prunes only excess released terminal jobs and preserves active cleanup',
    () async {
      final database = openTestDatabase();
      addTearDown(database.close);
      final repository = AttachmentRepository(database);
      for (final accountId in <String>['account-a', 'account-b']) {
        await _insertAccount(database, accountId);
        await repository.persistAccountState(
          account: AttachmentAccountState(
            accountId: AccountId.parse(accountId),
            server: ServerBase.parse('https://cloud.example.invalid'),
            lane: AttachmentAccountLane.ready,
            credentialGeneration: 1,
            capabilityGeneration: 1,
            jobs: const {},
          ),
          updatedAt: DateTime.utc(2026, 11, 21),
        );
      }
      final rows = <StoredAttachmentJob>[
        for (var index = 0; index < 4; index++)
          pendingAttachmentFixture(
            index,
            phase: index == 2 ? 'cancelled' : 'completed',
            count: 16,
          ),
        pendingAttachmentFixture(
          4,
          phase: 'completed',
          count: 16,
        ).copyWith(sourceReleased: false),
        pendingAttachmentFixture(5, phase: 'failed', count: 16),
        pendingAttachmentFixture(6, phase: 'uploading', count: 16),
        for (var index = 7; index < 10; index++)
          pendingAttachmentFixture(
            index,
            accountId: 'account-b',
            phase: 'completed',
            count: 16,
          ),
      ];
      for (final row in rows) {
        await database
            .into(database.attachmentJobs)
            .insert(row.toCompanion(true));
      }
      final preserved = (
        accountId: 'account-a',
        jobId: pendingAttachmentFixture(0, count: 16).jobId,
      );

      final removed = await repository.pruneReleasedTerminalJobs(
        retainPerAccount: 2,
        preserve: <AttachmentPersistenceKey>{preserved},
      );

      expect(removed, <AttachmentPersistenceKey>{
        (
          accountId: 'account-a',
          jobId: pendingAttachmentFixture(1, count: 16).jobId,
        ),
        (
          accountId: 'account-a',
          jobId: pendingAttachmentFixture(2, count: 16).jobId,
        ),
        (
          accountId: 'account-b',
          jobId: pendingAttachmentFixture(
            7,
            accountId: 'account-b',
            count: 16,
          ).jobId,
        ),
      });
      final remaining = await database.select(database.attachmentJobs).get();
      final remainingKeys =
          remaining.map((row) => (row.accountId, row.jobId)).toList()
            ..sort((left, right) {
              final account = left.$1.compareTo(right.$1);
              return account != 0 ? account : left.$2.compareTo(right.$2);
            });
      expect(remainingKeys, <(String, String)>[
        ('account-a', pendingAttachmentFixture(0, count: 16).jobId),
        ('account-a', pendingAttachmentFixture(3, count: 16).jobId),
        ('account-a', pendingAttachmentFixture(4, count: 16).jobId),
        ('account-a', pendingAttachmentFixture(5, count: 16).jobId),
        ('account-a', pendingAttachmentFixture(6, count: 16).jobId),
        (
          'account-b',
          pendingAttachmentFixture(8, accountId: 'account-b', count: 16).jobId,
        ),
        (
          'account-b',
          pendingAttachmentFixture(9, accountId: 'account-b', count: 16).jobId,
        ),
      ]);
    },
  );

  test('only an existing suspended lane can be resumed', () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    final repository = AttachmentRepository(database);
    final originalTime = DateTime.utc(2026, 11, 21);
    final resumeTime = DateTime.utc(2026, 11, 22);
    final lanes = {
      'account-a': AttachmentAccountLane.suspended,
      'account-b': AttachmentAccountLane.ready,
      'account-c': AttachmentAccountLane.reauthenticationRequired,
      'account-removed': AttachmentAccountLane.suspended,
    };
    for (final entry in lanes.entries) {
      await _insertAccount(database, entry.key);
      await repository.persistAccountState(
        account: AttachmentAccountState(
          accountId: AccountId.parse(entry.key),
          server: ServerBase.parse('https://cloud.example.invalid'),
          lane: entry.value,
          credentialGeneration: 3,
          capabilityGeneration: 5,
          jobs: const {},
        ),
        updatedAt: originalTime,
      );
    }
    await _insertAccount(database, 'account-without-runtime');
    await (database.delete(
      database.attachmentRuntimeAccounts,
    )..where((row) => row.accountId.equals('account-removed'))).go();
    await (database.delete(
      database.accounts,
    )..where((row) => row.id.equals('account-removed'))).go();
    final original = {
      for (final row
          in await database.select(database.attachmentRuntimeAccounts).get())
        row.accountId: row,
    };
    await Future.wait([
      for (final id in [...lanes.keys, 'account-without-runtime', 'account-a'])
        repository.resumeSuspendedAccount(
          accountId: AccountId.parse(id),
          updatedAt: resumeTime,
        ),
    ]);
    await repository.resumeSuspendedAccount(
      accountId: AccountId.parse('account-a'),
      updatedAt: resumeTime.add(const Duration(seconds: 1)),
    );

    final restored = {
      for (final row
          in await database.select(database.attachmentRuntimeAccounts).get())
        row.accountId: row,
    };
    expect(restored, {
      ...original,
      'account-a': original['account-a']!.copyWith(
        lane: AttachmentAccountLane.ready.name,
        updatedAtMillis: resumeTime.millisecondsSinceEpoch,
      ),
    });
  });
}

Future<void> _insertAccount(AppDatabase database, String accountId) => database
    .into(database.accounts)
    .insert(
      AccountsCompanion.insert(
        id: accountId,
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'fixture-user-$accountId',
        serverProductName: 'Nextcloud',
        createdAtMillis: 1,
      ),
    );
