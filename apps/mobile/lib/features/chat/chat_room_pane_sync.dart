part of 'chat_room_pane.dart';

extension _ChatRoomPaneSync on _ChatRoomPaneState {
  Future<void> _sync() => _restartLiveSync();

  void _handleConnectivityWake() {
    if (!mounted ||
        !_isForegroundLifecycleState(WidgetsBinding.instance.lifecycleState)) {
      return;
    }
    final binding = _liveBinding;
    if (binding == null) {
      return;
    }
    unawaited(_runConnectivityWake(binding, _syncGeneration));
  }

  Future<void> _runConnectivityWake(
    ChatLiveRoomBinding binding,
    int generation,
  ) async {
    try {
      await binding.wakeAfterConnectivity();
      if (_isForegroundLifecycleState(WidgetsBinding.instance.lifecycleState)) {
        _setSyncSuccess(generation);
      }
    } on ChatServiceException catch (error) {
      _setSyncError(generation, error);
    } on Object catch (error) {
      _setSyncError(generation, error);
    }
  }

  Future<void> _restartLiveSync() async {
    final generation = ++_syncGeneration;
    final previousBinding = _liveBinding;
    final previousLoop = _syncLoop;
    _liveBinding = null;
    _syncLoop = null;
    previousBinding?.close();
    await previousLoop?.stop();
    if (!mounted ||
        generation != _syncGeneration ||
        !_isForegroundLifecycleState(WidgetsBinding.instance.lifecycleState)) {
      return;
    }

    final binding = ref
        .read(chatServiceProvider)
        .bindLiveRoom(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
          threadId: widget.threadId,
        );
    var showProgress = true;
    late final ForegroundSyncLoop loop;
    loop = ForegroundSyncLoop(
      task: (cancellation) => _runLiveCycle(binding, cancellation, generation),
      successInterval: const Duration(seconds: 1),
      retryBaseDelay: const Duration(seconds: 2),
      retryMaximumDelay: const Duration(minutes: 1),
      onCycleStarted: () {
        if (showProgress) {
          _setSyncing(generation, true);
        }
      },
      onSuccess: () {
        showProgress = false;
        _setSyncSuccess(generation);
      },
      onError: (error) {
        showProgress = false;
        _setSyncError(generation, error);
      },
    );
    if (!mounted || generation != _syncGeneration) {
      binding.close();
      return;
    }
    _liveBinding = binding;
    _syncLoop = loop;
    loop.start();
  }

  Future<void> _stopLiveSync() async {
    final generation = ++_syncGeneration;
    final binding = _liveBinding;
    final loop = _syncLoop;
    _liveBinding = null;
    _syncLoop = null;
    binding?.close();
    await loop?.stop();
    if (mounted && generation == _syncGeneration && _syncing) {
      _update(() => _syncing = false);
    }
  }

  Future<void> _runLiveCycle(
    ChatLiveRoomBinding binding,
    Future<void> cancellation,
    int generation,
  ) async {
    try {
      await binding.synchronize(abortTrigger: cancellation);
    } on ChatServiceException catch (error) {
      if (_isTerminalLiveError(error.code)) {
        _setSyncError(generation, error);
        await cancellation;
        return;
      }
      rethrow;
    }
  }

  void _setSyncing(int generation, bool value) {
    if (!mounted || generation != _syncGeneration || _syncing == value) {
      return;
    }
    _update(() => _syncing = value);
  }

  void _setSyncSuccess(int generation) {
    if (!mounted || generation != _syncGeneration) {
      return;
    }
    _update(() {
      _syncing = false;
      _initialAttemptFinished = true;
      _localError = null;
    });
    _startPendingJump();
    _scheduleVisibleRootReadMarker(generation);
  }

