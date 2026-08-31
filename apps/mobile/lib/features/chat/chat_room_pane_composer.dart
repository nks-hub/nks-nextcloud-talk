part of 'chat_room_pane.dart';

extension _ChatRoomPaneComposer on _ChatRoomPaneState {
  Future<void> _shareCurrentLocation() async {
    if (_sending || _isReadOnlyNow()) {
      return;
    }
    final targetKey = _key;
    final threadId = _currentThreadContext?.networkThreadId;
    if (targetKey.threadId != null && threadId == null) {
      return;
    }
    final generation = ++_sendGeneration;
    final strings = AppLocalizations.of(context);
    _update(() => _sending = true);
    try {
      final position = await ref.read(currentLocationSourceProvider).current();
      if (!mounted || !_isCurrentSendScope(targetKey, generation)) {
        return;
      }
      final latitude = position.latitude.toStringAsFixed(6);
      final longitude = position.longitude.toStringAsFixed(6);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('location-share-confirmation'),
          title: Text(strings.locationConfirmTitle),
          content: Text(strings.locationCoordinates(latitude, longitude)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const Key('location-share-submit'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.shareLocation),
            ),
          ],
        ),
      );
      if (confirmed != true || !_isCurrentSendScope(targetKey, generation)) {
        return;
      }
      await ref
          .read(locationShareServiceProvider)
          .share(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            position: position,
            name: strings.sharedLocationDefaultName,
            threadId: threadId,
          );
      if (!_isCurrentSendScope(targetKey, generation)) {
        return;
      }
      await _sync();
      if (_isCurrentSendScope(targetKey, generation)) {
        _showLocationSnackBar(strings.locationShared);
      }
    } on CurrentLocationException catch (error) {
      if (_isCurrentSendScope(targetKey, generation)) {
        final message = switch (error.code) {
          CurrentLocationError.servicesDisabled =>
            strings.locationServicesDisabled,
          CurrentLocationError.permissionDenied =>
            strings.locationPermissionDenied,
          CurrentLocationError.permissionDeniedForever =>
            strings.locationPermissionDeniedForever,
          CurrentLocationError.unavailable => strings.locationUnavailable,
        };
        _showLocationSnackBar(
          message,
          action: error.code == CurrentLocationError.permissionDeniedForever
              ? SnackBarAction(
                  label: strings.openAppSettings,
                  onPressed: () => unawaited(
                    _openLocationAppSettings(targetKey, generation),
                  ),
                )
              : null,
        );
      }
    } on LocationShareException catch (error) {
      if (_isCurrentSendScope(targetKey, generation)) {
        _showLocationSnackBar(
          error.code == LocationShareError.ambiguous
              ? strings.locationShareAmbiguous
              : strings.locationShareFailed,
        );
      }
    } on Object {
      if (_isCurrentSendScope(targetKey, generation)) {
        _showLocationSnackBar(strings.locationShareFailed);
      }
    } finally {
      if (_isCurrentSendScope(targetKey, generation)) {
        _update(() => _sending = false);
      }
    }
  }

  Future<void> _openLocationAppSettings(
    ChatRoomProviderKey targetKey,
    int generation,
  ) async {
    if (!_isCurrentSendScope(targetKey, generation)) {
      return;
    }
    final failureMessage = AppLocalizations.of(context).openAppSettingsFailed;
    try {
      final opened = await ref.read(appSettingsOpenerProvider).open();
      if (!opened && _isCurrentSendScope(targetKey, generation)) {
        _showLocationSnackBar(failureMessage);
      }
    } on Object {
      if (_isCurrentSendScope(targetKey, generation)) {
        _showLocationSnackBar(failureMessage);
      }
    }
  }

  void _showLocationSnackBar(String message, {SnackBarAction? action}) {
    if (Scaffold.maybeOf(context) == null) {
      return;
    }
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _openSendOptions({
    required bool canSendSilently,
    required bool canSchedule,
  }) {
    if (!canSendSilently && !canSchedule) {
      return Future<void>.value();
    }
    final strings = AppLocalizations.of(context);
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          key: const Key('send-options-sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canSendSilently)
              ListTile(
                key: const Key('toggle-silent-send'),
                leading: Icon(
                  _silentSend
                      ? Icons.notifications_off
                      : Icons.notifications_outlined,
                ),
                title: Text(
                  _silentSend ? strings.silentSendOn : strings.silentSendOff,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  if (mounted) {
                    _update(() => _silentSend = !_silentSend);
                  }
                },
              ),
            if (canSchedule)
              ListTile(
                key: const Key('schedule-message'),
                leading: const Icon(Icons.schedule_send_outlined),
                title: Text(strings.scheduleMessage),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_scheduleMessage());
                },
              ),
          ],
        ),
      ),
    );
  }

  void _startReply(CachedChatMessage message) {
    if (_isReadOnlyNow() ||
        message.systemMessage.isNotEmpty ||
        message.deleted) {
      return;
    }
    _update(() => _replyTo = message);
  }

  Future<void> _send() async {
    final message = _composer.text.trim();
    if (message.isEmpty || _sending || _isReadOnlyNow()) {
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
    if (message.isEmpty || _sending || _isReadOnlyNow()) {
      return;
    }
    final threadContext = _currentThreadContext;
    if (targetKey.threadId != null && threadContext == null) {
      _update(() => _localError = ChatServiceError.invalidResponse);
      return;
    }
    final rootReply = targetKey.threadId == null ? _replyTo : null;
    final generation = ++_sendGeneration;
    // Emptied before the request, not after it. Clearing on the way back
    // compared the whole field against the sent text, so typing the next line
    // while the send was in flight left the sent one sitting in the composer.
    // At this instant the field holds exactly what is being sent, so nothing
    // the user has typed since can be thrown away.
    final String? sentDraft = clearComposer ? _composer.text : null;
    if (clearComposer) {
      _composer.clear();
    }
    _update(() => _sending = true);
    try {
      await ref
          .read(chatServiceProvider)
          .sendText(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            message: message,
            silent: _silentSend,
            threadId: targetKey.threadId,
            replyTo: rootReply?.messageId,
          );
      if (!_isCurrentSendScope(targetKey, generation)) {
        return;
      }
      if (rootReply != null && _replyTo?.messageId == rootReply.messageId) {
        _update(() => _replyTo = null);
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
      _restoreSentDraft(sentDraft);
      if (_isCurrentSendScope(targetKey, generation)) {
        _update(() => _localError = error.code);
      }
    } on Object {
      _restoreSentDraft(sentDraft);
      if (_isCurrentSendScope(targetKey, generation)) {
        _update(() => _localError = ChatServiceError.invalidResponse);
      }
    } finally {
      if (_isCurrentSendScope(targetKey, generation)) {
        _update(() => _sending = false);
      }
    }
  }

  /// Puts a refused message back so it is not lost with the failure notice.
  ///
  /// Only into a field the user has left alone: once they have started the
  /// next line, restoring would overwrite what they are writing, and the
  /// failure is already reported above the composer.
  void _restoreSentDraft(String? draft) {
    if (draft == null || draft.isEmpty || _composer.text.isNotEmpty) {
      return;
    }
    _composer.text = draft;
    _composer.selection = TextSelection.collapsed(offset: draft.length);
  }

  bool _isCurrentSendScope(ChatRoomProviderKey targetKey, int generation) {
    return mounted && generation == _sendGeneration && targetKey == _key;
  }

  /// Opens the emoji panel above the compose row, or closes it again.
  ///
  /// It used to be a modal bottom sheet, which covered most of the screen
  /// including the line being typed into. The panel takes the space the
  /// keyboard would use instead, so the composer and the last messages stay
  /// visible while picking.
  void _toggleEmojiPicker() {
    if (_sending || _isReadOnlyNow()) {
      return;
    }
    if (_emojiPickerPending) {
      _emojiPickerPending = false;
      return;
    }
    if (!_emojiPickerOpen) {
      // The soft keyboard and the panel want the same space; the panel wins
      // while it is open, exactly as the keyboard does while it is up. A
      // hardware-keyboard desktop has no such conflict, so the caret stays
      // put and picking does not interrupt typing.
      if (!context.sendsOnEnter) {
        FocusManager.instance.primaryFocus?.unfocus();
        if (View.of(context).viewInsets.bottom > 0) {
          _emojiPickerPending = true;
          return;
        }
      }
    } else if (context.sendsOnEnter) {
      _composerFocusNode.requestFocus();
    }
    _update(() => _emojiPickerOpen = !_emojiPickerOpen);
  }

  void _closeEmojiPicker() {
    _emojiPickerPending = false;
    if (_emojiPickerOpen) {
      if (context.sendsOnEnter) {
        _composerFocusNode.requestFocus();
      }
      _update(() => _emojiPickerOpen = false);
    }
  }

  void _insertEmoji(EmojiChoice choice) {
    if (!mounted || _isReadOnlyNow()) {
      _closeEmojiPicker();
      return;
    }
    // Picking keeps the panel open: people reach for several in a row, and
    // closing after each one made every extra emoji cost a reopen.
    if (!insertComposerText(_composer, choice.glyph)) {
      _showComposerLimitError();
    }
  }

  EmojiPickerLabels _emojiPickerLabels(AppLocalizations strings) {
    return EmojiPickerLabels(
      title: strings.emojiPickerTitle,
      closeTooltip: strings.emojiPickerCloseTooltip,
      manageFavorites: strings.emojiManageFavorites,
      finishManagingFavorites: strings.emojiFinishManagingFavorites,
      favoriteModeHint: strings.emojiFavoriteModeHint,
      addFavoriteLabel: strings.emojiAddFavoriteLabel,
      removeFavoriteLabel: strings.emojiRemoveFavoriteLabel,
      searchHint: strings.emojiSearchHint,
      noResults: strings.emojiNoResults,
      noRecents: strings.emojiNoRecents,
      noFavorites: strings.emojiNoFavorites,
      categoryLabels: <EmojiCategory, String>{
        EmojiCategory.favorites: strings.emojiCategoryFavorites,
        EmojiCategory.recent: strings.emojiCategoryRecent,
        EmojiCategory.smileys: strings.emojiCategorySmileys,
        EmojiCategory.people: strings.emojiCategoryPeople,
        EmojiCategory.animals: strings.emojiCategoryAnimals,
        EmojiCategory.food: strings.emojiCategoryFood,
        EmojiCategory.activities: strings.emojiCategoryActivities,
        EmojiCategory.travel: strings.emojiCategoryTravel,
        EmojiCategory.objects: strings.emojiCategoryObjects,
        EmojiCategory.symbols: strings.emojiCategorySymbols,
        EmojiCategory.flags: strings.emojiCategoryFlags,
      },
    );
  }

  Future<void> _requestGiphy({bool refresh = false}) async {
    if (_sending || _isReadOnlyNow()) {
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

  void _handleMediaReplyDurablyAccepted(int messageId) {
    if (!mounted || widget.threadId != null) {
      return;
    }
    final current = _replyTo;
    if (current == null ||
        current.messageId != messageId ||
        current.accountId != widget.account.id ||
        current.roomToken != widget.conversation.token ||
        (current.threadId != null && current.threadId != current.messageId)) {
      return;
    }
    _update(() {
      final latest = _replyTo;
      if (latest?.messageId == messageId &&
          latest?.accountId == widget.account.id &&
          latest?.roomToken == widget.conversation.token) {
        _replyTo = null;
      }
    });
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
    final threadContext = ChatThreadContext.fromCachedRoot(
      accountId: widget.account.id,
      roomToken: widget.conversation.token,
      root: message,
    );
    if (threadContext == null) {
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/chat/thread'),
          builder: (context) => ChatThreadScreen(
            account: widget.account,
            conversation: widget.conversation,
            threadContext: threadContext,
          ),
        ),
      ),
    );
  }

  /// Empties the message field once its text has left as a caption.
  void _clearConsumedCaption() {
    if (!mounted) {
      return;
    }
    _composer.clear();
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
          final threadContext = _currentThreadContext;
          final threadBinding = threadContext?.mediaBinding(
            accountId: accountId,
            roomToken: roomToken,
          );
          final cachedReplyTo = widget.threadId == null ? _replyTo : null;
          final replyTarget = cachedReplyTo == null
              ? null
              : ChatMediaReplyTarget(
                  accountId: AccountId.parse(cachedReplyTo.accountId),
                  roomToken: ConversationToken.parse(
                    cachedReplyTo.roomToken,
                    path: r'$.replyTo.roomToken',
                  ),
                  messageId: cachedReplyTo.messageId,
                  messageThreadId: cachedReplyTo.threadId,
                  deleted: cachedReplyTo.deleted,
                  systemMessage: cachedReplyTo.systemMessage.isNotEmpty,
                );
          return ChatMediaComposer(
            key: ValueKey((
              widget.account.id,
              widget.conversation.token,
              widget.threadId,
              threadContext?.kind,
            )),
            accountId: accountId,
            controller: _mediaComposerController,
            server: server,
            roomToken: roomToken,
            threadId: widget.threadId,
            threadBinding: threadBinding,
            replyTarget: replyTarget,
            onReplyDurablyAccepted: _handleMediaReplyDurablyAccepted,
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
            showAttachmentButton: false,
            silent: _silentSend,
            captionSource: () => _composer.text,
            onCaptionConsumed: _clearConsumedCaption,
            openAppSettings: () => ref.read(appSettingsOpenerProvider).open(),
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
