import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'app_database.dart';
import 'chat_repository.dart';

/// A send owns its draft until the outbox admits it in the same transaction.
final class RecoverableTextDraftStore extends ChangeNotifier {
  RecoverableTextDraftStore(this._db);
  final AppDatabase _db;
  final _active = <String, String>{};
  final _composer =
      <(String, String, int?), ({ComposerDraft draft, Object save})>{};
  final _volatile = <String, RefusedTextDraft>{};
  final _generations = <String, int>{};
  bool _closed = false;
  int accountGeneration(String account) => _generations[account] ?? 0;

  bool isActive(String id) => _active.containsKey(id);
  bool isVolatile(String id) => _volatile.containsKey(id);

  bool begin(RefusedTextDraft draft) {
    if (isActive(draft.draftId)) return false;
    _active[draft.draftId] = draft.accountId;
    _changed();
    return true;
  }

  void end(String id) {
    _active.remove(id);
    _changed();
  }

  Iterable<RefusedTextDraft> volatileDrafts(
    String account,
    String room,
    int? thread,
  ) => _volatile.values.where(
    (d) =>
        d.accountId == account && d.roomToken == room && d.threadId == thread,
  );

  Stream<List<RefusedTextDraft>> watch(
    String account,
    String room,
    int? thread,
  ) {
    final query = _db.select(_db.refusedTextDrafts)
      ..where(
        (d) =>
            d.accountId.equals(account) &
            d.roomToken.equals(room) &
            (thread == null ? d.threadId.isNull() : d.threadId.equals(thread)),
      )
      ..orderBy([
        (d) => OrderingTerm.asc(d.createdAtMillis),
        (d) => OrderingTerm.asc(d.rowId),
      ]);
    return query.watch();
  }

  /// Migrates the matching ordinary draft and the send intent together.
  Future<void> checkpoint(
    RefusedTextDraft draft, {
    bool fromComposer = false,
  }) async {
    final key = (draft.accountId, draft.roomToken, draft.threadId);
    final previous = _composer[key];
    try {
      await _db.transaction(() async {
        await _db.into(_db.refusedTextDrafts).insert(draft);
        if (!fromComposer) return;
        // The field may have been edited since its last debounced save.
        await (_db.delete(_db.chatDrafts)..where(
              (row) =>
                  row.accountId.equals(draft.accountId) &
                  row.roomToken.equals(draft.roomToken) &
                  row.scopeKey.equals(_scopeKey(draft.threadId)) &
                  row.updatedAtMillis.isSmallerOrEqualValue(
                    draft.createdAtMillis,
                  ),
            ))
            .go();
      });
      if (fromComposer && _composer[key] == previous) _composer.remove(key);
      _volatile.remove(draft.draftId);
    } on Object {
      if (isActive(draft.draftId)) _volatile[draft.draftId] = draft;
      rethrow;
    }
  }

  Future<void> restorePlain(RefusedTextDraft draft) =>
      _db.transaction(() async {
        if (await _remove(draft) == 0) {
          throw StateError('Draft is no longer available');
        }
        await _db
            .into(_db.chatDrafts)
            .insertOnConflictUpdate(
              ChatDraftsCompanion.insert(
                accountId: draft.accountId,
                roomToken: draft.roomToken,
                scopeKey: _scopeKey(draft.threadId),
                draftText: draft.message,
                composerContext: const Value('{}'),
                updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
              ),
            );
      });

  Future<void> discard(RefusedTextDraft draft) async {
    if (!_volatile.containsKey(draft.draftId)) await _remove(draft);
    _volatile.remove(draft.draftId);
    _changed();
  }

  Future<int> _remove(RefusedTextDraft draft) =>
      (_db.delete(_db.refusedTextDrafts)..where(
            (row) =>
                row.accountId.equals(draft.accountId) &
                row.roomToken.equals(draft.roomToken) &
                row.draftId.equals(draft.draftId),
          ))
          .go();

  String _scopeKey(int? thread) => thread == null ? 'root' : 'thread:$thread';

  Future<void> saveComposer(
    ChatRepository store,
    String account,
    String room,
    int? thread,
    String text, {
    CachedChatMessage? reply,
  }) async {
    final key = (account, room, thread);
    final value = (draft: (text: text, reply: reply), save: Object());
    _composer[key] = value;
    try {
      await store.saveDraft(
        accountId: account,
        roomToken: room,
        threadId: thread,
        text: text,
        reply: reply,
      );
      if (_composer[key] == value) _composer.remove(key);
    } on Object {
      // The current edit remains available across navigation until the next write.
    }
  }

  Future<String?> readComposer(
    ChatRepository store,
    String account,
    String room,
    int? thread,
  ) async {
    return (await readComposerDraft(store, account, room, thread))?.text;
  }

  Future<ComposerDraft?> readComposerDraft(
    ChatRepository store,
    String account,
    String room,
    int? thread,
  ) async {
    final memory = _composer[(account, room, thread)];
    if (memory != null) return memory.draft;
    try {
      return await store.readComposerDraft(
        accountId: account,
        roomToken: room,
        threadId: thread,
      );
    } on Object {
      return null;
    }
  }

  void forgetAccount(String account) {
    _generations[account] = accountGeneration(account) + 1;
    _active.removeWhere((_, owner) => owner == account);
    _volatile.removeWhere((_, draft) => draft.accountId == account);
    _composer.removeWhere((key, _) => key.$1 == account);
    _changed();
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
