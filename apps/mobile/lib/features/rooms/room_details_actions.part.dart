part of 'room_details_screen.dart';

mixin _RoomDetailsStateLogic on ConsumerState<RoomDetailsScreen> {
  late Future<List<Participant>> _participants;
  late ConversationRoom? _room;
  late bool _isFavorite;
  late int _notificationLevel;
  late bool _callNotificationsEnabled;
  bool _busy = false;

  late Set<String> _talkFeatures;

  @override
  void initState() {
    super.initState();
    _participants = _load();
    _room = _parseCachedRoom(widget.conversation);
    _isFavorite = widget.conversation.favorite;
    _notificationLevel = _room?.notificationLevel ?? _notificationDefault;
    _callNotificationsEnabled = _room?.notificationCalls == 1;
    _talkFeatures = _decodeTalkFeatures(widget.account.talkFeaturesJson);
  }

  Future<List<Participant>> _load() {
    return ref
        .read(participantsServiceProvider)
        .fetchParticipants(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
        );
  }

  void _retry() {
    setState(() {
      _participants = _load();
    });
  }

  /// Owners, moderators and guest moderators may rename the conversation and
  /// change its description; a plain participant must never see these.
  bool get _isModerator {
    return switch (participantRoleFor(_room?.participantType ?? -1)) {
      ParticipantRole.owner ||
      ParticipantRole.moderator ||
      ParticipantRole.guestModerator => true,
      _ => false,
    };
  }

  /// The server is the source of truth for whether leaving is currently
  /// allowed (e.g. it is refused for the last moderator); default to hidden
  /// when that could not be determined from the cached room.
  bool get _canLeave => _room?.canLeaveConversation ?? false;

  /// The server decides who may delete a conversation for everyone: it is
  /// refused without moderator rights and in one-to-one conversations, and
  /// reports that as `canDeleteConversation`. Hidden when the cached room
  /// could not be parsed, and paired with the local moderator check so a
  /// plain participant never sees the action.
  bool get _canDelete =>
      _isModerator && (_room?.canDeleteConversation ?? false);

  int get _roomType => _room?.type ?? widget.conversation.roomType;

  bool get _isPublic => _roomType == _roomTypePublic;

  /// The three administration endpoints the server only accepts for group and
  /// public conversations. Talk answers `400` for every other type on
  /// read-only and lobby ("only group and public conversation"), and
  /// `BanService::createBan` throws `InvalidArgumentException('room')` unless
  /// the room is `TYPE_GROUP` or `TYPE_PUBLIC`.
  bool get _isGroupOrPublic =>
      _roomType == _roomTypeGroup || _roomType == _roomTypePublic;

  /// Making a conversation public is only offered for a group conversation,
  /// and making it private only for a public one — the server answers `400`
  /// for the other direction.
  bool get _canToggleGuests => _isModerator && _isGroupOrPublic;

  /// A password only exists on a public conversation: Talk answers `403`
  /// "When the conversation is not a public conversation".
  bool get _canSetPassword => _isModerator && _isPublic;

  bool get _canSetReadOnly =>
      _isModerator &&
      _isGroupOrPublic &&
      _talkFeatures.contains(_readOnlyCapability);

  bool get _canSetLobby =>
      _isModerator &&
      _isGroupOrPublic &&
      _talkFeatures.contains(_lobbyCapability);

  /// Talk only accepts a name and a description on group and public rooms.
  /// A one-to-one room, its former shell, note-to-self and the changelog take
  /// their title from the other party or from the system, so offering the
  /// actions there would only produce a refusal.
  bool get _canEditRoomMetadata => _isModerator && _isGroupOrPublic;

  /// The avatar endpoints refuse a one-to-one conversation with `400`, so the
  /// action stays hidden there even for a moderator.
  bool get _canSetAvatar =>
      _isModerator &&
      _roomType != _roomTypeOneToOne &&
      _talkFeatures.contains(_avatarCapability);

  /// Talk `docs/avatar.md` recommends checking `isCustomAvatar` to decide
  /// whether to offer the removal at all.
  bool get _canRemoveAvatar =>
      _canSetAvatar && (_room?.isCustomAvatar ?? false);

  bool get _canBan =>
      _isModerator &&
      _isGroupOrPublic &&
      _talkFeatures.contains(_banCapability);

  bool get _hasPassword => _room?.hasPassword ?? false;

  int get _lobbyState => _room?.lobbyState ?? 0;

  int get _readOnly => _room?.readOnly ?? widget.conversation.readOnly;

  CachedConversation get _summaryConversation {
    final room = _room;
    if (room == null) {
      return widget.conversation;
    }
    return widget.conversation.copyWith(
      displayName: room.displayName,
      description: room.description,
      readOnly: room.readOnly,
      roomType: room.type,
      roomName: room.name,
      objectType: room.objectType,
      avatarVersion: room.avatarVersion,
      isCustomAvatar: room.isCustomAvatar,
    );
  }

  String _lobbyLabel(AppLocalizations strings) {
    if (_lobbyState == 0) {
      return strings.roomDetailsLobbyOff;
    }
    final timer = _room?.lobbyTimer ?? 0;
    return timer > 0
        ? strings.roomDetailsLobbyOnUntil(_formatLobbyTimer(timer))
        : strings.roomDetailsLobbyOn;
  }

  /// The guest link is a client-side URL, not an API call. Talk's
  /// `PageController` declares the route
  /// `#[FrontpageRoute(verb: 'GET', url: '/call/{token}', ...)]`, and the
  /// official web client builds exactly this address in
  /// `src/utils/handleUrl.ts` (`generateFullConversationLink` ->
  /// `generateAbsoluteUrl('/call/{token}', { token })`). The `index.php` form
  /// is used because it resolves whether or not the instance has pretty URLs,
  /// which is the same choice this app already makes for avatar URLs.
  Uri get _guestLink {
    final server = ServerBase.parse(widget.account.serverUrl);
    return server.uri.replace(
      path: '${server.basePath}/index.php/call/${widget.conversation.token}',
    );
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    String Function(AppLocalizations, RoomSettingsError) errorMessage =
        _actionErrorMessage,
    String Function(AppLocalizations, ParticipantsServiceError)
        participantErrorMessage =
        _participantActionErrorMessage,
  }) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on RoomSettingsException catch (error) {
      // Talk tells clients to show `ocs.data.message` verbatim when a
      // password violates the instance policy, because only the server knows
      // which rule failed and it already translated the explanation.
      final message = error.message;
      if (message != null && message.trim().isNotEmpty) {
        _showMessage(message);
      } else {
        _showActionError(errorMessage, error.code);
      }
    } on ParticipantsServiceException catch (error) {
      _showActionError(participantErrorMessage, error.code);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showActionError<T>(
    String Function(AppLocalizations, T) message,
    T code,
  ) {
    if (!mounted) {
      return;
    }
    _showMessage(message(AppLocalizations.of(context), code));
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _renameRoom() async {
    final strings = AppLocalizations.of(context);
    final newName = await showTextPromptDialog(
      context: context,
      fieldKey: const Key('room-details-rename-field'),
      confirmKey: const Key('room-details-rename-save'),
      title: strings.roomDetailsRenameDialogTitle,
      initialValue: _room?.displayName ?? widget.conversation.displayName,
      fieldLabel: strings.roomDetailsRenameFieldLabel,
      cancelLabel: strings.cancel,
      confirmLabel: strings.roomDetailsSave,
    );
    if (newName == null || newName.trim().isEmpty || !mounted) {
      return;
    }
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .renameRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            name: newName,
          );
      if (mounted) {
        setState(() => _room = room);
      }
    });
  }

  Future<void> _editDescription() async {
    final strings = AppLocalizations.of(context);
    final newDescription = await showTextPromptDialog(
      context: context,
      fieldKey: const Key('room-details-description-field'),
      confirmKey: const Key('room-details-description-save'),
      title: strings.roomDetailsDescriptionDialogTitle,
      initialValue: _room?.description ?? widget.conversation.description,
      fieldLabel: strings.roomDetailsDescriptionFieldLabel,
      cancelLabel: strings.cancel,
      confirmLabel: strings.roomDetailsSave,
      minLines: 2,
      maxLines: 6,
    );
    if (newDescription == null || !mounted) {
      return;
    }
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .updateDescription(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            description: newDescription,
          );
      if (mounted) {
        setState(() => _room = room);
      }
    });
  }

  Future<void> _changeNotificationLevel() async {
    final strings = AppLocalizations.of(context);
    final current = switch (_notificationLevel) {
      _notificationAlways => RoomNotificationLevel.always,
      _notificationMention => RoomNotificationLevel.mentions,
      _notificationNever => RoomNotificationLevel.never,
      _ => null,
    };
    final selected = await showDialog<RoomNotificationLevel>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const Key('room-details-notification-dialog'),
        title: Text(strings.roomDetailsNotificationDialogTitle),
        children: [
          for (final level in RoomNotificationLevel.values)
            SimpleDialogOption(
              key: Key('room-details-notification-${level.name}'),
              onPressed: () => Navigator.of(dialogContext).pop(level),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: level == current
                        ? const Icon(Icons.check, size: 20)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(_notificationLevelLabel(strings, level)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .setNotificationLevel(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            level: selected,
          );
      if (mounted) {
        setState(() => _notificationLevel = selected.wireValue);
      }
    });
  }

  Future<void> _toggleCallNotifications(bool enabled) async {
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .setCallNotificationLevel(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            level: enabled
                ? RoomCallNotificationLevel.on
                : RoomCallNotificationLevel.off,
          );
      if (mounted) {
        setState(() {
          _room = room;
          _callNotificationsEnabled = room.notificationCalls == 1;
        });
      }
    });
  }

  Future<void> _toggleFavorite(bool value) async {
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .setFavorite(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            favorite: value,
          );
      if (mounted) {
        setState(() => _isFavorite = value);
      }
    });
  }

  Future<void> _confirmLeave() async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-leave-dialog'),
        title: Text(strings.roomDetailsLeaveDialogTitle),
        content: Text(strings.roomDetailsLeaveDialogMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-leave-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsLeaveDialogConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    var left = false;
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .leaveRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          );
      left = true;
    });
    if (left && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _confirmDelete() async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-delete-dialog'),
        title: Text(strings.roomDetailsDeleteDialogTitle),
        content: Text(strings.roomDetailsDeleteDialogMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsDeleteDialogConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    var deleted = false;
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .deleteRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            canDeleteConversation: _room?.canDeleteConversation ?? false,
          );
      deleted = true;
    }, errorMessage: _deleteErrorMessage);
    if (deleted && mounted) {
      // Popping once would land on the chat of a conversation that no longer
      // exists, so unwind to the conversation list instead.
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// Applies one administration change and folds whatever refreshed room the
  /// server answered with back into the screen. The endpoints that answer
  /// without a room leave [_room] alone, so [fallback] patches the one field
  /// the caller knows changed.
  Future<void> _administer(
    Future<ConversationRoom?> Function() action, {
    required Map<String, Object?> Function() fallback,
    String Function(AppLocalizations, RoomSettingsError)? errorMessage,
  }) async {
    await _runAction(() async {
      final room = await action();
      if (!mounted) {
        return;
      }
      setState(() => _room = room ?? _patchCachedRoom(_room, fallback()));
    }, errorMessage: errorMessage ?? _actionErrorMessage);
  }

  Future<void> _toggleGuests(bool value) async {
    if (!value &&
        !await _confirm(
          key: 'room-details-guests-close-dialog',
          confirmKey: 'room-details-guests-close-confirm',
          title: (strings) => strings.roomDetailsGuestsCloseDialogTitle,
          message: (strings) => strings.roomDetailsGuestsCloseDialogMessage,
          confirmLabel: (strings) =>
              strings.roomDetailsGuestsCloseDialogConfirm,
        )) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setPublic(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            public: value,
          ),
      // Turning guests off also drops any password, because a password only
      // exists on a public conversation.
      fallback: () => {
        'type': value ? _roomTypePublic : _roomTypeGroup,
        if (!value) 'hasPassword': false,
      },
    );
  }

  Future<void> _shareGuestLink() async {
    final strings = AppLocalizations.of(context);
    await widget.linkSharer.share(
      uri: _guestLink,
      subject: strings.roomDetailsInviteLinkShareSubject,
    );
  }

  Future<void> _setPassword() async {
    final strings = AppLocalizations.of(context);
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _PasswordDialog(strings: strings),
    );
    if (password == null || !mounted) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setPassword(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            password: password,
          ),
      fallback: () => {'hasPassword': true},
      errorMessage: _passwordErrorMessage,
    );
  }

  Future<void> _removePassword() async {
    if (!await _confirm(
      key: 'room-details-password-remove-dialog',
      confirmKey: 'room-details-password-remove-confirm',
      title: (strings) => strings.roomDetailsPasswordRemoveDialogTitle,
      message: (strings) => strings.roomDetailsPasswordRemoveDialogMessage,
      confirmLabel: (strings) => strings.roomDetailsPasswordRemoveDialogConfirm,
    )) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setPassword(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            password: '',
          ),
      fallback: () => {'hasPassword': false},
      errorMessage: _passwordErrorMessage,
    );
  }

  Future<void> _toggleLobby(bool value) async {
    int? timer;
    if (value) {
      final choice = await showDialog<_LobbyChoice>(
        context: context,
        builder: (dialogContext) => _LobbyDialog(
          strings: AppLocalizations.of(context),
          now: DateTime.now(),
        ),
      );
      if (choice == null || !mounted) {
        return;
      }
      timer = choice.timerSecondsSinceEpoch;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setLobby(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            state: value ? RoomLobbyState.moderatorsOnly : RoomLobbyState.none,
            timerSecondsSinceEpoch: timer,
          ),
      fallback: () => {'lobbyState': value ? 1 : 0, 'lobbyTimer': timer ?? 0},
    );
  }

  Future<void> _toggleReadOnly(bool value) async {
    if (value &&
        !await _confirm(
          key: 'room-details-read-only-dialog',
          confirmKey: 'room-details-read-only-confirm',
          title: (strings) => strings.roomDetailsReadOnlyDialogTitle,
          message: (strings) => strings.roomDetailsReadOnlyDialogMessage,
          confirmLabel: (strings) => strings.roomDetailsReadOnlyDialogConfirm,
        )) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setReadOnly(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            state: value
                ? RoomReadOnlyState.readOnly
                : RoomReadOnlyState.readWrite,
          ),
      fallback: () => {'readOnly': value ? 1 : 0},
    );
  }

  Future<void> _changeAvatar() async {
    final choice = await showDialog<_AvatarChoice>(
      context: context,
      builder: (dialogContext) =>
          _AvatarDialog(strings: AppLocalizations.of(context)),
    );
    if (choice == null || !mounted) {
      return;
    }
    if (choice.pickImage) {
      return _uploadAvatarImage();
    }
    final emoji = choice.emoji;
    if (emoji == null) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setEmojiAvatar(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            emoji: emoji,
            hexColor: choice.hexColor,
          ),
      fallback: () => {'isCustomAvatar': true},
    );
  }

  /// Picks a picture and uploads it. Talk only accepts a square PNG or JPEG;
  /// the type is checked here, and the server explains every other refusal
  /// (not square, too big) in its own words.
  Future<void> _uploadAvatarImage() async {
    final ImageSelection? selection;
    try {
      selection = await widget.imagePicker.selectImage(
        AttachmentPickerSource.gallery,
      );
    } on ImageAttachmentPickerException {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).roomDetailsAvatarTypeRejected,
        );
      }
      return;
    }
    if (selection == null || !mounted) {
      return;
    }
    if (selection.byteLength < 1 ||
        selection.byteLength > roomAvatarMaximumBytes) {
      _showMessage(AppLocalizations.of(context).roomDetailsAvatarTooLarge);
      return;
    }

    final bytes = <int>[];
    await for (final chunk in selection.openRead()) {
      bytes.addAll(chunk);
    }
    final contentType =
        lookupMimeType(selection.displayName, headerBytes: bytes) ??
        selection.declaredMimeType;
    if (contentType == null || !roomAvatarImageTypes.contains(contentType)) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).roomDetailsAvatarTypeRejected,
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .uploadAvatar(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            imageBytes: bytes,
            contentType: contentType,
            fileName: _safeAvatarFileName(selection!.displayName, contentType),
          ),
      fallback: () => {'isCustomAvatar': true},
      errorMessage: _avatarErrorMessage,
    );
  }

  Future<void> _removeAvatar() async {
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .deleteAvatar(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          ),
      fallback: () => {'isCustomAvatar': false},
    );
  }

  /// Bans one attendee. The server removes them from the conversation in the
  /// same call, so the participant list is refetched afterwards.
  Future<void> _ban(Participant participant) async {
    final actorType = bannedActorTypeFor(participant.actorType);
    if (actorType == null) {
      return;
    }
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _BanDialog(
        strings: AppLocalizations.of(context),
        displayName: participant.displayName,
      ),
    );
    if (note == null || !mounted) {
      return;
    }
    var banned = false;
    await _runAction(() async {
      await ref
          .read(participantsServiceProvider)
          .banActor(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            actorType: actorType,
            actorId: participant.actorId,
            internalNote: note,
          );
      banned = true;
    }, participantErrorMessage: _banErrorMessage);
    if (banned && mounted) {
      _retry();
    }
  }

  Future<void> _showBans() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _BansDialog(
        account: widget.account,
        roomToken: widget.conversation.token,
      ),
    );
  }

  /// One confirmation dialog for every destructive administration change, so
  /// each of them does not repeat the same twenty lines.
  Future<bool> _confirm({
    required String key,
    required String confirmKey,
    required String Function(AppLocalizations) title,
    required String Function(AppLocalizations) message,
    required String Function(AppLocalizations) confirmLabel,
  }) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: Key(key),
        title: Text(title(strings)),
        content: Text(message(strings)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: Key(confirmKey),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel(strings)),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  /// Runs a moderation change and refetches the list, because the endpoints
  /// answer with an empty payload and the new roles are only visible after a
  /// reload.
  Future<void> _moderate(
    Participant participant,
    ParticipantModerationAction action,
  ) async {
    if (action == ParticipantModerationAction.remove &&
        !await _confirmRemoval(participant)) {
      return;
    }
    var changed = false;
    await _runAction(() async {
      await ref
          .read(participantsServiceProvider)
          .moderateParticipant(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            attendeeId: participant.attendeeId,
            action: action,
          );
      changed = true;
    });
    if (changed && mounted) {
      _retry();
    }
  }

  Future<bool> _confirmRemoval(Participant participant) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-remove-participant-dialog'),
        title: Text(strings.roomDetailsRemoveDialogTitle),
        content: Text(
          strings.roomDetailsRemoveDialogMessage(participant.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-remove-participant-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsRemoveDialogConfirm),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  /// Which moderation actions the server would accept for this attendee, so
  /// the menu never offers a change that is guaranteed to come back as an
  /// error. The server stays the authority; this only trims the obvious ones.
  List<ParticipantAction> _availableActions(Participant participant) {
    if (!_isModerator || _isSelf(participant)) {
      return const [];
    }
    final moderation = switch (participant.role) {
      ParticipantRole.user ||
      ParticipantRole.userSelfJoined ||
      ParticipantRole.guest => const [
        ParticipantAction.promote,
        ParticipantAction.remove,
      ],
      ParticipantRole.moderator ||
      ParticipantRole.guestModerator => const [ParticipantAction.demote],
      // Owners cannot be demoted or removed, and an unknown role means a
      // participant type this build does not understand.
      ParticipantRole.owner || null => const <ParticipantAction>[],
    };
    // A ban is offered wherever a removal is, and only for the actor types the
    // ban endpoint accepts: `BanController::banActor` declares
    // `'users'|'guests'|'emails'|'ip'`, and `ip` is not something the attendee
    // list can name.
    final bannable =
        _canBan &&
        moderation.contains(ParticipantAction.remove) &&
        bannedActorTypeFor(participant.actorType) != null;
    return [...moderation, if (bannable) ParticipantAction.ban];
  }

  Future<void> _runParticipantAction(
    Participant participant,
    ParticipantAction action,
  ) async {
    if (action == ParticipantAction.ban) {
      return _ban(participant);
    }
    return _moderate(participant, switch (action) {
      ParticipantAction.promote => ParticipantModerationAction.promote,
      ParticipantAction.demote => ParticipantModerationAction.demote,
      ParticipantAction.remove ||
      ParticipantAction.ban => ParticipantModerationAction.remove,
    });
  }

  /// Best-effort self match so a moderator is not offered actions on their own
  /// row; the login name is usually the user id, and the server refuses
  /// self-demotion anyway when it is not.
  bool _isSelf(Participant participant) {
    return participant.actorType == 'users' &&
        participant.actorId == widget.account.loginName;
  }
}
