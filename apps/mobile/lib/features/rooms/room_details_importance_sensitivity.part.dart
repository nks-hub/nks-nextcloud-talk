part of 'room_details_screen.dart';

mixin _RoomImportanceSensitivityStateLogic
    on ConsumerState<RoomDetailsScreen>, _RoomDetailsStateLogic {
  bool get _canSetImportant =>
      _room != null && _talkFeatures.contains(_importantCapability);

  bool get _canSetSensitive =>
      _room != null && _talkFeatures.contains(_sensitiveCapability);

  bool get _isClassified {
    final attributes = _room?.wire['attributes'];
    return attributes is int &&
        (attributes & _classifiedRoomAttribute) == _classifiedRoomAttribute;
  }

  Future<void> _toggleImportant(bool important) async {
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .setImportant(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            important: important,
          );
      if (mounted) {
        setState(() => _room = room);
      }
    });
  }

  Future<void> _toggleSensitive(bool sensitive) async {
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .setSensitive(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            sensitive: sensitive,
          );
      if (mounted) {
        setState(() => _room = room);
      }
    }, errorMessage: _sensitiveErrorMessage);
  }
}

String _sensitiveErrorMessage(
  AppLocalizations strings,
  RoomSettingsError code,
) => code == RoomSettingsError.rejected
    ? strings.roomDetailsSensitiveRejected
    : _actionErrorMessage(strings, code);
