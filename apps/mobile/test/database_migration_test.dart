@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test('schema v1 to v15 preserves its account and conversation', () async {
    final fixture =
        readFixtureJson(
              'conversation-list/fixtures/conversations-full.response.json',
            )
            as Map<String, Object?>;
    final ocs = fixture['ocs']! as Map<String, Object?>;
    final rooms = ocs['data']! as List<Object?>;
    final rawRoom = rooms.first! as Map<String, Object?>;
    final rawJson = jsonEncode(rawRoom).replaceAll("'", "''");
    final database = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) {
          raw
            ..execute(_accountsV2Sql)
            ..execute(_cachedConversationsV1Sql)
            ..execute(
              "INSERT INTO accounts (id, server_url, login_name, "
              "server_product_name, selected, created_at_millis) VALUES "
              "('account-a', 'https://cloud.example.invalid', "
              "'fixture-user', 'Nextcloud', 1, 1)",
            )
            ..execute(
              "INSERT INTO cached_conversations (account_id, token, "
              "display_name, description, last_activity, unread_messages, "
              "favorite, raw_json) VALUES ('account-a', "
              "'synthetic-room-token-a', 'Synthetic room A', '', 1, 0, 0, "
              "'$rawJson')",
            )
            ..execute('PRAGMA user_version = 1');
        },
      ),
    );
    addTearDown(database.close);

    final account = await database.select(database.accounts).getSingle();
    final room = await database
        .select(database.cachedConversations)
        .getSingle();

    expect(database.schemaVersion, 18);
    expect(account.id, 'account-a');
    expect(account.talkFeaturesJson, '[]');
    expect(room.token, 'synthetic-room-token-a');
    expect(room.readOnly, 0);
    expect(room.roomType, 2);
    expect(room.roomName, 'synthetic-room-a');
    expect(await database.select(database.chatCapabilities).get(), isEmpty);
    expect(await database.select(database.chatScopes).get(), isEmpty);
    expect(await database.select(database.cachedChatMessages).get(), isEmpty);
    expect(await database.select(database.textSendOperations).get(), isEmpty);
    expect(
      await database.select(database.attachmentRuntimeAccounts).get(),
      isEmpty,
    );
    expect(await database.select(database.attachmentJobs).get(), isEmpty);
  });

  test(
    'schema v2 to v15 preserves rooms and backfills avatar metadata',
    () async {
      final fixture =
          readFixtureJson(
                'conversation-list/fixtures/conversations-full.response.json',
              )
              as Map<String, Object?>;
      final ocs = fixture['ocs']! as Map<String, Object?>;
      final rooms = ocs['data']! as List<Object?>;
      final rawRoom = rooms.first! as Map<String, Object?>;
      final rawJson = jsonEncode(rawRoom).replaceAll("'", "''");

      final database = AppDatabase.forTesting(
        NativeDatabase.memory(
          setup: (raw) {
            raw
              ..execute(_accountsV2Sql)
              ..execute(_cachedChatMessagesV2Sql)
              ..execute(_cachedConversationsV2Sql)
              ..execute(_textSendOperationsV4Sql)
              ..execute(
                "INSERT INTO accounts (id, server_url, login_name, "
                "server_product_name, selected, created_at_millis) VALUES "
                "('account-a', 'https://cloud.example.invalid', "
                "'fixture-user', 'Nextcloud', 1, 1)",
              )
              ..execute(
                "INSERT INTO cached_conversations (account_id, token, "
                "display_name, description, last_activity, unread_messages, "
                "favorite, read_only, raw_json) VALUES "
                "('account-a', 'synthetic-room-token-a', 'Synthetic room A', "
                "'', 1, 0, 0, 0, '$rawJson')",
              )
              ..execute('PRAGMA user_version = 2');
          },
        ),
      );
      addTearDown(database.close);

      final room = await database
          .select(database.cachedConversations)
          .getSingle();
      final account = await database.select(database.accounts).getSingle();

      expect(database.schemaVersion, 18);
      expect(room.token, 'synthetic-room-token-a');
      expect(room.roomType, 2);
      expect(room.roomName, 'synthetic-room-a');
      expect(room.objectType, '');
      expect(room.avatarVersion, '1');
      expect(room.isCustomAvatar, isFalse);
      expect(account.talkFeaturesJson, '[]');
      expect(
        await database.select(database.conversationAvatars).get(),
        isEmpty,
      );
    },
  );

  test('schema v3 to v15 clears avatars lacking custom metadata', () async {
    final database = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) {
          raw
            ..execute(_accountsV3Sql)
            ..execute(_cachedConversationsV3Sql)
            ..execute(_cachedChatMessagesV2Sql)
            ..execute(_conversationAvatarsV3Sql)
            ..execute(_textSendOperationsV4Sql)
            ..execute(
              "INSERT INTO accounts (id, server_url, login_name, "
              "server_product_name, talk_features_json, selected, "
              "created_at_millis) VALUES ('account-a', "
              "'https://cloud.example.invalid', 'fixture-user', "
              "'Nextcloud', '[]', 1, 1)",
            )
            ..execute(
              "INSERT INTO conversation_avatars (account_id, cache_key, "
              "body, content_type, expires_at_millis, updated_at_millis) "
              "VALUES ('account-a', 'fixture-avatar', X'89504E47', "
              "'image/png', 1, 1)",
            )
            ..execute('PRAGMA user_version = 3');
        },
      ),
    );
    addTearDown(database.close);

    expect(database.schemaVersion, 18);
    expect(await database.select(database.conversationAvatars).get(), isEmpty);
  });

  test(
    'schema v4 to v15 preserves outbox rows with no thread binding',
    () async {
      final database = AppDatabase.forTesting(
        NativeDatabase.memory(
          setup: (raw) {
            raw
              ..execute(_accountsV3Sql)
              ..execute(_cachedConversationsV3Sql)
              ..execute(_cachedChatMessagesV2Sql)
              ..execute(_textSendOperationsV4Sql)
              ..execute(
                "INSERT INTO accounts (id, server_url, login_name, "
                "server_product_name, talk_features_json, selected, "
                "created_at_millis) VALUES ('account-a', "
                "'https://cloud.example.invalid', 'fixture-user', "
                "'Nextcloud', '[]', 1, 1)",
              )
              ..execute(
                "INSERT INTO text_send_operations (account_id, operation_id, "
                "room_token, reference_id, message, replay_contract_revision, "
                "enqueue_sequence, outbox_state, attempt_count, "
                "message_ids_json, duplicate_risk_acknowledged, "
                "created_at_millis, updated_at_millis) VALUES ('account-a', "
                "'operation-a', 'synthetic-room-token-a', 'reference-a', "
                "'Synthetic message', 'fixture-r1', 1, 'queued', 0, '[]', 0, "
                "1, 1)",
              )
              ..execute('PRAGMA user_version = 4');
          },
        ),
      );
      addTearDown(database.close);

      final operation = await database
          .select(database.textSendOperations)
          .getSingle();

    expect(database.schemaVersion, 18);
      expect(operation.operationId, 'operation-a');
      expect(operation.threadId, isNull);
    },
  );

  test(
    'schema v5 to v15 preserves thread binding and recovers sending rows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nctalk-chat-restart-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}chat.sqlite',
      );
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
                talkFeaturesJson: Value(
                  jsonEncode(<String>[
                    'chat-v2',
                    'chat-reference-id',
                    'threads',
                  ]),
                ),
                createdAtMillis: 1,
              ),
            );
        await database
            .into(database.chatCapabilities)
            .insert(
              ChatCapabilitiesCompanion.insert(
                accountId: 'account-a',
                fingerprint: 'fixture-capabilities',
                updatedAtMillis: 1,
              ),
            );
        await _insertThreadOperation(
          database,
          operationId: 'aaaaaaaa-0000-4000-8000-000000000001',
          referenceId: '11111111-1111-4111-8111-111111111111',
          enqueueSequence: 1,
          state: TextSendOutboxState.queued,
        );
        await _insertThreadOperation(
          database,
          operationId: 'aaaaaaaa-0000-4000-8000-000000000002',
          referenceId: '22222222-2222-4222-8222-222222222222',
          enqueueSequence: 2,
          state: TextSendOutboxState.sending,
        );
        await database.close();
        database = AppDatabase.forTesting(NativeDatabase(file));

        var snapshot = await ChatRepository(
          database,
        ).loadRuntimeForTesting('account-a');
        var operations =
            snapshot.accounts.values.single.operations.values.toList()..sort(
              (left, right) =>
                  left.enqueueSequence.compareTo(right.enqueueSequence),
            );
        expect(operations.map((operation) => operation.threadId), [109, 109]);
        expect(operations.map((operation) => operation.state), [
          TextSendOutboxState.queued,
          TextSendOutboxState.sending,
        ]);

        await ChatRepository(database).recoverInterruptedTextSends('account-a');
        await database.close();
        database = AppDatabase.forTesting(NativeDatabase(file));
        snapshot = await ChatRepository(
          database,
        ).loadRuntimeForTesting('account-a');
        operations = snapshot.accounts.values.single.operations.values.toList()
          ..sort(
            (left, right) =>
                left.enqueueSequence.compareTo(right.enqueueSequence),
          );

        expect(operations.map((operation) => operation.threadId), [109, 109]);
        expect(operations.first.state, TextSendOutboxState.queued);
        expect(operations.last.state, TextSendOutboxState.awaitingConfirmation);
        expect(operations.last.errorClass, 'process-interrupted');
      } finally {
        await database?.close();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );

  test('schema v6 to v15 preserves chat rows and creates join index', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-confirmation-index-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}chat.sqlite');
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
      await database
          .into(database.cachedChatMessages)
          .insert(
            CachedChatMessagesCompanion.insert(
              accountId: 'account-a',
              roomToken: 'rooma123',
              messageId: 101,
              actorType: 'users',
              actorId: 'fixture-user',
              actorDisplayName: 'Fixture User',
              timestamp: 1,
              systemMessage: '',
              messageType: 'comment',
              referenceId: '11111111-1111-4111-8111-111111111111',
              displayText: 'Synthetic attachment',
              deleted: false,
              rawJson: '{}',
            ),
          );
      await database.customStatement(
        'DROP INDEX cached_chat_messages_attachment_confirmation',
      );
      await _dropPresenceColumns(database);
      await database.customStatement(
        'ALTER TABLE cached_conversations DROP COLUMN is_archived',
      );
      await database.customStatement('PRAGMA user_version = 6');
      await database.close();

      database = AppDatabase.forTesting(NativeDatabase(file));
      final messages = await database.select(database.cachedChatMessages).get();
      final indexes = await database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'cached_chat_messages_attachment_confirmation'",
          )
          .get();

      expect(database.schemaVersion, 18);
      expect(messages.single.messageId, 101);
      expect(indexes, hasLength(1));
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('schema v7 to v15 adds nullable peer status columns', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-presence-columns-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}conversations.sqlite',
    );
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
      await database
          .into(database.cachedConversations)
          .insert(
            CachedConversationsCompanion.insert(
              accountId: 'account-a',
              token: 'rooma123',
              displayName: 'Synthetic room A',
              description: '',
              lastActivity: 1,
              unreadMessages: 0,
              favorite: false,
              rawJson: '{}',
            ),
          );
      await _dropPresenceColumns(database);
      await database.customStatement(
        'ALTER TABLE cached_conversations DROP COLUMN is_archived',
      );
      await database.customStatement('PRAGMA user_version = 7');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));

      final room = await database
          .select(database.cachedConversations)
          .getSingle();
      expect(database.schemaVersion, 18);
      expect(room.token, 'rooma123');
      expect(room.peerStatus, isNull);
      expect(room.peerStatusIcon, isNull);
      expect(room.peerStatusMessage, isNull);
      expect(room.peerStatusClearAt, isNull);
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('schema v8 to v15 creates the durable draft table', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-draft-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}drafts.sqlite',
    );
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
      await database.customStatement('DROP TABLE chat_drafts');
      await database.customStatement(
        'ALTER TABLE cached_conversations DROP COLUMN is_archived',
      );
      await database.customStatement('PRAGMA user_version = 8');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));

      final chat = ChatRepository(database);
      await chat.saveDraft(
        accountId: 'account-a',
        roomToken: 'rooma123',
        text: 'Recovered after an upgrade',
      );

      expect(database.schemaVersion, 18);
      expect(
        await chat.readDraft(accountId: 'account-a', roomToken: 'rooma123'),
        'Recovered after an upgrade',
      );
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('schema v9 to v15 backfills isArchived from raw_json', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-archive-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}archive.sqlite',
    );
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
      await database
          .into(database.cachedConversations)
          .insert(
            CachedConversationsCompanion.insert(
              accountId: 'account-a',
              token: 'rooma123',
              displayName: 'Synthetic room A',
              description: '',
              lastActivity: 1,
              unreadMessages: 0,
              favorite: false,
              rawJson: jsonEncode(const {'isArchived': true}),
            ),
          );
      await database.customStatement(
        'ALTER TABLE cached_conversations DROP COLUMN is_archived',
      );
      await database.customStatement('PRAGMA user_version = 9');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));

      final room = await database
          .select(database.cachedConversations)
          .getSingle();
      expect(database.schemaVersion, 18);
      expect(room.token, 'rooma123');
      expect(room.isArchived, isTrue);
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('schema v13 to v15 creates the account-scoped thread cache', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-thread-cache-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}threads.sqlite',
    );
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
      await database.customStatement('DROP TABLE cached_threads');
      await database.customStatement('PRAGMA user_version = 13');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));

      expect(database.schemaVersion, 18);
      expect(
        (await database.select(database.accounts).getSingle()).id,
        'account-a',
      );
      expect(await database.select(database.cachedThreads).get(), isEmpty);
      final columns = await database
          .customSelect('PRAGMA table_info(cached_threads)')
          .get();
      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll(<String>[
          'account_id',
          'room_token',
          'thread_id',
          'recent',
          'subscribed',
          'detailed',
        ]),
      );
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('schema v16 adds account themes without changing accounts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-account-theme-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}account-theme.sqlite',
    );
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
      await database.customStatement('DROP TABLE account_themes');
      await database.customStatement('PRAGMA user_version = 16');
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase(file));

      expect(database.schemaVersion, 18);
      expect(
        (await database.select(database.accounts).getSingle()).id,
        'account-a',
      );
      expect(await database.select(database.accountThemes).get(), isEmpty);
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test('refuses a newer schema without changing its version or data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-newer-schema-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}future.sqlite',
    );
    AppDatabase? database;
    try {
      database = AppDatabase.forTesting(NativeDatabase(file));
      await database.customStatement(
        'CREATE TABLE future_schema_probe (value TEXT NOT NULL)',
      );
      await database.customStatement(
        "INSERT INTO future_schema_probe (value) VALUES ('preserve-me')",
      );
      await database.customStatement('PRAGMA user_version = 19');
      await database.close();
      database = null;

      database = AppDatabase.forTesting(NativeDatabase(file));
      await expectLater(
        database.customSelect('SELECT 1').get(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('newer than supported'),
          ),
        ),
      );
      await database.close();
      database = null;

      int? observedVersion;
      String? observedValue;
      database = AppDatabase.forTesting(
        NativeDatabase(
          file,
          setup: (raw) {
            observedVersion = raw.userVersion;
            observedValue =
                raw
                        .select('SELECT value FROM future_schema_probe')
                        .single['value']
                    as String;
            throw const _DatabaseInspectionComplete();
          },
        ),
      );
      await expectLater(
        database.customSelect('SELECT 1').get(),
        throwsA(isA<_DatabaseInspectionComplete>()),
      );
      expect(observedVersion, 19);
      expect(observedValue, 'preserve-me');
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });
}

