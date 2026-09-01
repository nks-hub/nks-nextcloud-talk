import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';

import 'test_support.dart';

const _accountId = 'account-a';
const _futureClearAt = 4102444800;

void main() {
  testWidgets(
    'schema v8 presence reaches the provider-backed room header after repair',
    (tester) async {
      Directory? directory;
      AppDatabase? database;
      CachedConversation? providerRoom;
      try {
        await tester.runAsync(() async {
          final fixture = await _createFixture('nctalk-presence-v8-');
          directory = fixture.directory;
          database = fixture.database;
          await _seedAccount(database!);
          await _insertConversation(
            database!,
            token: 'rooma123',
            rawJson: _roomWire(
              token: 'rooma123',
              status: 'away',
              statusClearAt: _futureClearAt,
              statusIcon: '☕',
              statusMessage: 'Coffee break',
            ),
          );
          await _downgradeToSchemaV8(database!);
          await database!.close();
          database = AppDatabase.forTesting(NativeDatabase(fixture.file));

          final container = ProviderContainer(
            overrides: [appDatabaseProvider.overrideWithValue(database!)],
          );
          try {
            providerRoom = (await container.read(
              conversationsProvider(_accountId).future,
            )).single;
          } finally {
            container.dispose();
          }
        });

        final room = providerRoom!;
        expect(database!.schemaVersion, 18);
        expect(room.peerStatus, 'away');
        expect(room.peerStatusIcon, '☕');
        expect(room.peerStatusMessage, 'Coffee break');
        expect(room.peerStatusClearAt, _futureClearAt);

        await tester.pumpWidget(
          localizedTestApp(
            home: Scaffold(body: ConversationPresenceTitle(conversation: room)),
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const Key('conversation-presence-text-rooma123')),
          findsOneWidget,
        );
        expect(find.text('☕ Coffee break'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(
          () => _closeAndDelete(database: database, directory: directory),
        );
      }
    },
  );

  test(
    'schema v12 repair is guarded, malformed-safe, and idempotent',
    () async {
      final fixture = await _createFixture('nctalk-presence-v12-');
      AppDatabase? database = fixture.database;
      try {
        await _seedAccount(database);
        await _insertConversation(
          database,
          token: 'repair-room',
          rawJson: _roomWire(
            token: 'repair-room',
            status: 'online',
            statusClearAt: _futureClearAt,
            statusIcon: '🟢',
            statusMessage: 'Available',
          ),
        );
        await _insertConversation(
          database,
          token: 'projected-room',
          rawJson: _roomWire(
            token: 'projected-room',
            status: 'online',
            statusClearAt: _futureClearAt,
            statusIcon: '🟢',
            statusMessage: 'Stale wire value',
          ),
          peerStatus: 'dnd',
          peerStatusIcon: '🛡️',
          peerStatusMessage: 'Do not overwrite',
          peerStatusClearAt: _futureClearAt,
        );
        await _insertConversation(
          database,
          token: 'malformed-room',
          rawJson: '{',
        );
        await _insertConversation(
          database,
          token: 'missing-status-room',
          rawJson: _roomWire(
            token: 'missing-status-room',
            includeStatus: false,
          ),
        );
        await database.customStatement('PRAGMA user_version = 12');
        await database.close();
        database = AppDatabase.forTesting(NativeDatabase(fixture.file));

        var rooms = await _roomsByToken(database);
        expect(database.schemaVersion, 18);
        expect(rooms['repair-room']!.peerStatus, 'online');
        expect(rooms['repair-room']!.peerStatusIcon, '🟢');
        expect(rooms['repair-room']!.peerStatusMessage, 'Available');
        expect(rooms['repair-room']!.peerStatusClearAt, _futureClearAt);
        expect(rooms['projected-room']!.peerStatus, 'dnd');
        expect(rooms['projected-room']!.peerStatusIcon, '🛡️');
        expect(rooms['projected-room']!.peerStatusMessage, 'Do not overwrite');
        _expectNoPresence(rooms['malformed-room']!);
        _expectNoPresence(rooms['missing-status-room']!);

        await (database.update(
          database.cachedConversations,
        )..where((row) => row.token.equals('repair-room'))).write(
          CachedConversationsCompanion(
            rawJson: Value(
              _roomWire(
                token: 'repair-room',
                status: 'busy',
                statusIcon: '🔴',
                statusMessage: 'Changed after migration',
              ),
            ),
          ),
        );
        await database.close();
        database = AppDatabase.forTesting(NativeDatabase(fixture.file));
        rooms = await _roomsByToken(database);

        expect(database.schemaVersion, 18);
        expect(rooms['repair-room']!.peerStatus, 'online');
        expect(rooms['repair-room']!.peerStatusIcon, '🟢');
        expect(rooms['repair-room']!.peerStatusMessage, 'Available');
        _expectNoPresence(rooms['malformed-room']!);
        _expectNoPresence(rooms['missing-status-room']!);
      } finally {
        await _closeAndDelete(database: database, directory: fixture.directory);
      }
    },
  );
}

Future<_PresenceFixture> _createFixture(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  final file = File(
    '${directory.path}${Platform.pathSeparator}conversations.sqlite',
  );
  return (
    directory: directory,
    file: file,
    database: AppDatabase.forTesting(NativeDatabase(file)),
  );
}

Future<void> _seedAccount(AppDatabase database) {
  return database
      .into(database.accounts)
      .insert(
        AccountsCompanion.insert(
          id: _accountId,
          serverUrl: 'https://cloud.example.invalid',
          loginName: 'fixture-user',
          serverProductName: 'Nextcloud',
          createdAtMillis: 1,
        ),
      );
}

Future<void> _insertConversation(
  AppDatabase database, {
  required String token,
  required String rawJson,
  String? peerStatus,
  String? peerStatusIcon,
  String? peerStatusMessage,
  int? peerStatusClearAt,
}) {
  return database
      .into(database.cachedConversations)
      .insert(
        CachedConversationsCompanion.insert(
          accountId: _accountId,
          token: token,
          displayName: 'Synthetic peer',
          description: '',
          lastActivity: 1,
          unreadMessages: 0,
          favorite: false,
          roomType: const Value(1),
          peerStatus: Value(peerStatus),
          peerStatusIcon: Value(peerStatusIcon),
          peerStatusMessage: Value(peerStatusMessage),
          peerStatusClearAt: Value(peerStatusClearAt),
          rawJson: rawJson,
        ),
      );
}

String _roomWire({
  required String token,
  String? status,
  int? statusClearAt,
  String? statusIcon,
  String? statusMessage,
  bool includeStatus = true,
}) {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = fixture['ocs']! as Map<String, Object?>;
  final room = Map<String, Object?>.from(
    (ocs['data']! as List<Object?>).first! as Map<String, Object?>,
  );
  room['token'] = token;
  room['type'] = 1;
  for (final key in const <String>[
    'status',
    'statusClearAt',
    'statusIcon',
    'statusMessage',
  ]) {
    room.remove(key);
  }
  if (includeStatus) {
    room['status'] = status;
    if (statusClearAt != null) room['statusClearAt'] = statusClearAt;
    if (statusIcon != null) room['statusIcon'] = statusIcon;
    if (statusMessage != null) room['statusMessage'] = statusMessage;
  }
  return jsonEncode(room);
}

Future<void> _downgradeToSchemaV8(AppDatabase database) async {
  await database.customStatement('DROP TABLE call_lifecycle_sessions');
  await database.customStatement('DROP TABLE call_sessions');
  await database.customStatement('DROP TABLE chat_drafts');
  await database.customStatement(
    'ALTER TABLE cached_conversations DROP COLUMN is_archived',
  );
  await database.customStatement('PRAGMA user_version = 8');
}

Future<Map<String, CachedConversation>> _roomsByToken(
  AppDatabase database,
) async {
  final rooms = await database.select(database.cachedConversations).get();
  return <String, CachedConversation>{
    for (final room in rooms) room.token: room,
  };
}

void _expectNoPresence(CachedConversation room) {
  expect(room.peerStatus, isNull);
  expect(room.peerStatusIcon, isNull);
  expect(room.peerStatusMessage, isNull);
  expect(room.peerStatusClearAt, isNull);
}

Future<void> _closeAndDelete({
  required AppDatabase? database,
  required Directory? directory,
}) async {
  await database?.close();
  if (directory != null && await directory.exists()) {
    await directory.delete(recursive: true);
  }
}

typedef _PresenceFixture = ({
  Directory directory,
  File file,
  AppDatabase database,
});
