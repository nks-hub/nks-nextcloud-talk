part of 'chat_room_pane.dart';

extension _ChatRoomPaneSync on _ChatRoomPaneState {
  Future<void> _sync() => _restartLiveSync();

  bool _readerIsActive() =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.isCurrentOf(context) != false &&
      ref.read(windowActiveProvider);

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
    // The binding has started its catch-up by now; a loop sitting out a
    // backoff of up to a minute joins it instead of staying deaf.
    _syncLoop?.wake();
  }

  Future<void> _runConnectivityWake(
    ChatLiveRoomBinding binding,
    int generation,
  ) async {
    try {
      await binding.wakeAfterConnectivity();
      _rebuildSignalingAfterConnectivity();
      await _observeAuthoritativeIncomingMessages(generation);
      if (_isForegroundLifecycleState(WidgetsBinding.instance.lifecycleState)) {
        _setSyncSuccess(generation);
      }
    } on ChatServiceException catch (error) {
      _setSyncError(generation, error);
    } on Object catch (error) {
      _setSyncError(generation, error);
    }
  }

  /// Gives the room's signalling a second chance when the network returns.
  ///
  /// The chat's own binding is woken above, which is why messages come back.
  /// The signalling lease is a future that already resolved, and nothing
  /// replaced it, so everything under it kept the dead one: MEASURED on a
  /// handset, a call refused while offline went on being refused for minutes
  /// after the network returned, with the server reporting no call at all.
  ///
  /// NOT while a call holds the room. That same lease is the live call's own
  /// lane, and replacing it would end the call on a blip. Both halves were run
  /// on the handset: with no call the refusal cleared within forty seconds,
  /// and with a call joined the network was taken away and given back and the
  /// call was still there - the server still listing the participant with a
  /// fresh ping.
  void _rebuildSignalingAfterConnectivity() {
    if (!mounted) {
      return;
    }
    final room = (
      accountId: widget.account.id,
      roomToken: widget.conversation.token,
    );
    if (ref.read(callHeldRoomsProvider).contains(room)) {
      return;
    }
    ref.invalidate(chatRoomSignalingProvider(room));
  }

  /// [roomChanged] binds the new room without waiting for the previous
  /// room's round to wind down; the generation already keeps that round from
  /// touching this pane. The same room is still restarted in order.
  Future<void> _restartLiveSync({bool roomChanged = false}) async {
    final generation = ++_syncGeneration;
    final previousBinding = _liveBinding;
    final previousLoop = _syncLoop;
    _liveBinding = null;
    _syncLoop = null;
    previousBinding?.close();
    if (roomChanged) {
      unawaited(previousLoop?.stop());
    } else {
      await previousLoop?.stop();
    }
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
          readerActive: _readerIsActive(),
        );
    var showProgress = true;
    late final ForegroundSyncLoop loop;
    loop = ForegroundSyncLoop(
      task: (cancellation) async {
        await _runLiveCycle(binding, cancellation, generation);
        // A round that delivered something is followed by the next one at
        // once; the pause only paces rounds that changed nothing.
        if (binding.lastRoundAdvanced) {
          loop.wake();
        }
      },
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
      await binding.synchronize();
      await _observeAuthoritativeIncomingMessages(generation);
    } on ChatServiceException catch (error) {
      if (_isTerminalLiveError(error.code)) {
        _setSyncError(generation, error);
        await cancellation;
        return;
      }
      rethrow;
    }
  }

  Future<void> _observeAuthoritativeIncomingMessages(int generation) async {
    final key = _key;
    if (!mounted || !_canAnnounceIncomingMessage(generation, key)) {
      return;
    }
    if (!WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .accessibleNavigation) {
      // Nothing would be spoken, so the room is not read on every round. The
      // baseline is dropped so a screen reader switched on later starts from
      // the messages of that moment.
      _incomingAnnouncements.reset();
      return;
    }
    final repository = ref.read(chatRepositoryProvider);
    final messages = await repository.listMessages(
      accountId: key.accountId,
      roomToken: key.roomToken,
      threadId: key.threadId,
    );
    final threadContext = _currentThreadContext;
    final networkThreadId = threadContext == null
        ? key.threadId
        : threadContext.networkThreadId;
    final scope = await repository.getNetworkScope(
      accountId: key.accountId,
      roomToken: key.roomToken,
      threadId: networkThreadId,
    );
    if (!mounted || !_canAnnounceIncomingMessage(generation, key)) {
      return;
    }
    final strings = AppLocalizations.of(context);
    _incomingAnnouncements.observeAuthoritativeMerge(
      messages: messages.map(
        (message) => (
          messageId: message.messageId,
          actorId: message.actorId,
          actorDisplayName: message.actorDisplayName,
          systemMessage: message.systemMessage,
          messageType: message.messageType,
          displayText: message.displayText,
          deleted: message.deleted,
        ),
      ),
      authoritativeMessageId: int.tryParse(scope?.futureCursor ?? ''),
      localLoginName: widget.account.loginName,
      activityLabel: strings.lastMessageUnavailable,
      textDirection: Directionality.of(context),
      canAnnounce: () =>
          _canAnnounceIncomingMessage(generation, key) &&
          WidgetsBinding
              .instance
              .platformDispatcher
              .accessibilityFeatures
              .accessibleNavigation,
    );
  }

  bool _canAnnounceIncomingMessage(int generation, ChatRoomProviderKey key) =>
      mounted &&
      generation == _syncGeneration &&
      key == _key &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.isCurrentOf(context) != false &&
      _isForegroundLifecycleState(WidgetsBinding.instance.lifecycleState);

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
    // Every long-poll round ends here, and most of them change nothing.
    if (_syncing || !_initialAttemptFinished || _localError != null) {
      _update(() {
        _syncing = false;
        _initialAttemptFinished = true;
        _localError = null;
      });
    }
    _startPendingJump();
    _scheduleVisibleReadMarker(generation);
  }

  void _scheduleVisibleReadMarker(int generation) {
    if (!_canMarkVisibleRead(generation, _key)) {
      return;
    }
    final key = _key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_markVisibleRead(key, generation));
    });
    // A round that rebuilt nothing has no frame coming for the callback.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _markVisibleRead(ChatRoomProviderKey key, int generation) async {
    if (!_canMarkVisibleRead(generation, key)) {
      return;
    }
    final messages = _visibleMessages();
    final threadId = widget.threadId;
    final readableMessages = threadId == null
        ? messages
        : messages
              .where((message) => message.messageId != threadId)
              .toList(growable: false);
    if (readableMessages.isEmpty) {
      return;
    }
    final messageId = readableMessages.last.messageId;
    // A prior successful mark-read for this exact message id does not mean
    // the room is still read: a conversation-list resync can land afterward
    // and overwrite the cached row's `unreadMessages` with a value the
    // server had not yet caught up on, with no newer message to reset this
    // tracking. Re-checking the live cached row (not just the one-shot
    // flags) lets that case retry instead of leaving the badge stuck. An
    // unrecoverable `Error` is the one case that still never retries the
    // same message id, to avoid spamming reports for a broken row.
    final sameMessageAsLastAttempt =
        _lastAutoReadKey == key && _lastAutoReadMessageId == messageId;
    final alreadyHandled =
        sameMessageAsLastAttempt &&
        (_lastAutoReadUnrecoverable ||
            _readLiveConversation().unreadMessages <= 0);
    if (!_isMessageActuallyVisible(messageId) ||
        alreadyHandled ||
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
      _lastAutoReadUnrecoverable = false;
    } on RoomSettingsException {
      // A later successful foreground cycle retries the same visible marker.
    } on Error catch (error, stackTrace) {
      _lastAutoReadKey = key;
      _lastAutoReadMessageId = messageId;
      _lastAutoReadUnrecoverable = true;
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

  bool _canMarkVisibleRead(int generation, ChatRoomProviderKey key) {
    return mounted &&
        generation == _syncGeneration &&
        key == _key &&
        widget.jumpToMessageId == null &&
        _pendingJumpMessageId == null &&
        _jumpTargetId == null &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false &&
        ref.read(windowActiveProvider) &&
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
    // Compared as rectangles rather than as scroll offsets. The timeline is a
    // CustomScrollView with a `center` key, so its scroll range starts below
    // zero and `getOffsetToReveal` no longer lines up with `position.pixels`
    // the way it does in a plain list. Where the box actually paints is the
    // same question asked without that arithmetic.
    final RenderObject viewport = RenderAbstractViewport.of(renderObject);
    if (viewport is! RenderBox) {
      return false;
    }
    final RenderBox viewportBox = viewport;
    if (!viewportBox.hasSize) {
      return false;
    }
    final topLeft = renderObject.localToGlobal(
      Offset.zero,
      ancestor: viewportBox,
    );
    return (topLeft & renderObject.size).overlaps(
      Offset.zero & viewportBox.size,
    );
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
  ///
  /// Cached history the message window has not reached yet is shown first;
  /// [fetchOnly] skips that for a jump, which widens the window to its target
  /// itself and needs the page from the server.
  Future<bool> _loadOlder({bool fetchOnly = false}) async {
    if (_loadingOlder) {
      return false;
    }
    if (!fetchOnly && _widenMessageWindow()) {
      return true;
    }
    final scope = ref.read(chatScopeProvider(_key)).valueOrNull;
    if (scope?.hasHistory != true) {
      return false;
    }
    final targetKey = _key;
    final generation = ++_historyGeneration;
    bool isCurrent() =>
        mounted && generation == _historyGeneration && targetKey == _key;
    _update(() => _loadingOlder = true);
    try {
      await ref
          .read(chatServiceProvider)
          .loadOlder(
            readerIsActive: () => isCurrent() && _readerIsActive(),
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            threadId: targetKey.threadId,
          );
      if (!isCurrent()) return false;
      _update(() => _localError = null);
      return true;
    } on ChatServiceException catch (error) {
      if (isCurrent()) {
        _update(() => _localError = error.code);
      }
      return false;
    } on Object {
      if (isCurrent()) {
        _update(() => _localError = ChatServiceError.invalidResponse);
      }
      return false;
    } finally {
      if (isCurrent()) {
        _update(() => _loadingOlder = false);
      }
    }
  }

  /// Shows the next step of cached history. False when the window already
  /// holds everything cached, so only the server has more.
  bool _widenMessageWindow() {
    final key = _key;
    if (key.threadId != null) {
      return false;
    }
    final window = ref.read(chatMessageWindowProvider(key).notifier);
    final shown = ref.read(chatMessagesProvider(key)).valueOrNull?.length ?? 0;
    if (shown < window.state) {
      return false;
    }
    window.state += chatMessageWindowStep;
    return true;
  }

  /// Makes the message window reach back to [messageId], and waits for the
  /// rows, so a jump finds a target that is cached but older than the window.
  Future<void> _widenMessageWindowTo(
    int messageId,
    ChatRoomProviderKey key,
  ) async {
    if (key.threadId != null) {
      return;
    }
    final needed = await ref
        .read(chatRepositoryProvider)
        .countMessagesFrom(
          accountId: key.accountId,
          roomToken: key.roomToken,
          messageId: messageId,
          includeThreadReplies:
              ref.read(replyLayoutProvider) == ReplyLayout.inline,
        );
    if (!mounted || key != _key) {
      return;
    }
    final window = ref.read(chatMessageWindowProvider(key).notifier);
    if (needed <= window.state) {
      return;
    }
    // Some rows past the target, so it is not revealed at the very edge.
    window.state = needed + chatMessageWindowStep ~/ 2;
    try {
      await ref.read(chatMessagesProvider(key).future);
    } on Object {
      // The reveal below reports a target that never shows up.
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final awayFromNewest =
        position.pixels - _newestOffset(position) >
        _ChatRoomPaneState._jumpToNewestThreshold;
    if (awayFromNewest != _awayFromNewest) {
      _scrollController.keepPositionAcrossAnchorChange();
      _update(() {
        _awayFromNewest = awayFromNewest;
        // Freezing the anchor on the way up is what lets arriving messages be
        // laid out below the reader instead of pushing them along. Releasing
        // it at the bottom puts the view back to following the newest message.
        _anchorMessageId = awayFromNewest ? _newestCachedMessageId() : null;
      });
    }
    if (_loadingOlder || _jumpInProgress) {
      return;
    }
    if (position.pixels >= position.maxScrollExtent - 160) {
      unawaited(_loadOlder());
    }
  }

  /// Where the newest row sits. The timeline is reversed, so that is offset
  /// zero until the reader scrolls away; anchoring then moves everything newer
  /// than the anchor - sending attachments included - below zero.
  double _newestOffset(ScrollPosition position) =>
      _anchorMessageId == null ? 0 : position.minScrollExtent;

  /// Returns the reader to the newest message.
  ///
  /// Paging back through history is the only way to reach an old message and
  /// there was no way back short of scrolling the same distance again.
  Future<void> _jumpToNewest() async {
    if (!_scrollController.hasClients) {
      return;
    }
    // The anchor is the message that was newest when the reader left. What
    // arrived since lies below it and is only measured once it is on screen,
    // so from here the jump would stop at the anchor and leave the newer
    // messages under the fold. Without the anchor the newest edge is zero.
    if (_anchorMessageId != null) {
      _scrollController.keepPositionAcrossAnchorChange();
      _update(() => _anchorMessageId = null);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
    }
    // A long history makes an animated scroll take an unbounded time, so the
    // far part is cut in one step and only the last screen is animated.
    final position = _scrollController.position;
    final newest = _newestOffset(position);
    final nearby = newest + _ChatRoomPaneState._jumpToNewestAnimatedExtent;
    if (position.pixels > nearby) {
      _scrollController.jumpTo(nearby);
    }
    await _scrollController.animateTo(
      newest,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
    // Arriving releases the anchor, which moves the newest edge again, and
    // rows measured only now move it once more. A view left a few pixels
    // short shows no jump control and no longer follows new messages.
    // Done once the view has sat on the edge for a few frames in a row; a
    // slow first layout keeps moving it for longer than one frame.
    var steadyFrames = 0;
    for (var pass = 0; pass < 30 && steadyFrames < 3; pass++) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final settled = _scrollController.position;
      final target = _newestOffset(settled);
      if (settled.pixels == target) {
        steadyFrames++;
      } else {
        steadyFrames = 0;
        _scrollController.jumpTo(target);
      }
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// Newest message id in the cached timeline, or null when there is nothing
  /// to anchor on.
  int? _newestCachedMessageId() {
    final messages = _visibleMessages();
    return messages.isEmpty ? null : messages.last.messageId;
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
    _jumpInProgress = true;
    try {
      await _resolveJump(messageId, key, generation);
    } finally {
      if (_isCurrentJump(key, generation)) _jumpInProgress = false;
    }
  }

  Future<void> _resolveJump(
    int messageId,
    ChatRoomProviderKey key,
    int generation,
  ) async {
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
      if (scope?.hasHistory != true || !await _loadOlder(fetchOnly: true)) {
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
    await _widenMessageWindowTo(messageId, key);
    if (!mounted || !_isCurrentJump(key, generation)) {
      return true;
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
    final pending = pendingAttachmentBatches(
      ref.read(attachmentRoomJobsProvider(_key)).asData?.value ?? const [],
      serverUrl: widget.account.serverUrl,
    );
    final pendingIds = {
      for (final batch in pending) ...batch.confirmedMessageIds,
    };
    final orderedIds = [
      for (final message in messages)
        if (!pendingIds.contains(message.messageId)) message.messageId,
      for (final message in messages)
        if (pendingIds.contains(message.messageId)) message.messageId,
    ];
    final offset = _scrollController.offsetForMessage(messageId, orderedIds);
    if (offset == null) {
      return;
    }
    final position = _scrollController.position;
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
  ///
  /// Selects the one row: the provider carries every conversation of the
  /// account, and watching it whole rebuilt the pane, composer included,
  /// whenever any other room changed.
  CachedConversation _watchLiveConversation() {
    final token = widget.conversation.token;
    return ref.watch(
          conversationsProvider(widget.account.id).select((conversations) {
            for (final conversation
                in conversations.valueOrNull ?? const <CachedConversation>[]) {
              if (conversation.token == token) {
                return conversation;
              }
            }
            return null;
          }),
        ) ??
        widget.conversation;
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
      ChatServiceError.reauthenticationRequired => true,
      // Also a captive portal page or a proxy's own status: retried with the
      // loop's backoff. A room that is really gone leaves the cache and then
      // ends the loop as conversationMissing.
      ChatServiceError.invalidResponse ||
      ChatServiceError.rateLimited ||
      ChatServiceError.serviceUnavailable ||
      ChatServiceError.network => false,
    };
  }
}
