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

@DriftDatabase(
  tables: [
    Accounts,
    CachedConversations,
    ConversationAvatars,
    ChatCapabilities,
    ChatScopes,
    CachedChatMessages,
    TextSendOperations,
    ChatDrafts,
    AttachmentRuntimeAccounts,
    AttachmentJobs,
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
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.readOnly,
        );
        await migrator.createTable(chatCapabilities);
        await migrator.createTable(chatScopes);
        await migrator.createTable(cachedChatMessages);
        await migrator.createTable(textSendOperations);
      }
      if (from < 3) {
        await migrator.addColumn(accounts, accounts.talkFeaturesJson);
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.roomType,
        );
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.roomName,
        );
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.objectType,
        );
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.avatarVersion,
        );
        await migrator.addColumn(
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
        await migrator.addColumn(
          conversationAvatars,
          conversationAvatars.isCustomAvatar,
        );
      }
      if (from < 4) {
        await customStatement('DELETE FROM conversation_avatars');
      }
      if (from >= 2 && from < 5) {
        await migrator.addColumn(
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
        await migrator.addColumn(
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
      if (from < 8) {
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.peerStatus,
        );
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.peerStatusIcon,
        );
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.peerStatusMessage,
        );
        await migrator.addColumn(
          cachedConversations,
          cachedConversations.peerStatusClearAt,
        );
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
}
