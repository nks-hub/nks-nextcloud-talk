import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';

void main() {
  for (final release in _supportedReleaseSchemas) {
    test(
      'release schema v${release.version} (${release.sha.substring(0, 7)}) '
      'upgrades to v14 with account data intact',
      () => _verifyReleaseUpgrade(release),
    );
  }

  test(
    'schema left ahead of user_version by an interrupted migration '
    'still upgrades to v14',
    _verifyInterruptedUpgrade,
  );
}

/// An interrupted migration commits its completed steps but leaves
/// `user_version` untouched, so the next start replays steps the schema
/// already has. Reproduces a database recovered from a Windows 11 test
/// machine: `user_version` 7 with every column and table through step 10.
Future<void> _verifyInterruptedUpgrade() async {
  final directory = await Directory.systemTemp.createTemp(
    'nctalk-interrupted-',
  );
  final file = File(
    '${directory.path}${Platform.pathSeparator}interrupted.sqlite',
  );
  AppDatabase? database;
  try {
    database = AppDatabase.forTesting(NativeDatabase(file));
    await _seedSentinelData(database);
    await _downgradeToReleaseSchema(database, 11);
    await database.customStatement('PRAGMA user_version = 7');

    // The replay from 7 has to walk over work that is already there: tables
    // from steps 9 and 11 and columns from steps 8 and 10.
    final ahead = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    expect(
      ahead.map((row) => row.read<String>('name')).toSet(),
      containsAll(<String>{'chat_drafts', 'call_sessions'}),
    );
    await database.close();
    database = null;

    database = AppDatabase.forTesting(NativeDatabase(file));
    final room = await database
        .select(database.cachedConversations)
        .getSingle();
    final version = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    final tables = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();

    expect(version.read<int>('user_version'), 14);
    expect(room.isArchived, isTrue);
    expect(room.peerStatus, 'away');
    expect(
      tables.map((row) => row.read<String>('name')).toSet(),
      containsAll(<String>{
        'chat_drafts',
        'call_sessions',
        'call_lifecycle_sessions',
        'cached_threads',
      }),
    );
  } finally {
    await database?.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

Future<void> _verifyReleaseUpgrade(_ReleaseSchema release) async {
  final directory = await Directory.systemTemp.createTemp(
    'nctalk-release-v${release.version}-',
  );
  final file = File('${directory.path}${Platform.pathSeparator}release.sqlite');
  AppDatabase? database;
  try {
    database = AppDatabase.forTesting(NativeDatabase(file));
    await _seedSentinelData(database);
    await _downgradeToReleaseSchema(database, release.version);
    await database.close();
    database = null;

    database = AppDatabase.forTesting(NativeDatabase(file));
    final account = await database.select(database.accounts).getSingle();
    final room = await database
        .select(database.cachedConversations)
        .getSingle();
    final tables = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    final tableNames = tables.map((row) => row.read<String>('name')).toSet();
    final version = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    final foreignKeyViolations = await database
        .customSelect('PRAGMA foreign_key_check')
        .get();

    expect(version.read<int>('user_version'), 14);
    expect(account.id, 'account-matrix');
    expect(account.loginName, 'fixture-user');
    expect(room.token, 'matrix-room');
    expect(room.peerStatus, 'away');
    expect(room.peerStatusIcon, 'away');
    expect(room.peerStatusMessage, 'Synthetic matrix status');
    expect(room.peerStatusClearAt, 123456);
    expect(room.isArchived, isTrue);
    expect(
      tableNames,
      containsAll(<String>{
        'chat_drafts',
        'call_sessions',
        'call_lifecycle_sessions',
        'cached_threads',
      }),
    );
    expect(await database.select(database.cachedThreads).get(), isEmpty);
    expect(foreignKeyViolations, isEmpty);
  } finally {
    await database?.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

Future<void> _seedSentinelData(AppDatabase database) async {
  await database
      .into(database.accounts)
      .insert(
        AccountsCompanion.insert(
          id: 'account-matrix',
          serverUrl: 'https://cloud.example.invalid',
          loginName: 'fixture-user',
          serverProductName: 'Nextcloud',
          createdAtMillis: 1,
        ),
      );
  await database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: 'account-matrix',
          token: 'matrix-room',
          displayName: 'Synthetic matrix room',
          description: '',
          lastActivity: 1,
          unreadMessages: 0,
          favorite: false,
          rawJson: jsonEncode(const <String, Object?>{
            'status': 'away',
            'statusIcon': 'away',
            'statusMessage': 'Synthetic matrix status',
            'statusClearAt': 123456,
            'isArchived': true,
          }),
          peerStatus: const Value('away'),
          peerStatusIcon: const Value('away'),
          peerStatusMessage: const Value('Synthetic matrix status'),
          peerStatusClearAt: const Value(123456),
          isArchived: const Value(true),
        ),
      );
}

Future<void> _downgradeToReleaseSchema(
  AppDatabase database,
  int version,
) async {
  await database.customStatement('DROP TABLE cached_threads');
  if (version < 12) {
    await database.customStatement('DROP TABLE call_lifecycle_sessions');
  }
  if (version < 11) {
    await database.customStatement('DROP TABLE call_sessions');
  }
  if (version < 10) {
    await database.customStatement(
      'ALTER TABLE cached_conversations DROP COLUMN is_archived',
    );
  }
  if (version < 9) {
    await database.customStatement('DROP TABLE chat_drafts');
  }
  if (version < 8) {
    for (final column in const <String>[
      'peer_status_clear_at',
      'peer_status_message',
      'peer_status_icon',
      'peer_status',
    ]) {
      await database.customStatement(
        'ALTER TABLE cached_conversations DROP COLUMN $column',
      );
    }
  }
  await database.customStatement('PRAGMA user_version = $version');
}

final class _ReleaseSchema {
  const _ReleaseSchema(this.version, this.sha);

  final int version;
  final String sha;
}

const _supportedReleaseSchemas = <_ReleaseSchema>[
  _ReleaseSchema(7, '3d3e698f520952c9f831d227523cc26c4c0de15f'),
  _ReleaseSchema(8, '85fdb445a3adf406a0dea2b627685fff1af02efa'),
  _ReleaseSchema(9, '597adc6e2d2255c10b8c26247fe2a8899631c8f2'),
  _ReleaseSchema(10, '3227cc3e3c1553b1d409f358b912ecc12414d1fb'),
  _ReleaseSchema(11, 'ae94f36c9220b9fc5a94272dce6d76018fce8b92'),
  _ReleaseSchema(12, 'd1d6159912748886bad017ba5d5d1b10b4314afd'),
  _ReleaseSchema(13, 'aeac1d3db111fc8ff957cc892d97b11700cdba51'),
];
