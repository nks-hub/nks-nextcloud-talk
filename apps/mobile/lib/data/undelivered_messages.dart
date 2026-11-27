import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';
import 'app_database.dart';

final class UndeliveredMessage {
  const UndeliveredMessage({
    required this.account,
    required this.room,
    required this.id,
    required this.text,
    required this.state,
    required this.time,
    this.thread,
  });
  final String account, room, id, text, state;
  final int time;
  final int? thread;

  factory UndeliveredMessage.refused(RefusedTextDraft d) => UndeliveredMessage(
    account: d.accountId,
    room: d.roomToken,
    id: 'refused-draft-${d.draftId}',
    text: d.message,
    state: 'failed',
    time: d.createdAtMillis,
    thread: d.threadId,
  );
}

final undeliveredSelectionProvider = StateProvider<UndeliveredMessage?>(
  (_) => null,
);

final selectedUndeliveredOperationProvider = StreamProvider.autoDispose
    .family<StoredTextSendOperation?, UndeliveredMessage>((ref, item) {
      final db = ref.watch(appDatabaseProvider);
      return (db.select(db.textSendOperations)..where(
            (r) =>
                r.accountId.equals(item.account) &
                r.roomToken.equals(item.room) &
                r.operationId.equals(item.id) &
                r.outboxState.isIn(const [
                  'queued',
                  'sending',
                  'retryable',
                  'awaitingConfirmation',
                  'failed',
                ]),
          ))
          .watchSingleOrNull();
    });

/// Read admissions and refused drafts together: their ownership changes in one
/// transaction. Completed, skipped and cancelled sends require no intervention.
final storedUndeliveredProvider = StreamProvider.autoDispose
    .family<List<UndeliveredMessage>, String>((ref, account) {
      final db = ref.watch(appDatabaseProvider);
      return db
          .customSelect(
            '''
    SELECT room_token, operation_id AS id, message, outbox_state AS state,
           created_at_millis, COALESCE(composer_thread_id, thread_id) AS thread
      FROM text_send_operations WHERE account_id = ?
        AND outbox_state IN ('queued','sending','retryable','awaitingConfirmation','failed')
    UNION ALL
    SELECT room_token, 'refused-draft-' || draft_id, message, 'failed',
           created_at_millis, thread_id
      FROM refused_text_drafts WHERE account_id = ?
    ''',
            variables: [Variable(account), Variable(account)],
            readsFrom: {db.textSendOperations, db.refusedTextDrafts},
          )
          .watch()
          .map(
            (rows) => [
              for (final row in rows)
                UndeliveredMessage(
                  account: account,
                  room: row.read<String>('room_token'),
                  id: row.read<String>('id'),
                  text: row.read<String>('message'),
                  state: row.read<String>('state'),
                  time: row.read<int>('created_at_millis'),
                  thread: row.readNullable<int>('thread'),
                ),
            ],
          );
    });

final undeliveredMessagesProvider = Provider.autoDispose
    .family<AsyncValue<List<UndeliveredMessage>>, String>((ref, account) {
      final stored = ref.watch(storedUndeliveredProvider(account));
      final recovery = ref.watch(recoverableTextDraftStoreProvider);
      final memory = recovery
          .volatileForAccount(account)
          .map(UndeliveredMessage.refused);
      if (!stored.hasValue && memory.isEmpty) return stored;
      final rows =
          <String, UndeliveredMessage>{
            for (final row in [...?stored.valueOrNull, ...memory])
              if (!row.id.startsWith('refused-draft-') ||
                  !recovery.isActive(row.id.substring('refused-draft-'.length)))
                row.id: row,
          }.values.toList()..sort((a, b) {
            final time = a.time.compareTo(b.time);
            return time == 0 ? a.id.compareTo(b.id) : time;
          });
      return AsyncData(rows);
    });
