part of 'app_database.dart';

@DataClassName('StoredTextSendOperation')
class TextSendOperations extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get operationId => text()();

  TextColumn get roomToken => text()();

  TextColumn get referenceId => text()();

  TextColumn get message => text()();

  TextColumn get replayContractRevision => text()();

  /// Whether this message must raise no notification on delivery.
  ///
  /// Durable on purpose: the outbox replays after process death, and a
  /// message that went out loud because the flag lived only in memory would
  /// be the opposite of what the switch promised.
  BoolColumn get silent => boolean().withDefault(const Constant(false))();

  IntColumn get enqueueSequence => integer()();

  TextColumn get outboxState => text()();

  IntColumn get attemptCount => integer()();

  TextColumn get messageIdsJson => text()();

  BoolColumn get duplicateRiskAcknowledged => boolean()();

  TextColumn get errorClass => text().nullable()();

  /// Seconds since the epoch. On a `retryable` row the send is due then; on
  /// an `awaitingConfirmation` row a chat read started after it may prove the
  /// server never stored the message.
  IntColumn get nextAttemptAt => integer().nullable()();

  /// How often the row went back to the queue on such a proof alone.
  IntColumn get automaticResendCount =>
      integer().withDefault(const Constant(0))();

  /// Thread in the client UI. Ordinary threads and quoted room messages use
  /// the same reply field on the wire.
  IntColumn get composerThreadId => integer().nullable()();

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
