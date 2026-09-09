part of 'room_details_screen.dart';

extension _RoomDetailsUnbindState on _RoomDetailsStateLogic {
  /// Offered only where the server takes it: a moderator, the
  /// `unbind-conversation` capability, and one of the bindings the endpoint
  /// accepts. Every other conversation — an ordinary one, a persistent phone
  /// room, `note_to_self`, a breakout room — is refused with
  /// `400 object-type`, so the action is not shown for them at all.
  bool get _canUnbindConversation =>
      _isModerator &&
      _talkFeatures.contains(_unbindConversationCapability) &&
      unbindableObjectTypes.contains(_objectTypeOf(widget.conversation));

  Future<void> _unbindConversation() async {
    if (_busy) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final confirmed = await _confirm(
      key: 'room-details-unbind-confirm',
      confirmKey: 'room-details-unbind-confirm-action',
      title: (strings) => strings.roomDetailsUnbindAction,
      message: (strings) => strings.roomDetailsUnbindConfirm,
      confirmLabel: (strings) => strings.roomDetailsUnbindAction,
    );
    if (!confirmed || !mounted) {
      return;
    }
    _setBusy(true);
    try {
      final remaining = await ref
          .read(roomSettingsServiceProvider)
          .unbindConversation(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            objectType: _objectTypeOf(widget.conversation),
          );
      if (mounted) {
        // A temporary phone room does not become an ordinary conversation; it
        // becomes a persistent one. Saying "kept" for both would be a lie in
        // one of the two cases.
        _showMessage(
          remaining.isEmpty
              ? strings.roomDetailsUnbindDone
              : strings.roomDetailsUnbindKeptAsPhoneRoom,
        );
      }
    } on RoomSettingsException catch (error) {
      if (mounted) {
        _showMessage(_actionErrorMessage(strings, error.code));
      }
    } finally {
      if (mounted) {
        _setBusy(false);
      }
    }
  }
}

String _objectTypeOf(CachedConversation conversation) {
  return conversation.objectType;
}
