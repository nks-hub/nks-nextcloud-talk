import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

@DataClassName('StoredAccount')
class Accounts extends Table {
  TextColumn get id => text()();

  TextColumn get serverUrl => text()();

  TextColumn get loginName => text()();

  TextColumn get serverProductName => text()();

  TextColumn get talkFeaturesJson => text().withDefault(const Constant('[]'))();

  BoolColumn get selected => boolean().withDefault(const Constant(false))();

  IntColumn get createdAtMillis => integer()();

  TextColumn get conversationCursor => text().nullable()();

  TextColumn get conversationHash => text().nullable()();

  TextColumn get emptyConfirmationRequestId => text().nullable()();

  IntColumn get emptyConfirmationObservedAtMillis => integer().nullable()();

  IntColumn get lastSyncedAtMillis => integer().nullable()();

  TextColumn get lastSyncError => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {serverUrl, loginName},
  ];
}

@DataClassName('CachedConversation')
class CachedConversations extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get token => text()();

  TextColumn get displayName => text()();

  TextColumn get description => text()();

  IntColumn get lastActivity => integer()();

  IntColumn get unreadMessages => integer()();

  BoolColumn get favorite => boolean()();

  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  IntColumn get readOnly => integer().withDefault(const Constant(0))();

  IntColumn get roomType => integer().withDefault(const Constant(0))();

  TextColumn get roomName => text().withDefault(const Constant(''))();

  TextColumn get objectType => text().withDefault(const Constant(''))();

  TextColumn get avatarVersion => text().withDefault(const Constant(''))();

  BoolColumn get isCustomAvatar =>
      boolean().withDefault(const Constant(false))();

  TextColumn get peerStatus => text().nullable()();

  TextColumn get peerStatusIcon => text().nullable()();

  TextColumn get peerStatusMessage => text().nullable()();

  IntColumn get peerStatusClearAt => integer().nullable()();

  TextColumn get lastMessageText => text().nullable()();

  IntColumn get lastMessageTimestamp => integer().nullable()();

  TextColumn get rawJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, token};
}

@DataClassName('StoredConversationAvatar')
class ConversationAvatars extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get cacheKey => text()();

  BlobColumn get body => blob()();

  TextColumn get contentType => text()();

  BoolColumn get isCustomAvatar => boolean().nullable()();

  TextColumn get etag => text().nullable()();

  TextColumn get lastModified => text().nullable()();

  IntColumn get expiresAtMillis => integer()();

  IntColumn get updatedAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, cacheKey};
}

@DataClassName('StoredChatCapability')
class ChatCapabilities extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get fingerprint => text()();

  IntColumn get generation => integer().withDefault(const Constant(1))();

  IntColumn get credentialGeneration =>
      integer().withDefault(const Constant(1))();

  TextColumn get lane => text().withDefault(const Constant('ready'))();

  IntColumn get updatedAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}

@DataClassName('StoredChatScope')
class ChatScopes extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get roomToken => text()();

  TextColumn get scopeKey => text()();

  IntColumn get threadId => integer().nullable()();

  TextColumn get historyCursor => text()();

  TextColumn get futureCursor => text()();

  TextColumn get lastCommonRead => text()();

  IntColumn get lastReadMessage => integer()();

  IntColumn get unreadMessages => integer()();

  BoolColumn get hasHistory => boolean()();

  BoolColumn get futureConverged => boolean()();

  TextColumn get blocksJson => text()();

  IntColumn get lastSyncedAtMillis => integer().nullable()();

  TextColumn get lastSyncError => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, roomToken, scopeKey};
}

@DataClassName('CachedChatMessage')
@TableIndex(
  name: 'cached_chat_messages_attachment_confirmation',
  columns: {#accountId, #roomToken, #referenceId, #messageId},
)
class CachedChatMessages extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get roomToken => text()();

  IntColumn get messageId => integer()();

  TextColumn get actorType => text()();

  TextColumn get actorId => text()();

  TextColumn get actorDisplayName => text()();

  IntColumn get timestamp => integer()();

  TextColumn get systemMessage => text()();

  TextColumn get messageType => text()();

  TextColumn get referenceId => text()();

  TextColumn get displayText => text()();

  BoolColumn get deleted => boolean()();

  IntColumn get threadId => integer().nullable()();

  TextColumn get rawJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, roomToken, messageId};
}

