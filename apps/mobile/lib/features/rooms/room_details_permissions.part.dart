part of 'room_details_screen.dart';

mixin _RoomPermissionStateLogic
    on ConsumerState<RoomDetailsScreen>, _RoomDetailsStateLogic {
  Completer<void>? _permissionAbort;
  var _permissionEpoch = 0;

  bool get _permissionRoomEligible =>
      _room != null && _isGroupOrPublic && !_room!.isFederated;

  bool get _canEditDefaultPermissions =>
      _permissionRoomEligible &&
      _room?.objectType != _breakoutObjectType &&
      const {1, 2, 6}.contains(_room?.participantType) &&
      _talkFeatures.contains(_conversationPermissionsCapability);

  bool get _canEditMentionPermissions =>
      _permissionRoomEligible &&
      _room?.objectType != _breakoutObjectType &&
      const {1, 2}.contains(_room?.participantType) &&
      _talkFeatures.contains(_mentionPermissionsCapability);

  bool _canEditParticipantPermissions(Participant participant) =>
      _permissionRoomEligible &&
      const {1, 2, 6}.contains(_room?.participantType) &&
      _talkFeatures.contains(_publishingPermissionsCapability) &&
      const {3, 4, 5}.contains(participant.participantType) &&
      participant.actorId.isNotEmpty &&
      const {
        'users',
        'guests',
        'emails',
        'phones',
        'federated_users',
      }.contains(participant.actorType);

  @override
  void didUpdateWidget(covariant RoomDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.conversation.token != widget.conversation.token) {
      _cancelPermissionEdit();
      _busy = false;
    }
  }

  void _cancelPermissionEdit() {
    _permissionEpoch++;
    final abort = _permissionAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _permissionAbort = null;
  }

  @override
  void dispose() {
    _cancelPermissionEdit();
    super.dispose();
  }

  Future<void> _editDefaultPermissions() =>
      _editPermissions(PermissionEditKind.roomDefault);

  Future<void> _editMentionPermissions() =>
      _editPermissions(PermissionEditKind.mentions);

  Future<void> _editParticipantPermissions(Participant participant) =>
      _editPermissions(PermissionEditKind.attendee, participant: participant);

  Future<void> _editPermissions(
    PermissionEditKind kind, {
    Participant? participant,
  }) async {
    if (_busy) return;
    final accountId = widget.account.id;
    final roomToken = widget.conversation.token;
    final epoch = _permissionEpoch;
    final abort = Completer<void>();
    _permissionAbort = abort;
    bool current() =>
        mounted &&
        epoch == _permissionEpoch &&
        widget.account.id == accountId &&
        widget.conversation.token == roomToken;

    try {
      await _runAction(() async {
        final service = ref.read(roomSettingsServiceProvider);
        final edit = await service.preparePermissionEdit(
          accountId: accountId,
          roomToken: roomToken,
          kind: kind,
          attendeeId: participant?.attendeeId,
          abortTrigger: abort.future,
          isCurrent: current,
        );
        if (!current()) return;
        final value = await showDialog<int>(
          context: context,
          builder: (_) => _PermissionEditorDialog(edit: edit),
        );
        if (value == null || !current()) return;
        if (kind == PermissionEditKind.roomDefault &&
            !await _confirmPermissionChange(
              dialogKey: 'room-details-permission-reset-dialog',
              confirmKey: 'room-details-permission-reset-confirm',
              title: (s) => s.roomDetailsPermissionResetTitle,
              message: (s) => s.roomDetailsPermissionResetMessage,
              confirm: (s) => s.roomDetailsPermissionResetConfirm,
            )) {
          return;
        }
        if (edit.makesRegularMember &&
            !await _confirmPermissionChange(
              dialogKey: 'room-details-permission-membership-dialog',
              confirmKey: 'room-details-permission-membership-confirm',
              title: (s) => s.roomDetailsPermissionMembershipTitle,
              message: (s) => s.roomDetailsPermissionMembershipMessage,
              confirm: (s) => s.roomDetailsPermissionMembershipConfirm,
            )) {
          return;
        }
        if (!current()) return;
        final result = await service.applyPermissionEdit(
          edit: edit,
          value: value,
          confirmResetOverrides: kind == PermissionEditKind.roomDefault,
          confirmRegularMembership: edit.makesRegularMember,
          abortTrigger: abort.future,
          isCurrent: current,
        );
        if (!current()) return;
        setState(() {
          _room = result.room;
          _participants = Future<List<Participant>>.value(result.participants);
        });
      }, errorMessage: _permissionErrorMessage);
    } finally {
      if (identical(_permissionAbort, abort)) _permissionAbort = null;
    }
  }

  Future<bool> _confirmPermissionChange({
    required String dialogKey,
    required String confirmKey,
    required String Function(AppLocalizations) title,
    required String Function(AppLocalizations) message,
    required String Function(AppLocalizations) confirm,
  }) async {
    if (!mounted) return false;
    final strings = AppLocalizations.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: Key(dialogKey),
        title: Text(title(strings)),
        content: Text(message(strings)),
        actions: [
          TextButton(
            key: Key('$dialogKey-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: Key(confirmKey),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirm(strings)),
          ),
        ],
      ),
    );
    return accepted == true && mounted;
  }
}

