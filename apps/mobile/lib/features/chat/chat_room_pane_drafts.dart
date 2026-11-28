part of 'chat_room_pane.dart';

const _refusedDraftPrefix = 'refused-draft-';

mixin _ChatRoomDraftState {
  late final DraftHandoffStore _handoff;
  late final RecoverableTextDraftStore _composerDrafts;
  late int _draftAccountGeneration;
  ChatRepository? _draftStore;
  Timer? _draftTimer;
  bool _suppressDraftSave = false;
  CachedChatMessage? _restoredQuote;
  ({ChatRoomProviderKey key, String text, Future<bool> done})? _returningDraft;
  DraftRoom? _draftReadyKey;
  DraftRoom? _handoffRoom;
  ForegroundSyncLoop? _handoffLoop;
  String? _handoffNotice;
  DraftRoom? _reportedDraftConflict;
  Timer? _draftConflictHint;
}

extension _ChatRoomDrafts on _ChatRoomPaneState {
  ChatThreadContext? get _currentThreadContext {
    final threadContext = widget.threadContext;
    if (threadContext == null ||
        !threadContext.matches(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
          rootMessageId: widget.threadId,
        )) {
      return null;
    }
    return threadContext;
  }

  /// Composer text is only durable once the outbox admits it, and admission
  /// can be refused, so the draft is persisted on its own.
  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flushDraft(_key, _composer.text)),
    );
  }

  Future<void> _flushDraft(ChatRoomProviderKey key, String text) async {
    // Leaving before the asynchronous restore finishes must keep its disk row.
    if (_draftTimer == null && text.isEmpty) return;
    _draftTimer?.cancel();
    _draftTimer = null;
    final store = _draftStore;
    if (store == null ||
        _draftAccountGeneration !=
            _composerDrafts.accountGeneration(key.accountId)) {
      return;
    }
    if (_returningDraft?.key == key && _returningDraft?.text == text) return;
    final reply = _replyTo;
    unawaited(_publishDraft(key, text, reply?.messageId));
    await _composerDrafts.saveComposer(
      store,
      key.accountId,
      key.roomToken,
      key.threadId,
      text.trim().isEmpty ? '' : text,
      reply: reply,
    );
  }

  Future<void> _restoreDraft(ChatRoomProviderKey key) async {
    final store = _draftStore;
    if (store == null) {
      return;
    }
    final draft = await _composerDrafts.readComposerDraft(
      store,
      key.accountId,
      key.roomToken,
      key.threadId,
    );
    if (!_hasActiveElement || key != _key) return;
    if (draft != null && _replyTo == null && _composer.text.isEmpty) {
      _restoredQuote = draft.reply;
      _update(() => _replyTo = draft.reply);
      _composer.value = TextEditingValue(
        text: draft.text,
        selection: TextSelection.collapsed(offset: draft.text.length),
      );
      _focusOpenedDraft(key);
    }
    _draftReadyKey = key;
    _syncHandoffReader();
  }

  void _focusOpenedDraft(ChatRoomProviderKey key) {
    if (ref.read(composerDraftFocusProvider) != key) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _key != key ||
          ref.read(composerDraftFocusProvider) != key ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      ref.read(composerDraftFocusProvider.notifier).state = null;
      _composerFocusNode.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _returnPlainDraft(
    RefusedTextDraft draft,
    ChatRoomProviderKey key,
    int generation,
  ) async {
    if (_replyTo != null ||
        _mediaComposerController.hasPreparedAttachment ||
        _silentSend ||
        draft.silent ||
        draft.replyTo != null ||
        _composerDrafts.isVolatile(draft.draftId) ||
        _composer.text.isNotEmpty) {
      return;
    }
    final ready = Completer<bool>();
    final returning = (key: key, text: draft.message, done: ready.future);
    _returningDraft = returning;
    _composer.value = TextEditingValue(
      text: draft.message,
      selection: TextSelection.collapsed(offset: draft.message.length),
    );
    try {
      await _composerDrafts.restorePlain(draft);
      _handoff.returnToComposer(key, draft.draftId).ignore();
      ready.complete(true);
    } on Object {
      // The independent copy still owns the text if the transaction rolled back.
      if (_isCurrentTextSendScope(key, generation) &&
          _composer.text == draft.message) {
        _composer.clear();
      }
      ready.complete(false);
    } finally {
      if (identical(_returningDraft?.done, ready.future)) {
        _returningDraft = null;
      }
    }
  }

  Map<String, RefusedTextDraft> _recoverableDrafts() {
    final key = _key;
    final recovery = ref.watch(recoverableTextDraftStoreProvider);
    return {
      for (final draft in [
        ...?ref.watch(roomRefusedDraftsProvider(key)).valueOrNull,
        ...recovery.volatileDrafts(key.accountId, key.roomToken, key.threadId),
      ])
        if (!recovery.isActive(draft.draftId))
          '$_refusedDraftPrefix${draft.draftId}': draft,
    };
  }

  StoredTextSendOperation _failedDraftOperation(RefusedTextDraft draft) =>
      StoredTextSendOperation(
        accountId: draft.accountId,
        operationId: '$_refusedDraftPrefix${draft.draftId}',
        roomToken: draft.roomToken,
        threadId: draft.threadId,
        replyTo: draft.replyTo,
        referenceId: '',
        message: draft.message,
        replayContractRevision: '',
        silent: draft.silent,
        enqueueSequence: 0,
        outboxState: 'failed',
        errorClass:
            ref
                .read(recoverableTextDraftStoreProvider)
                .isVolatile(draft.draftId)
            ? 'local-draft-not-saved'
            : null,
        attemptCount: 0,
        messageIdsJson: '[]',
        duplicateRiskAcknowledged: false,
        automaticResendCount: 0,
        createdAtMillis: draft.createdAtMillis,
        updatedAtMillis: draft.createdAtMillis,
      );

  Future<void> _retryDraft(RefusedTextDraft draft) async {
    if (_isReadOnlyNow()) return;
    final recovery = ref.read(recoverableTextDraftStoreProvider);
    final service = ref.read(chatServiceProvider);
    if (!recovery.begin(draft)) return;
    final key = (
      accountId: draft.accountId,
      roomToken: draft.roomToken,
      threadId: draft.threadId,
    );
    final generation = _handoff.generation(key.accountId);
    final reserved = _handoff.reserved(key, draft.draftId)..ignore();
    try {
      if (mounted &&
          _key.accountId == draft.accountId &&
          _key.roomToken == draft.roomToken &&
          draft.replyTo != null) {
        _update(() => _replyTargets.add(draft.replyTo!));
      }
      await service.sendText(
        accountId: draft.accountId,
        roomToken: draft.roomToken,
        threadId: draft.threadId,
        replyTo: draft.replyTo,
        silent: draft.silent,
        message: draft.message,
        recoverableDraft: (
          id: draft.draftId,
          checkpoint: recovery.isVolatile(draft.draftId)
              ? recovery.checkpoint(draft)
              : null,
        ),
      );
      unawaited(_removeAdmittedDraft(key, reserved, generation));
    } on Object catch (error) {
      if (mounted &&
          _key ==
              (
                accountId: draft.accountId,
                roomToken: draft.roomToken,
                threadId: draft.threadId,
              )) {
        _update(
          () => _localError = error is ChatServiceException
              ? error.code
              : ChatServiceError.invalidResponse,
        );
      }
    } finally {
      recovery.end(draft.draftId);
    }
  }

  Future<void> _discardDraft(RefusedTextDraft draft) async {
    final recovery = ref.read(recoverableTextDraftStoreProvider);
    if (!recovery.begin(draft)) return;
    final key = (
      accountId: draft.accountId,
      roomToken: draft.roomToken,
      threadId: draft.threadId,
    );
    final generation = _handoff.generation(key.accountId);
    final reserved = _handoff.reserved(key, draft.draftId)..ignore();
    try {
      await recovery.discard(draft);
      unawaited(_removeAdmittedDraft(key, reserved, generation));
    } on Object {
      if (mounted) {
        _update(() => _localError = ChatServiceError.invalidResponse);
      }
    } finally {
      recovery.end(draft.draftId);
    }
  }
}
