part of 'chat_room_pane.dart';

extension _ChatRoomPaneComposer on _ChatRoomPaneState {
  void _startReply(CachedChatMessage message) {
    if (message.systemMessage.isNotEmpty || message.deleted) {
      return;
    }
    _update(() => _replyTo = message);
  }

  Future<void> _send() async {
    final message = _composer.text.trim();
    if (message.isEmpty || _sending || widget.conversation.readOnly != 0) {
      return;
    }
    await _sendMessage(message, clearComposer: true);
  }

  Future<void> _sendGiphyForScope(
    GiphyEntry entry,
    HttpGiphyRepository repository,
    ChatRoomProviderKey targetKey,
    int giphyGeneration,
  ) async {
    if (!_isCurrentGiphyScope(targetKey, giphyGeneration)) {
      return;
    }
    if (!isSupportedGiphyResource(entry.resourceUrl)) {
      if (mounted) {
        _update(() => _localError = ChatServiceError.invalidResponse);
      }
      return;
    }
    // A GIF is sent as a reference, not as a file in the user's storage. The
    // bubble resolves that reference through the account's own server and
    // renders the animation inline.
    await _sendMessage(
      entry.resourceUrl.toString(),
      clearComposer: false,
      expectedKey: targetKey,
    );
  }

  Future<void> _sendMessage(
    String message, {
    required bool clearComposer,
    ChatRoomProviderKey? expectedKey,
  }) async {
    final targetKey = _key;
    if (expectedKey != null && expectedKey != targetKey) {
      return;
    }
    if (message.isEmpty || _sending || widget.conversation.readOnly != 0) {
      return;
    }
    final replyTo = targetKey.threadId == null ? _replyTo : null;
    final generation = ++_sendGeneration;
    _update(() => _sending = true);
    try {
      await ref
          .read(chatServiceProvider)
          .sendText(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            message: message,
            threadId: targetKey.threadId,
            replyTo: replyTo?.messageId,
          );
      if (!_isCurrentSendScope(targetKey, generation)) {
        return;
      }
      if (replyTo != null && _replyTo?.messageId == replyTo.messageId) {
        _update(() => _replyTo = null);
      }
      if (clearComposer && _composer.text.trim() == message) {
        _composer.clear();
      }
      if (_scrollController.hasClients) {
        await _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
      if (_isCurrentSendScope(targetKey, generation)) {
        _update(() => _localError = null);
      }
    } on ChatServiceException catch (error) {
      if (_isCurrentSendScope(targetKey, generation)) {
        _update(() => _localError = error.code);
      }
    } on Object {
      if (_isCurrentSendScope(targetKey, generation)) {
        _update(() => _localError = ChatServiceError.invalidResponse);
      }
    } finally {
      if (_isCurrentSendScope(targetKey, generation)) {
        _update(() => _sending = false);
      }
    }
  }

  bool _isCurrentSendScope(ChatRoomProviderKey targetKey, int generation) {
    return mounted && generation == _sendGeneration && targetKey == _key;
  }

  Future<void> _showEmojiPicker() async {
    if (_sending || widget.conversation.readOnly != 0) {
      return;
    }
    final strings = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.72,
            child: EmojiPicker(
              labels: _emojiPickerLabels(strings),
              onSelected: (choice) {
                if (!insertComposerText(_composer, choice.glyph)) {
                  _showComposerLimitError();
                  return;
                }
                Navigator.of(sheetContext).pop();
              },
            ),
          ),
        ),
      ),
    );
  }

  EmojiPickerLabels _emojiPickerLabels(AppLocalizations strings) {
    return EmojiPickerLabels(
      searchHint: strings.emojiSearchHint,
      noResults: strings.emojiNoResults,
      categoryLabels: <EmojiCategory, String>{
        EmojiCategory.smileys: strings.emojiCategorySmileys,
        EmojiCategory.people: strings.emojiCategoryPeople,
        EmojiCategory.animals: strings.emojiCategoryAnimals,
        EmojiCategory.food: strings.emojiCategoryFood,
        EmojiCategory.activities: strings.emojiCategoryActivities,
        EmojiCategory.travel: strings.emojiCategoryTravel,
        EmojiCategory.objects: strings.emojiCategoryObjects,
        EmojiCategory.symbols: strings.emojiCategorySymbols,
      },
    );
  }

  Future<void> _requestGiphy({bool refresh = false}) async {
    if (_sending || widget.conversation.readOnly != 0) {
      return;
    }
    final targetKey = _key;
    final generation = ++_giphyGeneration;
    final provider = giphyRepositoryProvider(targetKey.accountId);
    final subscription = ref.listenManual<AsyncValue<HttpGiphyRepository?>>(
      provider,
      (_, _) {},
      fireImmediately: true,
    );
    if (!_giphyRequested) {
      _update(() => _giphyRequested = true);
    }
    try {
      if (refresh) {
        ref.invalidate(provider);
      }
      final repository = await ref.read(provider.future);
      if (!_isCurrentGiphyScope(targetKey, generation) || repository == null) {
        return;
      }
      await _showGiphyPicker(repository, targetKey, generation);
    } on Object {
      // The watched provider exposes a localized retry state in the composer.
    } finally {
      subscription.close();
    }
  }

  bool _isCurrentGiphyScope(ChatRoomProviderKey targetKey, int generation) {
    return mounted && generation == _giphyGeneration && targetKey == _key;
  }

  Future<void> _showGiphyPicker(
    HttpGiphyRepository repository,
    ChatRoomProviderKey targetKey,
    int generation,
  ) async {
    if (!_isCurrentGiphyScope(targetKey, generation)) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final controller = GiphyController(repository: repository);
    unawaited(controller.loadTrending());
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (sheetContext) => Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * 0.72,
              child: GiphyPicker(
                controller: controller,
                labels: GiphyPickerLabels(
                  searchHint: strings.giphySearchHint,
                  noResults: strings.giphyNoResults,
                  retry: strings.retry,
                  loadMore: strings.giphyLoadMore,
                  poweredByGiphy: strings.giphyPoweredBy,
                ),
                thumbnailBuilder: (_, entry) => ExcludeSemantics(
                  child: _GiphyThumbnail(repository: repository, entry: entry),
                ),
                onAttributionPressed: _openGiphyAttribution,
                onSelected: (entry) {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    _sendGiphyForScope(
                      entry,
                      repository,
                      targetKey,
                      generation,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _openGiphyAttribution(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // The picker remains usable when no external browser is available.
    }
  }

  void _showComposerLimitError() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).messageTooLong)),
      );
  }

  Future<void> _confirmResend(StoredTextSendOperation operation) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('duplicate-risk-dialog'),
        title: Text(strings.duplicateRiskTitle),
        content: Text(strings.duplicateRiskBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('confirm-duplicate-risk'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.confirmResend),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await ref
          .read(chatServiceProvider)
          .resendText(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            operationId: operation.operationId,
          );
      if (mounted) {
        _update(() => _localError = null);
      }
    } on ChatServiceException catch (error) {
      if (mounted) {
        _update(() => _localError = error.code);
      }
    } on Object {
      if (mounted) {
        _update(() => _localError = ChatServiceError.invalidResponse);
      }
    }
  }

  /// Drops a pending send. The service refuses operations whose body may
  /// already have reached the server; those keep their bubble and the user is
  /// told why, because silently hiding one would hide a message that exists.
  Future<void> _cancelPending(StoredTextSendOperation operation) async {
    final strings = AppLocalizations.of(context);
    bool cancelled;
    try {
      cancelled = await ref
          .read(chatServiceProvider)
          .cancelText(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            operationId: operation.operationId,
          );
    } on Object {
      cancelled = false;
    }
    if (!mounted || cancelled) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(strings.outboxCancelAmbiguous)));
  }

  void _openThread(CachedChatMessage message) {
    if (widget.threadId != null || message.messageId < 1) {
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => ChatThreadScreen(
            account: widget.account,
            conversation: widget.conversation,
            threadId: message.messageId,
          ),
        ),
      ),
    );
  }

  Widget _buildMediaComposer(
    AsyncValue<ChatAttachmentDependencies> dependencies, {
    required List<Widget> idleActions,
  }) {
    return dependencies.when(
      loading: () => ChatMediaComposerStatus.loading(idleActions: idleActions),
      error: (_, _) => ChatMediaComposerStatus.unavailable(
        idleActions: idleActions,
        onRetry: () {
          ref.invalidate(chatAttachmentDependenciesProvider(_key));
        },
      ),
      data: (value) {
        try {
          final accountId = AccountId.parse(widget.account.id);
          final server = ServerBase.parse(widget.account.serverUrl);
          final roomToken = ConversationToken.parse(
            widget.conversation.token,
            path: r'$.roomToken',
          );
          return ChatMediaComposer(
            key: ValueKey((
              widget.account.id,
              widget.conversation.token,
              widget.threadId,
            )),
            accountId: accountId,
            controller: _mediaComposerController,
            server: server,
            roomToken: roomToken,
            threadId: widget.threadId,
            sourceStore: value.source,
            capabilityProfile: value.profile,
            submissionBridge: AttachmentSubmissionBridge.withService(
              accountId: accountId,
              server: server,
              roomToken: roomToken,
              prepare: value.resolver.resolve,
              service: value.service,
            ),
            idleActions: idleActions,
          );
        } on TalkProtocolException {
          return ChatMediaComposerStatus.unavailable(
            idleActions: idleActions,
            onRetry: () {
              ref.invalidate(chatAttachmentDependenciesProvider(_key));
            },
          );
        }
      },
    );
  }
}