final class _PermissionEditorDialog extends StatefulWidget {
  const _PermissionEditorDialog({required this.edit});

  final RoomPermissionEdit edit;

  @override
  State<_PermissionEditorDialog> createState() =>
      _PermissionEditorDialogState();
}

final class _PermissionEditorDialogState
    extends State<_PermissionEditorDialog> {
  late bool _inherits;
  late int _mask;
  late int _mentionValue;

  RoomPermissionEdit get _edit => widget.edit;
  RoomPermissionPolicy get _policy => _edit.policy;

  @override
  void initState() {
    super.initState();
    _inherits =
        _edit.kind == PermissionEditKind.attendee && _edit.initialValue == 0;
    _mentionValue = _policy.forcedMentions ?? _edit.initialValue;
    final forced = _policy.forcedPermissions;
    final effective = _edit.target?.permissions ?? _edit.initialValue;
    _mask =
        forced ??
        (_inherits ? normalizePermissionSet(effective) : _edit.initialValue);
  }

  int get _value => switch (_edit.kind) {
    PermissionEditKind.mentions => _mentionValue,
    PermissionEditKind.attendee => _inherits ? 0 : _mask | 1,
    PermissionEditKind.roomDefault => _mask,
  };

  bool get _maskManaged => _policy.forcedPermissions != null;

  String _title(AppLocalizations strings) => switch (_edit.kind) {
    PermissionEditKind.roomDefault =>
      strings.roomDetailsDefaultPermissionsAction,
    PermissionEditKind.mentions => strings.roomDetailsMentionPermissionsAction,
    PermissionEditKind.attendee =>
      strings.roomDetailsParticipantPermissionsTitle(_edit.target!.displayName),
  };

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('room-details-permission-editor'),
      scrollable: true,
      title: Text(_title(strings)),
      content: switch (_edit.kind) {
        PermissionEditKind.mentions => _mentionEditor(strings),
        PermissionEditKind.roomDefault ||
        PermissionEditKind.attendee => _maskEditor(strings),
      },
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('room-details-permission-save'),
          onPressed: () => Navigator.of(context).pop(_value),
          child: Text(strings.roomDetailsSave),
        ),
      ],
    );
  }

  Widget _mentionEditor(AppLocalizations strings) {
    final forced = _policy.forcedMentions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (forced != null)
          Text(
            strings.roomDetailsPermissionManaged,
            key: const Key('room-details-permission-managed'),
          ),
        RadioGroup<int>(
          groupValue: _mentionValue,
          onChanged: (value) {
            if (forced == null) {
              setState(() => _mentionValue = value ?? 0);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<int>(
                key: const Key('room-details-mention-everyone'),
                contentPadding: EdgeInsets.zero,
                value: 0,
                enabled: forced == null,
                title: Text(strings.roomDetailsMentionEveryone),
              ),
              RadioListTile<int>(
                key: const Key('room-details-mention-moderators'),
                contentPadding: EdgeInsets.zero,
                value: 1,
                enabled: forced == null,
                title: Text(strings.roomDetailsMentionModerators),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _maskEditor(AppLocalizations strings) {
    final attendee = _edit.kind == PermissionEditKind.attendee;
    final maximum = attendee ? _policy.maximumCustom : _policy.maximumDefault;
    final controls = <ConversationPermission>[
      for (final permission in ConversationPermission.values)
        if (maximum & permission.bit != 0 &&
            (permission != ConversationPermission.chat ||
                _policy.canEditChat) &&
            (permission != ConversationPermission.react ||
                _policy.canEditReactions))
          permission,
    ];
    final disabledCalls = !_policy.callsEnabled;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (attendee)
          RadioGroup<bool>(
            key: const Key('room-details-permission-mode'),
            groupValue: _inherits,
            onChanged: (value) {
              if (value != false || _policy.forcedPermissions != 0) {
                setState(() => _inherits = value ?? _inherits);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<bool>(
                  key: const Key('room-details-permission-inherit'),
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  title: Text(strings.roomDetailsPermissionInherit),
                ),
                RadioListTile<bool>(
                  key: const Key('room-details-permission-custom'),
                  contentPadding: EdgeInsets.zero,
                  value: false,
                  enabled: _policy.forcedPermissions != 0,
                  title: Text(strings.roomDetailsPermissionCustom),
                ),
              ],
            ),
          ),
        if (_maskManaged)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              strings.roomDetailsPermissionManaged,
              key: const Key('room-details-permission-managed'),
            ),
          ),
        if (disabledCalls)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(strings.roomDetailsPermissionCallsDisabled),
          ),
        for (final permission in controls)
          CheckboxListTile(
            key: Key('room-details-permission-${permission.name}'),
            contentPadding: EdgeInsets.zero,
            value: _mask & permission.bit != 0,
            onChanged:
                _inherits ||
                    _maskManaged ||
                    (disabledCalls && _isCallPermission(permission))
                ? null
                : (enabled) => setState(() {
                    if (enabled == true) {
                      _mask |= permission.bit;
                    } else {
                      _mask &= ~permission.bit;
                    }
                    if (attendee) _mask |= 1;
                  }),
            title: Text(_permissionLabel(strings, permission)),
          ),
        if (controls.isEmpty) Text(strings.newConversationPermissionsNone),
      ],
    );
  }
}