  void _scheduleVisibleRootReadMarker(int generation) {
    if (!_canMarkVisibleRootRead(generation, _key)) {
      return;
    }
    final key = _key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_markVisibleRootRead(key, generation));
    });
  }

  Future<void> _markVisibleRootRead(
    ChatRoomProviderKey key,
    int generation,
  ) async {
    if (!_canMarkVisibleRootRead(generation, key)) {
      return;
    }
    final messages = _visibleMessages();
    if (messages.isEmpty) {
      return;
    }
    final messageId = messages.last.messageId;
    if (!_isMessageActuallyVisible(messageId) ||
        (_lastAutoReadKey == key && _lastAutoReadMessageId == messageId) ||
        (_autoReadInFlightKey == key &&
            _autoReadInFlightMessageId == messageId)) {
      return;
    }

    _autoReadInFlightKey = key;
    _autoReadInFlightMessageId = messageId;
    try {
      await ref
          .read(roomSettingsServiceProvider)
          .markConversationRead(
            accountId: key.accountId,
            roomToken: key.roomToken,
            lastReadMessage: messageId,
          );
      _lastAutoReadKey = key;
      _lastAutoReadMessageId = messageId;
    } on RoomSettingsException {
      // A later successful foreground cycle retries the same visible marker.
    } on Error catch (error, stackTrace) {
      _lastAutoReadKey = key;
      _lastAutoReadMessageId = messageId;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Nextcloud Talk chat',
          context: ErrorDescription(
            'while automatically marking a message read',
          ),
        ),
      );
    } finally {
      if (_autoReadInFlightKey == key &&
          _autoReadInFlightMessageId == messageId) {
        _autoReadInFlightKey = null;
        _autoReadInFlightMessageId = null;
      }
    }
  }

  bool _canMarkVisibleRootRead(int generation, ChatRoomProviderKey key) {
    return mounted &&
        generation == _syncGeneration &&
        key == _key &&
        widget.threadId == null &&
        widget.jumpToMessageId == null &&
        _pendingJumpMessageId == null &&
        _jumpTargetId == null &&
        _isForegroundLifecycleState(WidgetsBinding.instance.lifecycleState);
  }

  bool _isMessageActuallyVisible(int messageId) {
    final targetKey = ValueKey(
      'chat-message-${widget.account.id}-'
      '${widget.conversation.token}-$messageId',
    );
    Element? target;
    void findTarget(Element element) {
      if (target != null) {
        return;
      }
      if (element.widget.key == targetKey) {
        target = element;
        return;
      }
      element.visitChildElements(findTarget);
    }

    context.visitChildElements(findTarget);
    final renderObject = target?.renderObject;
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return false;
    }
    RenderObject? ancestor = renderObject.parent;
    while (ancestor != null) {
      if (ancestor is RenderOffstage && ancestor.offstage) {
        return false;
      }
      ancestor = ancestor.parent;
    }
    final viewport = RenderAbstractViewport.of(renderObject);
    final scrollable = Scrollable.maybeOf(target!);
    if (scrollable == null || !scrollable.position.hasContentDimensions) {
      return false;
    }
    final start = viewport.getOffsetToReveal(renderObject, 0).offset;
    final end = viewport.getOffsetToReveal(renderObject, 1).offset;
    final targetStart = math.min(start, end);
    final targetEnd = math.max(start, end);
    final visibleStart = scrollable.position.pixels;
    final visibleEnd = visibleStart + scrollable.position.viewportDimension;
    return targetEnd > visibleStart && targetStart < visibleEnd;
  }

  void _setSyncError(int generation, Object error) {
    if (!mounted || generation != _syncGeneration) {
      return;
    }
    final code = error is ChatServiceException
        ? error.code
        : ChatServiceError.invalidResponse;
    _update(() {
      _syncing = false;
      _initialAttemptFinished = true;
      _localError = code;
    });
    // A failed first attempt still resolves the jump: paging back over a
    // cached scope may work, and when it does not the user is told so
    // instead of being left on the newest message without explanation.
    _startPendingJump();
  }

  /// Returns whether the page was fetched. A refused or failed fetch is
  /// already surfaced through [_localError]; the boolean only lets a caller
  /// stop paging instead of retrying the same failure.
  Future<bool> _loadOlder() async {
    if (_loadingOlder) {
      return false;
    }
    final scope = ref.read(chatScopeProvider(_key)).valueOrNull;
    if (scope?.hasHistory != true) {
      return false;
    }
    _update(() => _loadingOlder = true);
    try {
      await ref
          .read(chatServiceProvider)
          .loadOlder(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            threadId: widget.threadId,
          );
      if (mounted) {
        _update(() => _localError = null);
      }
      return true;
    } on ChatServiceException catch (error) {
      if (mounted) {
        _update(() => _localError = error.code);
      }
      return false;
    } on Object {
      if (mounted) {
        _update(() => _localError = ChatServiceError.invalidResponse);
      }
      return false;
    } finally {
      if (mounted) {
        _update(() => _loadingOlder = false);
      }
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _loadingOlder) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 160) {
      unawaited(_loadOlder());
    }
  }

  void _startPendingJump() {
    final target = _pendingJumpMessageId;
    if (target == null) {
      return;
    }
    _pendingJumpMessageId = null;
    unawaited(_jumpToMessage(target));
  }

  /// Reveals [messageId] inside this scope, fetching older history pages
  /// while the message is not covered by the scope's confirmed blocks.
  ///
  /// Both entry points - a search result and a tapped quote - land here, so
  /// the fetch, the scroll and the highlight exist exactly once. Paging back
  /// is the only way to reach an uncached message: `planChatGetMerge` only
  /// extends a scope at its two cursor ends, so an ad-hoc fetch anchored on
  /// an arbitrary id would be discarded as stale rather than merged.
  Future<void> _jumpToMessage(int messageId) async {
    final generation = ++_jumpGeneration;
    final key = _key;
    final chat = ref.read(chatRepositoryProvider);
    for (var page = 0; page <= _ChatRoomPaneState._maximumJumpPages; page++) {
      final scope = await chat.getScope(
        accountId: key.accountId,
        roomToken: key.roomToken,
        threadId: key.threadId,
      );
      if (!_isCurrentJump(key, generation)) {
        return;
      }
      final cachedProbe = await _revealCoveredMessage(
        scope,
        messageId,
        key,
        generation,
      );
      if (cachedProbe != null) {
        if (cachedProbe) {
          return;
        }
        break;
      }
      if (scope?.hasHistory != true || !await _loadOlder()) {
        break;
      }
      final loadedScope = await chat.getScope(
        accountId: key.accountId,
        roomToken: key.roomToken,
        threadId: key.threadId,
      );
      if (!_isCurrentJump(key, generation)) {
        return;
      }
      final loadedProbe = await _revealCoveredMessage(
        loadedScope,
        messageId,
        key,
        generation,
      );
      if (loadedProbe != null) {
        if (loadedProbe) {
          return;
        }
        break;
      }
    }
    if (mounted && _isCurrentJump(key, generation)) {
      _reportJumpFailed();
    }
  }

  /// Returns `null` while the target is still outside fetched blocks, `true`
  /// after revealing it, and `false` when a confirmed block contains no
  /// visible row. The last case is terminal: another history page cannot
  /// restore a hidden, expired or deleted message inside an existing block.
  Future<bool?> _revealCoveredMessage(
    StoredChatScope? scope,
    int messageId,
    ChatRoomProviderKey key,
    int generation,
  ) async {
    final blocks = _decodeScopeBlocks(scope);
    if (blocks == null || _blockIndexOf(blocks, messageId) == -1) {
      return null;
    }
    return _revealMessage(messageId, key, generation);
  }

  /// Scrolls the target into view and highlights it. Returns `false` only
  /// when the message never materialized, which is the caller's cue to tell
  /// the user rather than to leave the timeline where it was.
  Future<bool> _revealMessage(
    int messageId,
    ChatRoomProviderKey key,
    int generation,
  ) async {
    if (_jumpTargetId != messageId) {
      _update(() => _jumpTargetId = messageId);
    }
    for (var pass = 0; pass < _ChatRoomPaneState._maximumRevealPasses; pass++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_isCurrentJump(key, generation)) {
        // A newer jump or a scope change owns the outcome now.
        return true;
      }
      final targetContext = _jumpTargetKey.currentContext;
      if (targetContext != null && targetContext.mounted) {
        await Scrollable.ensureVisible(
          targetContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        if (_isCurrentJump(key, generation)) {
          _highlight(messageId);
        }
        return true;
      }
      _scrollTowards(messageId);
    }
    return false;
  }

  /// Moves the reversed timeline to where [messageId] is estimated to sit so
  /// the list builds the children around it; the next pass then measures the
  /// real position. Off-screen children have no extent yet, so the estimate
  /// improves with every pass instead of landing in one step.
  void _scrollTowards(int messageId) {
    if (!_scrollController.hasClients) {
      return;
    }
    final messages = _visibleMessages();
    final index = messages.indexWhere(
      (message) => message.messageId == messageId,
    );
    if (index < 0 || messages.length < 2) {
      return;
    }
    final position = _scrollController.position;
    // The timeline is reversed: the newest message sits at offset zero and
    // the oldest at the far end.
    final fraction = (messages.length - 1 - index) / (messages.length - 1);
    final offset = position.maxScrollExtent * fraction;
    _scrollController.jumpTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  /// The same rows the timeline renders, filtered by the scope's blocks so
  /// an index here matches an index there.
  List<CachedChatMessage> _visibleMessages() {
    final key = _key;
    return _messagesWithinBlocks(
      ref.read(chatMessagesProvider(key)).valueOrNull ??
          const <CachedChatMessage>[],
      _decodeScopeBlocks(ref.read(chatScopeProvider(key)).valueOrNull),
    );
  }

  void _highlight(int messageId) {
    _highlightTimer?.cancel();
    _update(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(_ChatRoomPaneState._highlightDuration, () {
      if (mounted) {
        _update(() => _highlightedMessageId = null);
      }
    });
  }

  void _reportJumpFailed() {
    _update(() => _jumpTargetId = null);
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('chat-jump-not-found'),
          content: Text(strings.jumpToMessageNotFound),
        ),
      );
  }

  /// Watches the freshest cached row for this room, falling back to the
  /// snapshot the pane was constructed with until Drift emits its first row.
  CachedConversation _watchLiveConversation() {
    return _resolveLiveConversation(
      ref.watch(conversationsProvider(widget.account.id)).valueOrNull,
    );
  }

  /// Reads the same row for event-time admission checks. A sheet or menu can
  /// remain open while another client makes the room read-only, so callbacks
  /// must not rely on the writable state captured by the previous build.
  CachedConversation _readLiveConversation() {
    return _resolveLiveConversation(
      ref.read(conversationsProvider(widget.account.id)).valueOrNull,
    );
  }

  CachedConversation _resolveLiveConversation(
    List<CachedConversation>? conversations,
  ) {
    if (conversations == null) {
      return widget.conversation;
    }
    for (final conversation in conversations) {
      if (conversation.token == widget.conversation.token) {
        return conversation;
      }
    }
    return widget.conversation;
  }

  bool _isReadOnlyNow() => _readLiveConversation().readOnly != 0;

  bool _isCurrentJump(ChatRoomProviderKey key, int generation) =>
      mounted && generation == _jumpGeneration && key == _key;

  bool _isForegroundLifecycleState(AppLifecycleState? state) {
    return state == null || state == AppLifecycleState.resumed;
  }

  bool _isTerminalLiveError(ChatServiceError error) {
    return switch (error) {
      ChatServiceError.accountMissing ||
      ChatServiceError.conversationMissing ||
      ChatServiceError.credentialMissing ||
      ChatServiceError.talkUnavailable ||
      ChatServiceError.chatUnsupported ||
      ChatServiceError.sendUnsupported ||
      ChatServiceError.readOnly ||
      ChatServiceError.reauthenticationRequired ||
      ChatServiceError.invalidResponse => true,
      ChatServiceError.rateLimited ||
      ChatServiceError.serviceUnavailable ||
      ChatServiceError.network => false,
    };
  }
}
