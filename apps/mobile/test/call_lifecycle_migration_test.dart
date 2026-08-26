import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';

void main() {
  test('schema v11 migrates to v13 without losing accounts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-call-lifecycle-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}call-lifecycle.sqlite',
    );
    AppDatabase? database;
    try {
      database = AppDatabase.forTesting(NativeDatabase(file));
      await database.customSelect('SELECT 1').get();
      await AccountRepository(database).upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://cloud.example.invalid',
        loginName: 'alice',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026, 8, 26),
      );
      await database.close();
      database = null;

      database = AppDatabase.forTesting(
        NativeDatabase(
          file,
          setup: (raw) {
            raw
              ..execute('DROP TABLE call_lifecycle_sessions')
              ..userVersion = 11;
          },
        ),
      );
      final columns = await database
          .customSelect('PRAGMA table_info(call_lifecycle_sessions)')
          .get();

      expect(database.schemaVersion, 13);
      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll(<String>[
          'account_id',
          'room_token',
          'phase',
          'mutation_sequence',
        ]),
      );
      expect(
        (await database.select(database.accounts).getSingle()).id,
        'account-a',
      );
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });
}
