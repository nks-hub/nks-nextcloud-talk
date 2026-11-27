part of 'chat_repository.dart';

/// Older clients saved the text and admitted a send in separate transactions.
/// Only a send whose parent is unambiguous can suppress such a draft. Current
/// drafts are checkpointed atomically and must never be deduplicated by text.
const _visibleDraft = CustomExpression<bool>('''
  composer_context IS NOT NULL OR NOT EXISTS (
    SELECT 1 FROM text_send_operations AS sent
    WHERE sent.account_id = chat_drafts.account_id
      AND sent.room_token = chat_drafts.room_token
      AND sent.message = chat_drafts.draft_text
      AND sent.created_at_millis >= chat_drafts.updated_at_millis
      AND ((chat_drafts.scope_key = 'root'
            AND sent.thread_id IS NULL AND sent.reply_to IS NULL)
        OR chat_drafts.scope_key = 'thread:' || sent.thread_id)
  )
''');

typedef ComposerDraft = ({String text, CachedChatMessage? reply});

extension ChatRepositoryDrafts on ChatRepository {
  Stream<List<StoredChatDraft>> watchDrafts(String accountId) =>
      (_database.select(_database.chatDrafts)
            ..where((r) => r.accountId.equals(accountId) & _visibleDraft)
            ..orderBy([
              (r) => OrderingTerm.desc(r.updatedAtMillis),
              (r) => OrderingTerm.asc(r.roomToken),
              (r) => OrderingTerm.asc(r.scopeKey),
            ]))
          .watch();

  Future<ComposerDraft?> readComposerDraft({
    required String accountId,
    required String roomToken,
    int? threadId,
  }) => _database.transaction(() async {
    final scope = _scopeKey(threadId);
    Expression<bool> matches(ChatDrafts r) =>
        r.accountId.equals(accountId) &
        r.roomToken.equals(roomToken) &
        r.scopeKey.equals(scope);
    final drafts = _database.chatDrafts;
    final row = await (_database.select(
      drafts,
    )..where(matches)).getSingleOrNull();
    if (row == null || row.draftText.isEmpty) return null;
    if (row.composerContext == null) {
      final stale = await (_database.delete(
        drafts,
      )..where((r) => matches(r) & _visibleDraft.not())).go();
      if (stale != 0) return null;
    }
    final snapshot = row.composerContext;
    final reply = snapshot == null || snapshot == '{}'
        ? null
        : CachedChatMessage.fromJson(
            jsonDecode(snapshot) as Map<String, dynamic>,
          );
    if (reply != null &&
        (reply.accountId != accountId ||
            reply.roomToken != roomToken ||
            reply.messageId <= 0)) {
      throw const FormatException('Invalid draft reply scope');
    }
    return (text: row.draftText, reply: reply);
  });

  Future<void> _writeDraft({
    required String accountId,
    required String roomToken,
    required String text,
    int? threadId,
    CachedChatMessage? reply,
  }) async {
    final scope = _scopeKey(threadId);
    if (reply != null &&
        (reply.accountId != accountId ||
            reply.roomToken != roomToken ||
            reply.messageId <= 0)) {
      throw ArgumentError('Reply belongs to another conversation');
    }
    if (text.isEmpty) {
      await (_database.delete(_database.chatDrafts)..where(
            (r) =>
                r.accountId.equals(accountId) &
                r.roomToken.equals(roomToken) &
                r.scopeKey.equals(scope),
          ))
          .go();
      return;
    }
    final context = reply == null ? '{}' : jsonEncode(reply.toJson());
    final drafts = _database.chatDrafts;
    final row = ChatDraftsCompanion.insert(
      accountId: accountId,
      roomToken: roomToken,
      scopeKey: scope,
      draftText: text,
      updatedAtMillis: _clock().millisecondsSinceEpoch,
      composerContext: Value(context),
    );
    await _database
        .into(drafts)
        .insert(
          row,
          onConflict: DoUpdate(
            (_) => row,
            where: (r) =>
                r.draftText.equals(text).not() |
                r.composerContext.isNotValue(context),
          ),
        );
  }
}
