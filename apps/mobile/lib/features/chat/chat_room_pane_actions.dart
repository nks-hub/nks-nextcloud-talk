part of 'chat_room_pane.dart';

extension _ChatRoomPaneActions on _ChatRoomPaneState {
  void _showMessageActions(
    CachedChatMessage message,
    ChatMessage? parsed, {
    required bool canReply,
    required bool canEdit,
    required bool canDelete,
    required bool canReact,
    required bool canPin,
    required bool isPinned,
    required bool canRemind,
    required bool canPrivateReply,
    required bool canTranslate,
  }) {
    final strings = AppLocalizations.of(context);
    final copyText = message.displayText;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Wrap(
            children: [
              if (canReply)
                ListTile(
                  key: const Key('message-action-reply'),
                  leading: const Icon(Icons.reply_rounded),
                  title: Text(strings.messageActionReply),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _startReply(message);
                  },
                ),
              if (copyText.isNotEmpty)
                ListTile(
                  key: const Key('message-action-copy'),
                  leading: const Icon(Icons.copy_rounded),
                  title: Text(strings.messageActionCopy),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_copyMessageText(copyText));
                  },
                ),
              if (canPrivateReply)
                ListTile(
                  key: const Key('message-action-private-reply'),
                  leading: const Icon(Icons.lock_outline_rounded),
                  title: Text(strings.messageActionPrivateReply),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_startPrivateReply(message));
                  },
                ),
              if (copyText.isNotEmpty)
                ListTile(
                  key: const Key('message-action-forward'),
                  leading: const Icon(Icons.forward_rounded),
                  title: Text(strings.messageActionForward),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_forwardMessage(copyText));
                  },
                ),
              if (copyText.isNotEmpty && _noteToSelf() != null)
                ListTile(
                  key: const Key('message-action-note-to-self'),
                  leading: const Icon(Icons.edit_note_rounded),
                  title: Text(strings.messageActionNoteToSelf),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_forwardMessage(copyText, target: _noteToSelf()));
                  },
                ),
              if (canEdit)
                ListTile(
                  key: const Key('message-action-edit'),
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(strings.messageActionEdit),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_startEditMessage(message, parsed));
                  },
                ),
              if (canTranslate && parsed != null)
                ListTile(
                  key: const Key('message-action-translate'),
                  leading: const Icon(Icons.translate_outlined),
                  title: Text(strings.messageActionTranslate),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_openTranslation(parsed));
                  },
                ),
              if (canDelete)
                ListTile(
                  key: const Key('message-action-delete'),
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: Text(strings.messageActionDelete),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_confirmDeleteMessage(message));
                  },
                ),
              if (canReact)
                ListTile(
                  key: const Key('message-action-react'),
                  leading: const Icon(Icons.add_reaction_outlined),
                  title: Text(strings.messageActionReact),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_openReactionPicker(message));
                  },
                ),
              if (canPin && !isPinned)
                ListTile(
                  key: const Key('message-action-pin'),
                  leading: const Icon(Icons.push_pin_outlined),
                  title: Text(strings.messageActionPin),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_pinMessage(message));
                  },
                ),
              if (canPin && isPinned)
                ListTile(
                  key: const Key('message-action-unpin'),
                  leading: const Icon(Icons.push_pin_rounded),
                  title: Text(strings.messageActionUnpin),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_unpinMessage(message));
                  },
                ),
              if (canRemind)
                ListTile(
                  key: const Key('message-action-remind'),
                  leading: const Icon(Icons.alarm_add_outlined),
                  title: Text(strings.messageActionRemind),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_openReminder(message));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openTranslation(ChatMessage message) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => MessageTranslationDialog(
        account: widget.account,
        roomToken: _key.roomToken,
        message: message,
        service: ref.read(messageTranslationServiceProvider),
      ),
    );
  }

  /// Forwards the rendered text of a message into another conversation of the
  /// same account.
  ///
  /// ponytail: Nextcloud Talk has no documented forward endpoint in
  /// `docs/architecture/chat-messages-api.md`, and the upstream clients
  /// implement forwarding as a plain send of the original text into the target
  /// room. This reuses `ChatService.sendText` for exactly that. Deliberate
  /// simplification: quoted attribution of the original author and forwarding
  /// of rich objects (files, polls, locations) are not carried over — those
  /// need a documented contract first.
  /// The account's own note-to-self room, when the cached list has one and
  /// this is not it. Talk creates the room server-side; the app only reads it.
  CachedConversation? _noteToSelf() {
    final conversations =
        ref.read(conversationsProvider(widget.account.id)).valueOrNull ??
        const <CachedConversation>[];
    for (final conversation in conversations) {
      if (conversation.roomType == ConversationRoomType.noteToSelf &&
          conversation.token != widget.conversation.token) {
        return conversation;
      }
    }
    return null;
  }

  Future<void> _forwardMessage(
    String text, {
    CachedConversation? target,
  }) async {
    final accountId = widget.account.id;
    target ??= await showModalBottomSheet<CachedConversation>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ForwardTargetSheet(
        accountId: accountId,
        excludedToken: widget.conversation.token,
      ),
    );
    if (target == null || !mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(chatServiceProvider)
          .sendText(
            accountId: accountId,
            roomToken: target.token,
            message: text,
          );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('chat-forward-success'),
            content: Text(strings.messageForwarded(target.displayName)),
          ),
        );
    } on Object {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('chat-forward-failure'),
            content: Text(strings.messageForwardFailed),
          ),
        );
    }
  }

  /// Answers [message] in the one-to-one conversation with its author.
  ///
  /// The reply text is collected first and the eligibility snapshot only
  /// afterwards, because the snapshot is bound to the source room, the target
  /// room and the parent message and is rechecked when the outbox admits the
  /// operation. Preparing it before the user has written anything would mean
  /// racing the capability generation for no reason.
  Future<void> _startPrivateReply(CachedChatMessage message) async {
    final strings = AppLocalizations.of(context);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _PrivateReplyDialog(
        authorDisplayName: message.actorDisplayName,
        quotedText: message.displayText,
      ),
    );
    if (text == null || !mounted) {
      return;
    }
    final accountId = widget.account.id;
    final sourceRoomToken = widget.conversation.token;
    final messenger = ScaffoldMessenger.of(context);
    final chatService = ref.read(chatServiceProvider);
    try {
      final targetToken = await ref
          .read(newConversationServiceProvider)
          .createOneToOneWithUser(
            accountId: accountId,
            userId: message.actorId,
          );
      final eligibility = await chatService.preparePrivateReplyEligibility(
        accountId: accountId,
        sourceRoomToken: sourceRoomToken,
        targetRoomToken: targetToken.value,
        parentMessageId: message.messageId,
      );
      await chatService.sendText(
        accountId: accountId,
        roomToken: targetToken.value,
        message: text,
        replyTo: message.messageId,
        replyToToken: sourceRoomToken,
        privateReplyEligibility: eligibility,
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('private-reply-success'),
            content: Text(strings.privateReplySent(message.actorDisplayName)),
          ),
        );
    } on ChatServiceException catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('private-reply-failure'),
            content: Text(
              error.code == ChatServiceError.sendUnsupported
                  ? strings.privateReplyUnsupported
                  : strings.privateReplyFailed,
            ),
          ),
        );
    } on Object {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('private-reply-failure'),
            content: Text(strings.privateReplyFailed),
          ),
        );
    }
  }

  /// Pins [message] for the whole conversation.
  ///
  /// The pin lives on the room, not on the message, so the banner only
  /// appears once the conversation row carries the new `lastPinnedId`. The
  /// refresh below is what fetches that row; without it the pin would be
  /// invisible until the next scheduled conversation sync.
  Future<void> _pinMessage(CachedChatMessage message) async {
    final targetKey = _key;
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .pinMessage(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
          );
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
      return;
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
      return;
    }
    await _refreshConversations();
    if (!mounted) {
      return;
    }
    _showActionNotice(
      AppLocalizations.of(context).messagePinned,
      const Key('chat-pin-success'),
    );
  }

  Future<void> _unpinMessage(CachedChatMessage message) async {
    final targetKey = _key;
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .unpinMessage(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
          );
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
      return;
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
      return;
    }
    await _refreshConversations();
    if (!mounted) {
      return;
    }
    _showActionNotice(
      AppLocalizations.of(context).messageUnpinned,
      const Key('chat-unpin-success'),
    );
  }

  /// Hides the conversation pin for this account only.
  Future<void> _hidePinnedMessage(int messageId) async {
    final targetKey = _key;
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .hidePinnedMessage(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: messageId,
          );
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
      return;
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
      return;
    }
    await _refreshConversations();
  }

  /// Opens the reminder options for [message] and applies the choice.
  ///
  /// The existing reminder is read first so the sheet can offer to remove it;
  /// Talk answers "no reminder here" with a `404`, which the service reports
  /// as `null` rather than as a failure.
  Future<void> _openReminder(CachedChatMessage message) async {
    final targetKey = _key;
    final service = ref.read(chatMessageActionsServiceProvider);
    RichChatReminder? existing;
    try {
      existing = await service.getReminder(
        accountId: targetKey.accountId,
        roomToken: targetKey.roomToken,
        messageId: message.messageId,
      );
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
      return;
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
      return;
    }
    if (!mounted || targetKey != _key) {
      return;
    }
    final existingAt = existing == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            existing.timestamp * 1000,
          ).toLocal();
    final now = DateTime.now();
    final result = await showReminderSheet(
      context: context,
      now: now,
      existing: existingAt,
    );
    if (result == null || !mounted || targetKey != _key) {
      return;
    }
    final strings = AppLocalizations.of(context);
    try {
      switch (result.action) {
        case ReminderSheetAction.remove:
          await service.deleteReminder(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
          );
          if (mounted) {
            _showActionNotice(
              strings.reminderRemoved,
              const Key('chat-reminder-removed'),
            );
          }
        case ReminderSheetAction.set:
          final at = result.at!;
          if (!at.isAfter(DateTime.now())) {
            _showActionNotice(
              strings.scheduleTimeInPast,
              const Key('chat-reminder-past'),
            );
            return;
          }
          await service.setReminder(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
            timestamp: at.toUtc().millisecondsSinceEpoch ~/ 1000,
          );
          if (mounted) {
            _showActionNotice(
              strings.reminderSet(formatMoment(context, at)),
              const Key('chat-reminder-set'),
            );
          }
      }
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
    }
  }

  /// Hands the composed text to the server to deliver later.
  ///
  /// This never enters the durable text-send outbox. That outbox settles
  /// "did this POST reach the chat" by matching its `referenceId` against
  /// fresh history, and a scheduled message has no history entry until the
  /// server fires it, so an outbox record would stay unresolved for hours and
  /// a manual resend would duplicate it. The schedule is the server's, and
  /// [_openScheduledMessages] is how an unclear result gets settled.
  Future<void> _scheduleMessage() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending || _isReadOnlyNow()) {
      return;
    }
    final targetKey = _key;
    final at = await showSendLaterSheet(context: context, now: DateTime.now());
    if (at == null || !mounted || targetKey != _key || _isReadOnlyNow()) {
      return;
    }
    final strings = AppLocalizations.of(context);
    if (!at.isAfter(DateTime.now())) {
      _showActionNotice(
        strings.scheduleTimeInPast,
        const Key('chat-schedule-past'),
      );
      return;
    }
    _update(() => _sending = true);
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .scheduleMessage(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            message: text,
            sendAt: at.toUtc().millisecondsSinceEpoch ~/ 1000,
          );
      if (!mounted || targetKey != _key) {
        return;
      }
      _composer.clear();
      _showActionNotice(
        strings.scheduleMessageSet(formatMoment(context, at)),
        const Key('chat-schedule-success'),
      );
      await _refreshConversations();
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
    } finally {
      if (mounted) {
        _update(() => _sending = false);
      }
    }
  }

  Future<void> _openScheduledMessages() async {
    final targetKey = _key;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => ScheduledMessagesSheet(
        accountId: targetKey.accountId,
        roomToken: targetKey.roomToken,
      ),
    );
    await _refreshConversations();
  }

  /// Pulls the conversation list again so a room-level change - a new pin, a
  /// new scheduled message - reaches the cached row this pane renders from.
  ///
  /// Neither the pin nor the scheduled-message count is carried by a chat
  /// message: both live on the conversation, so only a conversation sync can
  /// observe them. A full sync is asked for because a delta may legitimately
  /// skip a room whose `lastActivity` a pin did not move.
  Future<void> _refreshConversations() async {
    try {
      await ref
          .read(conversationSyncServiceProvider)
          .sync(widget.account.id, forceFull: true);
    } on Object {
      // The mutation itself already succeeded; a stale banner until the next
      // scheduled sync is not worth a second error channel on top of the
      // pane's own sync error handling.
    }
  }

  void _showActionNotice(String text, Key key) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: key, content: Text(text)));
  }

  Future<void> _copyMessageText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(strings.messageCopied)));
  }

  Future<void> _startEditMessage(
    CachedChatMessage message,
    ChatMessage? parsed,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _EditMessageDialog(
        initialText: parsed?.message ?? message.displayText,
      ),
    );
    final trimmed = result?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) {
      return;
    }
    final targetKey = _key;
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .editMessage(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
            message: trimmed,
          );
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
    }
  }

  Future<void> _confirmDeleteMessage(CachedChatMessage message) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('delete-message-dialog'),
        title: Text(strings.deleteMessageConfirmTitle),
        // Large text can make the body taller than the screen; without this
        // the actions are pushed off the bottom and the dialog cannot be
        // answered at all.
        scrollable: true,
        content: Text(strings.deleteMessageConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('confirm-delete-message'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.messageActionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final targetKey = _key;
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .deleteMessage(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
          );
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
    }
  }

  Future<void> _toggleReaction(
    CachedChatMessage message,
    ChatMessage? parsed,
    String emoji,
  ) async {
    if (_isReadOnlyNow()) {
      return;
    }
    final selfReacted = parsed?.reactionsSelf.contains(emoji) ?? false;
    final targetKey = _key;
    try {
      final service = ref.read(chatMessageActionsServiceProvider);
      if (selfReacted) {
        await service.deleteReaction(
          accountId: targetKey.accountId,
          roomToken: targetKey.roomToken,
          messageId: message.messageId,
          reaction: emoji,
        );
      } else {
        await service.addReaction(
          accountId: targetKey.accountId,
          roomToken: targetKey.roomToken,
          messageId: message.messageId,
          reaction: emoji,
        );
      }
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
    }
  }

  Future<void> _openReactionPicker(CachedChatMessage message) async {
    if (_isReadOnlyNow()) {
      return;
    }
    final strings = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final emoji in _ChatRoomPaneState._quickReactionEmoji)
                    InkWell(
                      key: Key('quick-reaction-$emoji'),
                      borderRadius: BorderRadius.circular(24),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          _toggleReaction(
                            message,
                            _parseCachedMessage(message),
                            emoji,
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                key: const Key('open-full-reaction-picker'),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_openFullReactionPicker(message));
                },
                icon: const Icon(Icons.add_reaction_outlined),
                label: Text(strings.reactionPickerMore),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFullReactionPicker(CachedChatMessage message) async {
    if (_isReadOnlyNow()) {
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
              accountId: AccountId.parse(_key.accountId),
              usageStore: ref.read(emojiUsageStoreProvider),
              labels: _emojiPickerLabels(strings),
              onClose: () => Navigator.of(sheetContext).pop(),
              onSelected: (choice) {
                Navigator.of(sheetContext).pop();
                unawaited(
                  _toggleReaction(
                    message,
                    _parseCachedMessage(message),
                    choice.glyph,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _showActionError(ChatMessageActionError code) {
    if (!mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(_messageActionErrorMessage(strings, code))),
      );
  }
}
