part of 'chat_room_pane.dart';

extension _ChatRoomPaneAttachmentControls on _ChatRoomPaneState {
  bool _supportsFileAttachment(
    AsyncValue<ChatAttachmentDependencies>? dependencies,
  ) {
    final profile = dependencies?.valueOrNull?.profile;
    final thread = _currentThreadContext;
    if (profile == null || (widget.threadId != null && thread == null)) {
      return false;
    }
    return profile.supports(
      AttachmentMetadata(
        kind: AttachmentMessageKind.file,
        replyTo: widget.threadId == null
            ? _replyTo?.messageId
            : thread?.replyTo,
        threadId: widget.threadId == null ? null : thread?.networkThreadId,
        silent: _silentSend,
      ),
    );
  }

  List<AttachmentMenuAction> _attachmentMenuActions({
    required AppLocalizations strings,
    required bool attachmentSupported,
    required RichChatCapabilityProfile? actionsProfile,
    required AsyncValue<bool>? pollAvailable,
    required bool voiceSupported,
  }) => <AttachmentMenuAction>[
    AttachmentMenuAction(
      key: const Key('open-format-menu'),
      icon: const Icon(Icons.text_format_rounded),
      label: strings.formatMenuTooltip,
      onSelected: _sending ? null : () => unawaited(_chooseComposerFormat()),
    ),
    AttachmentMenuAction(
      key: const Key('open-reply-templates'),
      icon: const Icon(Icons.short_text_rounded),
      label: strings.replyTemplates,
      onSelected: _sending ? null : () => unawaited(_chooseReplyTemplate()),
    ),
    if (voiceSupported)
      AttachmentMenuAction(
        key: const Key('record-voice-message'),
        icon: const Icon(Icons.mic_none_rounded),
        label: strings.recordVoiceMessage,
        onSelected: _sending
            ? null
            : () => unawaited(_mediaComposerController.startVoice()),
      ),
    AttachmentMenuAction(
      key: const Key('attach-source-gallery'),
      icon: const Icon(Icons.image_outlined),
      label: strings.attachFromGallery,
      onSelected: !attachmentSupported || _sending
          ? null
          : () => unawaited(
              _mediaComposerController.pickAttachment(
                AttachmentPickerSource.gallery,
              ),
            ),
    ),
    AttachmentMenuAction(
      key: const Key('attach-source-camera'),
      icon: const Icon(Icons.photo_camera_outlined),
      label: strings.attachFromCamera,
      onSelected: !attachmentSupported || _sending
          ? null
          : () => unawaited(
              _mediaComposerController.pickAttachment(
                AttachmentPickerSource.camera,
              ),
            ),
    ),
    AttachmentMenuAction(
      key: const Key('attach-source-file'),
      icon: const Icon(Icons.insert_drive_file_outlined),
      label: strings.attachFromFile,
      onSelected: !attachmentSupported || _sending
          ? null
          : () => unawaited(
              _mediaComposerController.pickAttachment(
                AttachmentPickerSource.file,
              ),
            ),
    ),
    AttachmentMenuAction(
      key: const Key('attach-source-contact'),
      icon: const Icon(Icons.contact_page_outlined),
      label: strings.contactAttachment,
      onSelected: !attachmentSupported || _sending
          ? null
          : () => unawaited(_mediaComposerController.pickContact()),
    ),
    AttachmentMenuAction(
      key: const Key('attach-source-remote-file'),
      icon: const Icon(Icons.cloud_outlined),
      label: strings.attachFromServer,
      onSelected: _sending ? null : () => unawaited(_pickRemoteFile()),
    ),
    if (actionsProfile?.geoLocation ?? false)
      AttachmentMenuAction(
        key: const Key('share-current-location'),
        icon: const Icon(Icons.location_on_outlined),
        label: strings.shareLocation,
        onSelected:
            _sending ||
                (widget.threadId != null &&
                    _currentThreadContext?.isNamed != true)
            ? null
            : () => unawaited(_shareCurrentLocation()),
      ),
    if (actionsProfile?.geoLocation ?? false)
      AttachmentMenuAction(
        key: const Key('pick-location-on-map'),
        icon: const Icon(Icons.map_outlined),
        label: strings.locationPickerMenuAction,
        onSelected:
            _sending ||
                (widget.threadId != null &&
                    _currentThreadContext?.isNamed != true)
            ? null
            : () => unawaited(_pickLocationOnMap()),
      ),
    if (_offersRoomTool(RoomMessageTool.checklist, watch: true))
      AttachmentMenuAction(
        key: const Key('compose-checklist'),
        icon: const Icon(Icons.checklist),
        label: strings.sharedChecklist,
        onSelected: _sending || _composer.text.isNotEmpty
            ? null
            : () => unawaited(_newSharedChecklist()),
      ),
    if (pollAvailable?.isLoading ?? false)
      AttachmentMenuAction(
        key: const Key('create-poll-checking'),
        icon: const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: strings.pollChecking,
        onSelected: null,
      ),
    if (pollAvailable?.valueOrNull ?? false)
      AttachmentMenuAction(
        key: const Key('create-poll'),
        icon: const Icon(Icons.poll_outlined),
        label: strings.pollMenuAction,
        onSelected: _sending ? null : () => unawaited(_openPollComposer()),
      ),
  ];

