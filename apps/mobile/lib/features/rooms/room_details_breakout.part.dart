part of 'room_details_screen.dart';

mixin _RoomBreakoutStateLogic
    on ConsumerState<RoomDetailsScreen>, _RoomDetailsStateLogic {
  @override
  int get _breakoutMode => _wireInt('breakoutRoomMode');
  @override
  int get _breakoutStatus => _wireInt('breakoutRoomStatus');

  /// The parent's breakout rooms, read when the screen opens on a configured
  /// parent and after every breakout action. An assistance request lives on
  /// the child (`breakoutRoomStatus == 2`), so this is the only way the
  /// moderator's screen can show it.
  List<ConversationRoom> _breakoutChildren = const <ConversationRoom>[];

  @override
  Future<void> _loadBreakoutChildren() async {
    if (!_canManageBreakoutRooms || _breakoutMode == 0) {
      if (_breakoutChildren.isNotEmpty && mounted) {
        setState(() => _breakoutChildren = const <ConversationRoom>[]);
      }
      return;
    }
    try {
      final rooms = await ref
          .read(roomSettingsServiceProvider)
          .listBreakoutRooms(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          );
      if (mounted) {
        setState(() => _breakoutChildren = rooms);
      }
    } on Object {
      // The subtitle simply does not mention the children.
    }
  }

  Iterable<ConversationRoom> get _breakoutRoomsAsking => _breakoutChildren
      .where((room) => (room.wire['breakoutRoomStatus'] as int? ?? 0) == 2);

  int _wireInt(String key) {
    final value = _room?.wire[key];
    return value is int ? value : 0;
  }

  String _breakoutLabel(AppLocalizations strings) {
    if (_breakoutMode == 0) {
      return strings.roomDetailsBreakoutNotConfigured;
    }
    final asking = _breakoutRoomsAsking
        .map((room) => room.displayName)
        .toList();
    if (asking.isNotEmpty) {
      return strings.roomDetailsBreakoutAssistanceRequested(asking.join(', '));
    }
    return _breakoutStatus == 0
        ? strings.roomDetailsBreakoutStopped
        : strings.roomDetailsBreakoutStarted;
  }

  Future<void> _manageBreakoutRooms() async {
    await _manageBreakoutRoomsAction();
    await _loadBreakoutChildren();
  }

  Future<void> _manageBreakoutRoomsAction() async {
    final action = await showModalBottomSheet<_BreakoutAction>(
      context: context,
      builder: (sheetContext) => _BreakoutActionsSheet(
        strings: AppLocalizations.of(context),
        configured: _breakoutMode != 0,
        started: _breakoutStatus != 0,
      ),
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case _BreakoutAction.create:
        final plan = await showDialog<_BreakoutPlan>(
          context: context,
          builder: (dialogContext) =>
              _BreakoutAmountDialog(strings: AppLocalizations.of(context)),
        );
        if (plan == null || !mounted) {
          return;
        }
        String? attendeeMap;
        if (plan.mode == BreakoutRoomMode.manual) {
          attendeeMap = await _askAttendeeMap(plan.amount);
          if (attendeeMap == null || !mounted) {
            return;
          }
        }
        await _administer(
          () => ref
              .read(roomSettingsServiceProvider)
              .configureBreakoutRooms(
                accountId: widget.account.id,
                roomToken: widget.conversation.token,
                amount: plan.amount,
                mode: plan.mode,
                attendeeMap: attendeeMap,
              ),
          fallback: () => {
            'breakoutRoomMode': plan.mode.wireValue,
            'breakoutRoomStatus': 0,
          },
        );
      case _BreakoutAction.start:
      case _BreakoutAction.stop:
        final start = action == _BreakoutAction.start;
        await _administer(
          () => ref
              .read(roomSettingsServiceProvider)
              .runBreakoutRooms(
                accountId: widget.account.id,
                roomToken: widget.conversation.token,
                start: start,
              ),
          fallback: () => {'breakoutRoomStatus': start ? 1 : 0},
        );
      case _BreakoutAction.broadcast:
        final message = await showDialog<String>(
          context: context,
          builder: (dialogContext) =>
              _BreakoutBroadcastDialog(strings: AppLocalizations.of(context)),
        );
        if (message == null || !mounted) {
          return;
        }
        await _runAction(
          () => ref
              .read(roomSettingsServiceProvider)
              .broadcastToBreakoutRooms(
                accountId: widget.account.id,
                roomToken: widget.conversation.token,
                message: message,
              ),
          errorMessage: _actionErrorMessage,
        );
      case _BreakoutAction.remove:
        if (!await _confirm(
          key: 'room-details-breakout-remove-dialog',
          confirmKey: 'room-details-breakout-remove-confirm',
          title: (strings) => strings.roomDetailsBreakoutRemoveDialogTitle,
          message: (strings) => strings.roomDetailsBreakoutRemoveDialogMessage,
          confirmLabel: (strings) =>
              strings.roomDetailsBreakoutRemoveDialogConfirm,
        )) {
          return;
        }
        // The children are already loaded for the "asks for a moderator"
        // subtitle, so the removal can name the rooms it deletes and they
        // leave the list with it instead of lingering until the next sync.
        final removed = [
          for (final child in _breakoutChildren) child.token.value,
        ];
        await _administer(
          () => ref
              .read(roomSettingsServiceProvider)
              .removeBreakoutRooms(
                accountId: widget.account.id,
                roomToken: widget.conversation.token,
                childTokens: removed,
              ),
          fallback: () => {'breakoutRoomMode': 0, 'breakoutRoomStatus': 0},
        );
    }
  }

  /// Asks who goes into which room and encodes the answer the way the server
  /// reads it: a JSON object of attendee id to a ZERO-BASED room number
  /// (`BreakoutRoomService::parseAttendeeForm`). Anybody left unassigned is
  /// simply absent from the map — the server puts them nowhere, which is what
  /// "not assigned" means.
  Future<String?> _askAttendeeMap(int amount) async {
    final List<Participant> participants;
    try {
      participants = await _load();
    } on Object {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).roomDetailsActionErrorGeneric,
        );
      }
      return null;
    }
    if (!mounted) {
      return null;
    }
    final assignment = await showDialog<Map<int, int>>(
      context: context,
      builder: (dialogContext) => _BreakoutAssignDialog(
        strings: AppLocalizations.of(context),
        participants: participants,
        amount: amount,
      ),
    );
    if (assignment == null) {
      return null;
    }
    return jsonEncode(
      assignment.map((attendeeId, room) => MapEntry('$attendeeId', room)),
    );
  }

  Future<void> _switchBreakoutRoom() async {
    final strings = AppLocalizations.of(context);
    final List<ConversationRoom> rooms;
    try {
      rooms = await ref
          .read(roomSettingsServiceProvider)
          .listBreakoutRooms(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          );
    } on RoomSettingsException catch (error) {
      if (mounted) {
        _showMessage(_actionErrorMessage(strings, error.code));
      }
      return;
    } on Object {
      if (mounted) {
        _showMessage(strings.roomDetailsActionErrorGeneric);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    if (rooms.isEmpty) {
      _showMessage(strings.roomDetailsBreakoutSwitchEmpty);
      return;
    }
    final target = await showDialog<ConversationRoom>(
      context: context,
      builder: (dialogContext) =>
          _BreakoutSwitchDialog(strings: strings, rooms: rooms),
    );
    if (target == null || !mounted) {
      return;
    }
    var switched = false;
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .switchBreakoutRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            target: target.token.value,
          );
      switched = true;
    }, errorMessage: _actionErrorMessage);
    if (switched && mounted) {
      _showMessage(strings.roomDetailsBreakoutSwitched(target.displayName));
    }
  }

  Future<void> _toggleBreakoutAssistance() async {
    final requested = _breakoutStatus != 2;
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setBreakoutAssistance(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            requested: requested,
          ),
      fallback: () => {'breakoutRoomStatus': requested ? 2 : 1},
    );
  }
}
