part of 'room_details_screen.dart';

final class _MessageExpirationOption {
  const _MessageExpirationOption(this.seconds);

  final int seconds;
}

/// The exact choices offered by Talk's official web client at upstream
/// `f2958bb25be6604240c58a3faf9a2033a30d20e5`.
const List<_MessageExpirationOption> _messageExpirationOptions = [
  _MessageExpirationOption(3600),
  _MessageExpirationOption(28800),
  _MessageExpirationOption(86400),
  _MessageExpirationOption(604800),
  _MessageExpirationOption(2419200),
  _MessageExpirationOption(0),
];

String _messageExpirationLabel(AppLocalizations strings, int seconds) {
  return switch (seconds) {
    0 => strings.roomDetailsMessageExpirationOff,
    3600 => strings.roomDetailsMessageExpirationOneHour,
    28800 => strings.roomDetailsMessageExpirationEightHours,
    86400 => strings.roomDetailsMessageExpirationOneDay,
    604800 => strings.roomDetailsMessageExpirationOneWeek,
    2419200 => strings.roomDetailsMessageExpirationFourWeeks,
    _ => strings.roomDetailsMessageExpirationCustom(seconds),
  };
}

String _messageExpirationErrorMessage(
  AppLocalizations strings,
  RoomSettingsError code,
) {
  return code == RoomSettingsError.rejected
      ? strings.roomDetailsMessageExpirationRejected
      : _actionErrorMessage(strings, code);
}

extension _RoomDetailsMessageExpirationState on _RoomDetailsScreenState {
  bool get _canSetMessageExpiration =>
      _isModerator &&
      _roomType != _roomTypeFormerOneToOne &&
      _talkFeatures.contains(_messageExpirationCapability);

  int get _messageExpirationSeconds {
    final value = _room?.wire['messageExpiration'];
    return value is int && value >= 0 ? value : 0;
  }

  Future<void> _changeMessageExpiration() async {
    final strings = AppLocalizations.of(context);
    final selected = await showDialog<_MessageExpirationOption>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const Key('room-details-message-expiration-dialog'),
        title: Text(strings.roomDetailsMessageExpirationDialogTitle),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(strings.roomDetailsMessageExpirationHint),
          ),
          for (final option in _messageExpirationOptions)
            SimpleDialogOption(
              key: Key('room-details-message-expiration-${option.seconds}'),
              onPressed: () => Navigator.of(dialogContext).pop(option),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: option.seconds == _messageExpirationSeconds
                        ? const Icon(Icons.check, size: 20)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(_messageExpirationLabel(strings, option.seconds)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setMessageExpiration(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            seconds: selected.seconds,
          ),
      fallback: () => {'messageExpiration': selected.seconds},
      errorMessage: _messageExpirationErrorMessage,
    );
  }
}