@DataClassName('CachedThread')
class CachedThreads extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get roomToken => text()();

  IntColumn get threadId => integer()();

  TextColumn get title => text()();

  IntColumn get lastMessageId => integer()();

  IntColumn get lastActivity => integer()();

  IntColumn get numReplies => integer()();

  IntColumn get notificationLevel => integer()();

  BoolColumn get recent => boolean().withDefault(const Constant(false))();

  BoolColumn get subscribed => boolean().withDefault(const Constant(false))();

  BoolColumn get detailed => boolean().withDefault(const Constant(false))();

  TextColumn get rawJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, roomToken, threadId};
}

@DataClassName('StoredTextSendOperation')
class TextSendOperations extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get operationId => text()();

  TextColumn get roomToken => text()();

  TextColumn get referenceId => text()();

  TextColumn get message => text()();

  TextColumn get replayContractRevision => text()();

  IntColumn get enqueueSequence => integer()();

  TextColumn get outboxState => text()();

  IntColumn get attemptCount => integer()();

  TextColumn get messageIdsJson => text()();

  BoolColumn get duplicateRiskAcknowledged => boolean()();

  TextColumn get errorClass => text().nullable()();

  IntColumn get nextAttemptAt => integer().nullable()();

  IntColumn get replyTo => integer().nullable()();

  IntColumn get threadId => integer().nullable()();

  TextColumn get replyToToken => text().nullable()();

  TextColumn get parentRoomToken => text().nullable()();

  IntColumn get createdAtMillis => integer()();

  IntColumn get updatedAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, operationId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, referenceId},
    {accountId, roomToken, enqueueSequence},
  ];
}

/// Composer text that has not been admitted to the outbox yet. A send can be
/// refused before admission, for example while the device is offline, so the
/// text has to survive process death on its own.
@DataClassName('StoredChatDraft')
class ChatDrafts extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get roomToken => text()();

  TextColumn get scopeKey => text()();

  TextColumn get draftText => text()();

  IntColumn get updatedAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, roomToken, scopeKey};
}

@DataClassName('StoredAttachmentRuntimeAccount')
class AttachmentRuntimeAccounts extends Table {
  TextColumn get accountId => text().references(Accounts, #id)();

  TextColumn get serverUrl => text()();

  TextColumn get lane => text()();

  IntColumn get credentialGeneration => integer()();

  IntColumn get capabilityGeneration => integer()();

  IntColumn get updatedAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}

@DataClassName('StoredAttachmentJob')
class AttachmentJobs extends Table {
  TextColumn get accountId =>
      text().references(AttachmentRuntimeAccounts, #accountId)();

  TextColumn get jobId => text()();

  TextColumn get serverUrl => text()();

  IntColumn get capabilityGeneration => integer()();

  TextColumn get replayContractRevision => text()();

  TextColumn get davUserId => text()();

  TextColumn get roomToken => text()();

  TextColumn get referenceId => text()();

  TextColumn get sourceHandle => text()();

  TextColumn get sourceOwnership => text()();

  IntColumn get sourceByteLength => integer()();

  TextColumn get sourceSha256 => text()();

  TextColumn get sourceMimeType => text()();

  TextColumn get sourceDisplayName => text()();

  TextColumn get messageKind => text()();

  TextColumn get caption => text().nullable()();

  IntColumn get replyTo => integer().nullable()();

  IntColumn get threadId => integer().nullable()();

  TextColumn get threadTitle => text().nullable()();

  BoolColumn get silent => boolean()();

  IntColumn get enqueueSequence => integer()();

  IntColumn get normalUploadMaximumBytes => integer()();

  IntColumn get chunkSizeBytes => integer()();

  TextColumn get uploadSessionId => text().nullable()();

  TextColumn get phase => text()();

  TextColumn get resumePhase => text().nullable()();

  TextColumn get remoteDraftFolder => text().nullable()();

  TextColumn get remoteTemporaryPath => text().nullable()();

  BoolColumn get chunkCollectionReady => boolean()();

  BoolColumn get chunkManifestLoaded => boolean()();

  TextColumn get verifiedChunksJson => text()();

  TextColumn get inFlightStep => text().nullable()();

  TextColumn get inFlightRequestId => text().nullable()();

  IntColumn get attemptCount => integer()();

  BoolColumn get finalizationDispatched => boolean()();

  BoolColumn get cleanupChunkSession => boolean()();

  BoolColumn get cleanupDraftFile => boolean()();

  TextColumn get messageIdsJson => text()();

  TextColumn get errorClass => text().nullable()();

  BoolColumn get profileFederated => boolean()();

  BoolColumn get profileEnabled => boolean()();

  BoolColumn get profileCaption => boolean()();

  BoolColumn get profileVoice => boolean()();

  BoolColumn get profileReply => boolean()();

  BoolColumn get profileThreads => boolean()();

  BoolColumn get profileSilent => boolean()();

  BoolColumn get roomCanWrite => boolean()();

  IntColumn get automaticRetryCount =>
      integer().withDefault(const Constant(0))();

  IntColumn get nextAttemptAtMillis => integer().nullable()();

  BoolColumn get sourceReleased =>
      boolean().withDefault(const Constant(false))();

  TextColumn get localCleanupError => text().nullable()();

  IntColumn get createdAtMillis => integer()();

  IntColumn get updatedAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, jobId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, referenceId},
    {accountId, roomToken, enqueueSequence},
  ];
}