  Future<void> _chooseReplyTemplate() async {
    final room = _key;
    final text = await showReplyTemplates(
      context,
      account: AccountId.parse(room.accountId),
      store: ref.read(replyTemplateStoreProvider),
    );
    if (text == null || !mounted || room != _key || _isReadOnlyNow()) return;
    if (!insertComposerText(_composer, text)) _showComposerLimitError();
    _composerFocusNode.requestFocus();
  }

  bool _offersRoomTool(RoomMessageTool tool, {bool watch = false}) {
    final key = (
      accountId: widget.account.id,
      roomToken: widget.conversation.token,
    );
    if (!ownTalkConversationCanShare(
      roomType: widget.conversation.roomType,
      rawJson: widget.conversation.rawJson,
    )) {
      return false;
    }
    final supported = ownTalkRoomExtrasProvider(
      key,
    ).select((s) => s.capability?.supportsFeature(tool.feature) == true);
    return watch ? ref.watch(supported) : ref.read(supported);
  }

  Future<void> _newSharedChecklist() async {
    final key = _key;
    final text = await composeSharedChecklist(context);
    if (!mounted ||
        key != _key ||
        text == null ||
        _composer.text.isNotEmpty ||
        _isReadOnlyNow()) {
      return;
    }
    if (!insertComposerText(_composer, text)) {
      _showComposerLimitError();
      return;
    }
    _composerFocusNode.requestFocus();
  }

  Future<void> _chooseComposerFormat() async {
    final room = _key;
    final strings = AppLocalizations.of(context);
    final format = await showModalBottomSheet<ComposerFormat>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (format, label, icon) in [
                (ComposerFormat.bold, strings.formatBold, Icons.format_bold),
                (
                  ComposerFormat.italic,
                  strings.formatItalic,
                  Icons.format_italic,
                ),
                (
                  ComposerFormat.strikethrough,
                  strings.formatStrikethrough,
                  Icons.format_strikethrough,
                ),
                (
                  ComposerFormat.inlineCode,
                  strings.formatInlineCode,
                  Icons.code,
                ),
                (
                  ComposerFormat.codeBlock,
                  strings.formatCodeBlock,
                  Icons.data_object,
                ),
              ])
                ListTile(
                  key: Key('format-${format.name}'),
                  leading: Icon(icon),
                  title: Text(label),
                  onTap: () => Navigator.pop(sheetContext, format),
                ),
            ],
          ),
        ),
      ),
    );
    if (mounted && _key == room && format != null) {
      _applyComposerFormat(format);
    }
  }

  Widget _buildMediaComposer(
    AsyncValue<ChatAttachmentDependencies> dependencies, {
    required Widget field,
    required Widget leadingAction,
    required List<Widget> idleActions,
    required ChatComposerDraftActions draftActions,
  }) {
    return dependencies.when(
      loading: () => ChatMediaComposerStatus.loading(
        field: field,
        leadingAction: leadingAction,
        idleActions: idleActions,
        draftActions: draftActions,
      ),
      error: (_, _) => ChatMediaComposerStatus.unavailable(
        field: field,
        leadingAction: leadingAction,
        idleActions: idleActions,
        draftActions: draftActions,
        onRetry: () => retryChatAttachmentDependencies(ref, _key),
      ),
      data: (value) {
        final captionOwner = _key;
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
            // The same source the call uses: the platform says when it has
            // taken the microphone for a telephone call, and a recording that
            // does not hear it records the ringing.
            audioInterruptions: ref.read(callAudioInterruptionsProvider),
            field: field,
            leadingAction: leadingAction,
            idleActions: idleActions,
            draftActions: draftActions,
            showAttachmentButton: false,
            silent: _silentSend,
            captionSource: () => _composer.text,
            onCaptionConsumed: (caption) =>
                _clearConsumedCaption(captionOwner, caption),
            openAppSettings: () => ref.read(appSettingsOpenerProvider).open(),
          );
        } on TalkProtocolException {
          return ChatMediaComposerStatus.unavailable(
            field: field,
            leadingAction: leadingAction,
            idleActions: idleActions,
            draftActions: draftActions,
            onRetry: () => retryChatAttachmentDependencies(ref, _key),
          );
        }
      },
    );
  }
}
