part of 'room_details_screen.dart';

mixin _RoomPublicStateLogic
    on ConsumerState<RoomDetailsScreen>, _RoomDetailsStateLogic {
  Completer<void>? _publicAbort;
  var _publicEpoch = 0;

  @override
  void didUpdateWidget(covariant RoomDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.conversation.token != widget.conversation.token) {
      _cancelPublicChange();
      _busy = false;
    }
  }

  void _cancelPublicChange() {
    _publicEpoch++;
    final abort = _publicAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _publicAbort = null;
  }

  @override
  void dispose() {
    _cancelPublicChange();
    super.dispose();
  }

  Future<void> _toggleGuests(bool value) async {
    if (_busy) return;
    final accountId = widget.account.id;
    final token = widget.conversation.token;
    final epoch = _publicEpoch;
    final abort = Completer<void>();
    _publicAbort = abort;
    bool current() =>
        mounted &&
        epoch == _publicEpoch &&
        widget.account.id == accountId &&
        widget.conversation.token == token;
    final strings = AppLocalizations.of(context);
    final service = ref.read(roomSettingsServiceProvider);
    setState(() => _busy = true);
    try {
      if (!value &&
          !await _confirm(
            key: 'room-details-guests-close-dialog',
            confirmKey: 'room-details-guests-close-confirm',
            title: (s) => s.roomDetailsGuestsCloseDialogTitle,
            message: (s) => s.roomDetailsGuestsCloseDialogMessage,
            confirmLabel: (s) => s.roomDetailsGuestsCloseDialogConfirm,
          )) {
        return;
      }
      if (!current()) return;
      final access = await service.preparePublicChange(
        accountId: accountId,
        roomToken: token,
        abortTrigger: abort.future,
        isCurrent: current,
      );
      if (!mounted || !current()) return;
      if ((access.room.type == _roomTypePublic) == value) {
        setState(() => _room = access.room);
        return;
      }
      String? password;
      if (value && access.forcePasswords && !access.supportsPassword) {
        throw const RoomSettingsException(RoomSettingsError.preconditionFailed);
      }
      if (value && access.supportsPassword) {
        password = await showDialog<String>(
          context: context,
          builder: (_) => _PasswordDialog(
            strings: strings,
            allowEmpty: !access.forcePasswords,
            title: strings.roomDetailsPublicPasswordTitle,
            helperText: access.forcePasswords
                ? strings.roomDetailsPublicPasswordRequired
                : access.room.hasPassword
                ? strings.roomDetailsPublicPasswordRetained
                : strings.roomDetailsPublicPasswordOptional,
          ),
        );
        if (password == null || !current()) return;
      }
      final room = await service.setPublic(
        accountId: accountId,
        roomToken: token,
        public: value,
        password: password,
        prepared: access,
        abortTrigger: abort.future,
        isCurrent: current,
      );
      if (current()) setState(() => _room = room);
    } on RoomSettingsException catch (error) {
      if (!current()) return;
      _showMessage(
        error.message ??
            (error.code == RoomSettingsError.preconditionFailed
                ? strings.newConversationPolicyChanged
                : _actionErrorMessage(strings, error.code)),
      );
    } finally {
      if (!abort.isCompleted) abort.complete();
      if (current()) {
        _publicAbort = null;
        setState(() => _busy = false);
      }
    }
  }
}