/// Minimal non-secret state needed to recover a signaling lane after process
/// death. HPB tickets, tokens, settings, participants and pending frames are
/// deliberately transient and never belong in this table.
@DataClassName('StoredCallSession')
class CallSessions extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get roomToken => text()();

  TextColumn get serverUrl => text()();

  IntColumn get credentialGeneration => integer()();

  IntColumn get capabilityGeneration => integer()();

  TextColumn get settingsRevision => text()();

  BoolColumn get profileEnabled => boolean()();

  BoolColumn get profileChatRelay => boolean()();

  TextColumn get nextcloudSessionId => text()();

  IntColumn get connectionEpoch => integer()();

  IntColumn get roomEpoch => integer()();

  BoolColumn get renegotiationRequired => boolean()();

  IntColumn get updatedAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, roomToken};
}

/// Durable non-secret intent and confirmation state for Talk's v4 call REST
/// lifecycle. This is deliberately separate from [CallSessions]: releasing a
/// signaling lane must not erase an ambiguous REST join, flag update or leave.
@DataClassName('StoredCallLifecycleSession')
class CallLifecycleSessions extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get roomToken => text()();

  TextColumn get serverUrl => text()();

  TextColumn get nextcloudSessionId => text()();

  IntColumn get credentialGeneration => integer()();

  IntColumn get capabilityGeneration => integer()();

  TextColumn get capabilityRevision => text()();

  TextColumn get phase => text()();

  IntColumn get confirmedFlags => integer().nullable()();

  IntColumn get requestedFlags => integer().nullable()();

  BoolColumn get endForEveryone => boolean().nullable()();

  IntColumn get mutationSequence => integer()();

  IntColumn get updatedAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, roomToken};
}

@DriftDatabase(
  tables: [
    Accounts,
    CachedConversations,
    ConversationAvatars,
    ChatCapabilities,
    ChatScopes,
    CachedChatMessages,
    CachedThreads,
    TextSendOperations,
    ChatDrafts,
    AttachmentRuntimeAccounts,
    AttachmentJobs,
    CallSessions,
    CallLifecycleSessions,
  ],
)
final class AppDatabase extends _$AppDatabase {
  AppDatabase()
    : super(
        driftDatabase(
          name: 'nks_nextcloud_talk',
          native: DriftNativeOptions(
            shareAcrossIsolates: true,
            setup: (database) => database.execute('PRAGMA foreign_keys = ON'),
          ),
        ),
      );

  AppDatabase.forTesting(super.connection);