bool _isCallPermission(ConversationPermission permission) =>
    switch (permission) {
      ConversationPermission.startCall ||
      ConversationPermission.joinCall ||
      ConversationPermission.bypassLobby ||
      ConversationPermission.publishAudio ||
      ConversationPermission.publishVideo ||
      ConversationPermission.publishScreen => true,
      ConversationPermission.chat || ConversationPermission.react => false,
    };

String _permissionLabel(
  AppLocalizations strings,
  ConversationPermission permission,
) => switch (permission) {
  ConversationPermission.startCall =>
    strings.newConversationPermissionStartCalls,
  ConversationPermission.joinCall => strings.newConversationPermissionJoinCalls,
  ConversationPermission.bypassLobby =>
    strings.newConversationPermissionIgnoreLobby,
  ConversationPermission.publishAudio => strings.newConversationPermissionAudio,
  ConversationPermission.publishVideo => strings.newConversationPermissionVideo,
  ConversationPermission.publishScreen =>
    strings.newConversationPermissionScreen,
  ConversationPermission.chat => strings.newConversationPermissionChat,
  ConversationPermission.react => strings.newConversationPermissionReact,
};

String _permissionErrorMessage(
  AppLocalizations strings,
  RoomSettingsError code,
) => switch (code) {
  RoomSettingsError.rejected => strings.roomDetailsPermissionChangeRejected,
  RoomSettingsError.preconditionFailed =>
    strings.roomDetailsPermissionPolicyChanged,
  _ => _actionErrorMessage(strings, code),
};
