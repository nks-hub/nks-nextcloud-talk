import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';

void main() {
  test('schema 19 gains the bounded thread window index', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-thread-window-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}thread-window.sqlite',
    );
    AppDatabase? database;
    try {
      database = AppDatabase.forTesting(NativeDatabase(file));
      await database.customStatement(
        'DROP INDEX cached_chat_messages_thread_window',
      );
      await database.customStatement('PRAGMA user_version = 19');
      await database.close();
      database = null;

      database = AppDatabase.forTesting(NativeDatabase(file));
      final version = await database
          .customSelect('PRAGMA user_version')
          .getSingle();
      final index = await database
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
            variables: [
              Variable.withString('cached_chat_messages_thread_window'),
            ],
          )
          .getSingleOrNull();

      expect(version.read<int>('user_version'), 23);
      expect(
        index?.read<String>('sql'),
        contains('(account_id, room_token, thread_id, message_id)'),
      );
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });
}
