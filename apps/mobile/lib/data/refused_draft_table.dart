part of 'app_database.dart';

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

/// Independent copies of text the outbox could not accept.
@DataClassName('RefusedTextDraft')
class RefusedTextDrafts extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get roomToken => text()();
  TextColumn get draftId => text()();
  TextColumn get message => text()();
  IntColumn get threadId => integer().nullable()();
  IntColumn get replyTo => integer().nullable()();
  BoolColumn get silent => boolean()();
  IntColumn get createdAtMillis => integer()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, roomToken, draftId};
}