  @override
  int get schemaVersion => 14;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      if (from > to) {
        throw StateError(
          'Database schema version $from is newer than supported $to',
        );
      }
      if (from < 2) {
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.readOnly,
        );
        await migrator.createTable(chatCapabilities);
        await migrator.createTable(chatScopes);
        await migrator.createTable(cachedChatMessages);
        await migrator.createTable(textSendOperations);
      }
      if (from < 3) {
        await _addColumnIfMissing(migrator,accounts, accounts.talkFeaturesJson);
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.roomType,
        );
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.roomName,
        );
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.objectType,
        );
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.avatarVersion,
        );
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.isCustomAvatar,
        );
        await migrator.createTable(conversationAvatars);
        await customStatement('''
          UPDATE cached_conversations
          SET room_type = CASE
                WHEN json_valid(raw_json)
                  THEN COALESCE(CAST(json_extract(raw_json, '\$.type') AS INTEGER), 0)
                ELSE 0
              END,
              room_name = CASE
                WHEN json_valid(raw_json)
                  THEN COALESCE(json_extract(raw_json, '\$.name'), '')
                ELSE ''
              END,
              object_type = CASE
                WHEN json_valid(raw_json)
                  THEN COALESCE(json_extract(raw_json, '\$.objectType'), '')
                ELSE ''
              END,
              avatar_version = CASE
                WHEN json_valid(raw_json)
                  THEN COALESCE(json_extract(raw_json, '\$.avatarVersion'), '')
                ELSE ''
              END,
              is_custom_avatar = CASE
                WHEN json_valid(raw_json)
                  THEN COALESCE(json_extract(raw_json, '\$.isCustomAvatar'), 0)
                ELSE 0
              END
        ''');
      }
      if (from >= 3 && from < 4) {
        await _addColumnIfMissing(migrator,
          conversationAvatars,
          conversationAvatars.isCustomAvatar,
        );
      }
      if (from < 4) {
        await customStatement('DELETE FROM conversation_avatars');
      }
      if (from >= 2 && from < 5) {
        await _addColumnIfMissing(migrator,
          textSendOperations,
          textSendOperations.threadId,
        );
      }
      if (from < 6) {
        await migrator.createTable(attachmentRuntimeAccounts);
        await migrator.createTable(attachmentJobs);
      }
      if (from < 7) {
        await customStatement(
          'CREATE INDEX IF NOT EXISTS '
          'cached_chat_messages_attachment_confirmation '
          'ON cached_chat_messages '
          '(account_id, room_token, reference_id, message_id)',
        );
      }
      if (from < 9) {
        await migrator.createTable(chatDrafts);
      }
      if (from < 10) {
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.isArchived,
        );
        await customStatement('''
          UPDATE cached_conversations
          SET is_archived = CASE
                WHEN json_valid(raw_json)
                  THEN COALESCE(json_extract(raw_json, '\$.isArchived'), 0)
                ELSE 0
              END
        ''');
      }
      if (from < 11) {
        await migrator.createTable(callSessions);
      }
      if (from < 12) {
        await migrator.createTable(callLifecycleSessions);
      }
      if (from < 8) {
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.peerStatus,
        );
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.peerStatusIcon,
        );
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.peerStatusMessage,
        );
        await _addColumnIfMissing(migrator,
          cachedConversations,
          cachedConversations.peerStatusClearAt,
        );
      }
      if (from < 13) {
        await customStatement(r'''
          UPDATE cached_conversations
          SET peer_status = CASE
                WHEN json_valid(raw_json)
                  THEN json_extract(raw_json, '$.status')
                ELSE NULL
              END,
              peer_status_icon = CASE
                WHEN json_valid(raw_json)
                  THEN json_extract(raw_json, '$.statusIcon')
                ELSE NULL
              END,
              peer_status_message = CASE
                WHEN json_valid(raw_json)
                  THEN json_extract(raw_json, '$.statusMessage')
                ELSE NULL
              END,
              peer_status_clear_at = CASE
                WHEN json_valid(raw_json)
                  THEN json_extract(raw_json, '$.statusClearAt')
                ELSE NULL
              END
          WHERE peer_status IS NULL
            AND peer_status_icon IS NULL
            AND peer_status_message IS NULL
            AND peer_status_clear_at IS NULL
            AND CASE
                  WHEN json_valid(raw_json)
                    THEN json_type(raw_json, '$.status') = 'text'
                  ELSE 0
                END
        ''');
      }
      if (from < 14) {
        await migrator.createTable(cachedThreads);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      final violations = await customSelect('PRAGMA foreign_key_check').get();
      if (violations.isNotEmpty) {
        throw StateError('Database foreign-key validation failed');
      }
    },
  );

  /// Adds [column] to [table] unless it is already there.
  ///
  /// An interrupted migration keeps the steps it managed to run but leaves
  /// `user_version` at the old value, so the next start replays them. Every
  /// other step survives that replay on its own — tables and indexes are
  /// created with `IF NOT EXISTS` and the backfills recompute from
  /// `raw_json` — which left `addColumn` as the only step that could fail
  /// and lock the app out of its own database for good.
  Future<void> _addColumnIfMissing(
    Migrator migrator,
    TableInfo<Table, dynamic> table,
    GeneratedColumn<Object> column,
  ) async {
    final existing = await customSelect(
      'PRAGMA table_info(${table.actualTableName})',
    ).get();
    final present = existing.any(
      (row) => row.read<String>('name') == column.name,
    );
    if (!present) {
      await migrator.addColumn(table, column);
    }
  }
}