final class _DatabaseInspectionComplete implements Exception {
  const _DatabaseInspectionComplete();
}

Future<void> _dropPresenceColumns(AppDatabase database) async {
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

Future<void> _insertThreadOperation(
  AppDatabase database, {
  required String operationId,
  required String referenceId,
  required int enqueueSequence,
  required TextSendOutboxState state,
}) {
  return database
      .into(database.textSendOperations)
      .insert(
        TextSendOperationsCompanion.insert(
          accountId: 'account-a',
          operationId: operationId,
          roomToken: 'rooma123',
          referenceId: referenceId,
          message: 'Synthetic persisted named-thread send',
          replayContractRevision: textSendReplayContractRevision,
          enqueueSequence: enqueueSequence,
          outboxState: state.name,
          attemptCount: state == TextSendOutboxState.sending ? 1 : 0,
          messageIdsJson: '[]',
          duplicateRiskAcknowledged: false,
          threadId: const Value(109),
          createdAtMillis: 1,
          updatedAtMillis: 1,
        ),
      );
}

const _accountsV2Sql = '''
CREATE TABLE accounts (
  id TEXT NOT NULL PRIMARY KEY,
  server_url TEXT NOT NULL,
  login_name TEXT NOT NULL,
  server_product_name TEXT NOT NULL,
  selected INTEGER NOT NULL DEFAULT 0 CHECK (selected IN (0, 1)),
  created_at_millis INTEGER NOT NULL,
  conversation_cursor TEXT NULL,
  conversation_hash TEXT NULL,
  empty_confirmation_request_id TEXT NULL,
  empty_confirmation_observed_at_millis INTEGER NULL,
  last_synced_at_millis INTEGER NULL,
  last_sync_error TEXT NULL,
  UNIQUE(server_url, login_name)
)
''';

const _cachedConversationsV2Sql = '''
CREATE TABLE cached_conversations (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  display_name TEXT NOT NULL,
  description TEXT NOT NULL,
  last_activity INTEGER NOT NULL,
  unread_messages INTEGER NOT NULL,
  favorite INTEGER NOT NULL CHECK (favorite IN (0, 1)),
  read_only INTEGER NOT NULL DEFAULT 0,
  last_message_text TEXT NULL,
  last_message_timestamp INTEGER NULL,
  raw_json TEXT NOT NULL,
  PRIMARY KEY(account_id, token)
)
''';

const _cachedConversationsV3Sql = '''
CREATE TABLE cached_conversations (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  display_name TEXT NOT NULL,
  description TEXT NOT NULL,
  last_activity INTEGER NOT NULL,
  unread_messages INTEGER NOT NULL,
  favorite INTEGER NOT NULL CHECK (favorite IN (0, 1)),
  read_only INTEGER NOT NULL DEFAULT 0,
  room_type INTEGER NOT NULL DEFAULT 0,
  room_name TEXT NOT NULL DEFAULT '',
  object_type TEXT NOT NULL DEFAULT '',
  avatar_version TEXT NOT NULL DEFAULT '',
  is_custom_avatar INTEGER NOT NULL DEFAULT 0 CHECK (is_custom_avatar IN (0, 1)),
  last_message_text TEXT NULL,
  last_message_timestamp INTEGER NULL,
  raw_json TEXT NOT NULL,
  PRIMARY KEY(account_id, token)
)
''';

const _cachedConversationsV1Sql = '''
CREATE TABLE cached_conversations (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  display_name TEXT NOT NULL,
  description TEXT NOT NULL,
  last_activity INTEGER NOT NULL,
  unread_messages INTEGER NOT NULL,
  favorite INTEGER NOT NULL CHECK (favorite IN (0, 1)),
  last_message_text TEXT NULL,
  last_message_timestamp INTEGER NULL,
  raw_json TEXT NOT NULL,
  PRIMARY KEY(account_id, token)
)
''';

const _cachedChatMessagesV2Sql = '''
CREATE TABLE cached_chat_messages (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  room_token TEXT NOT NULL,
  message_id INTEGER NOT NULL,
  actor_type TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_display_name TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  system_message TEXT NOT NULL,
  message_type TEXT NOT NULL,
  reference_id TEXT NOT NULL,
  display_text TEXT NOT NULL,
  deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
  thread_id INTEGER NULL,
  raw_json TEXT NOT NULL,
  PRIMARY KEY(account_id, room_token, message_id)
)
''';

const _textSendOperationsV4Sql = '''
CREATE TABLE text_send_operations (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  operation_id TEXT NOT NULL,
  room_token TEXT NOT NULL,
  reference_id TEXT NOT NULL,
  message TEXT NOT NULL,
  replay_contract_revision TEXT NOT NULL,
  enqueue_sequence INTEGER NOT NULL,
  outbox_state TEXT NOT NULL,
  attempt_count INTEGER NOT NULL,
  message_ids_json TEXT NOT NULL,
  duplicate_risk_acknowledged INTEGER NOT NULL
    CHECK (duplicate_risk_acknowledged IN (0, 1)),
  error_class TEXT NULL,
  next_attempt_at INTEGER NULL,
  reply_to INTEGER NULL,
  reply_to_token TEXT NULL,
  parent_room_token TEXT NULL,
  created_at_millis INTEGER NOT NULL,
  updated_at_millis INTEGER NOT NULL,
  PRIMARY KEY(account_id, operation_id),
  UNIQUE(account_id, reference_id),
  UNIQUE(account_id, room_token, enqueue_sequence)
)
''';

const _accountsV3Sql = '''
CREATE TABLE accounts (
  id TEXT NOT NULL PRIMARY KEY,
  server_url TEXT NOT NULL,
  login_name TEXT NOT NULL,
  server_product_name TEXT NOT NULL,
  talk_features_json TEXT NOT NULL DEFAULT '[]',
  selected INTEGER NOT NULL DEFAULT 0 CHECK (selected IN (0, 1)),
  created_at_millis INTEGER NOT NULL,
  conversation_cursor TEXT NULL,
  conversation_hash TEXT NULL,
  empty_confirmation_request_id TEXT NULL,
  empty_confirmation_observed_at_millis INTEGER NULL,
  last_synced_at_millis INTEGER NULL,
  last_sync_error TEXT NULL,
  UNIQUE(server_url, login_name)
)
''';

const _conversationAvatarsV3Sql = '''
CREATE TABLE conversation_avatars (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  cache_key TEXT NOT NULL,
  body BLOB NOT NULL,
  content_type TEXT NOT NULL,
  etag TEXT NULL,
  last_modified TEXT NULL,
  expires_at_millis INTEGER NOT NULL,
  updated_at_millis INTEGER NOT NULL,
  PRIMARY KEY(account_id, cache_key)
)
''';
