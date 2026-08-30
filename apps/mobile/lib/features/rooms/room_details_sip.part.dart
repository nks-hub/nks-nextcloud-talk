part of 'room_details_screen.dart';

mixin _RoomSipStateLogic
    on ConsumerState<RoomDetailsScreen>, _RoomDetailsStateLogic {
  Future<String>? _sipDialInInstructions;

  @override
  void initState() {
    super.initState();
    _sipDialInInstructions = _showsSipDialIn
        ? _fetchSipDialInInstructions()
        : null;
  }

  /// `canEnableSIP` is calculated by Talk from the server configuration and
  /// the signed-in user's allowed groups. The capability proves the endpoint
  /// exists; both are required and classified rooms stay fail-closed.
  bool get _canSetSip =>
      _isModerator &&
      ((_room?.attributes ?? 0) & _classifiedRoomAttribute) == 0 &&
      (_room?.canEnableSip ?? false) &&
      _talkFeatures.contains(_sipCapability);

  /// Dial-in information belongs to every participant, not only moderators
  /// who may change the mode.
  bool get _showsSipDialIn =>
      _room != null &&
      _sipState != RoomSipState.disabled &&
      _talkFeatures.contains(_sipCapability);

  RoomSipState get _sipState => switch (_room?.sipEnabled ?? 0) {
    1 => RoomSipState.enabledWithPin,
    2 => RoomSipState.enabledWithoutPin,
    _ => RoomSipState.disabled,
  };

  String _sipLabel(AppLocalizations strings) {
    return switch (_sipState) {
      RoomSipState.disabled => strings.roomDetailsSipDisabled,
      RoomSipState.enabledWithPin => strings.roomDetailsSipWithPin,
      RoomSipState.enabledWithoutPin => strings.roomDetailsSipWithoutPin,
    };
  }

  Future<String> _fetchSipDialInInstructions() {
    return ref
        .read(roomSettingsServiceProvider)
        .fetchSipDialInInstructions(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
        );
  }

  void _reloadSipDialInInstructions() {
    if (!_showsSipDialIn) {
      setState(() {
        _sipDialInInstructions = null;
      });
      return;
    }
    final instructions = _fetchSipDialInInstructions();
    setState(() {
      _sipDialInInstructions = instructions;
    });
  }

  Future<void> _changeSip() async {
    final strings = AppLocalizations.of(context);
    final states = <RoomSipState>[
      RoomSipState.disabled,
      RoomSipState.enabledWithPin,
      if (_talkFeatures.contains(_sipNoPinCapability))
        RoomSipState.enabledWithoutPin,
    ];
    final selected = await showDialog<RoomSipState>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const Key('room-details-sip-dialog'),
        title: Text(strings.roomDetailsSipDialogTitle),
        children: [
          for (final state in states)
            SimpleDialogOption(
              key: Key('room-details-sip-${state.name}'),
              onPressed: () => Navigator.of(dialogContext).pop(state),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: state == _sipState
                        ? const Icon(Icons.check, size: 20)
                        : null,
                  ),
                  Expanded(
                    child: Text(switch (state) {
                      RoomSipState.disabled => strings.roomDetailsSipDisabled,
                      RoomSipState.enabledWithPin =>
                        strings.roomDetailsSipWithPin,
                      RoomSipState.enabledWithoutPin =>
                        strings.roomDetailsSipWithoutPin,
                    }),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || selected == _sipState || !mounted) {
      return;
    }

    var changed = false;
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .setSip(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            state: selected,
          );
      if (mounted) {
        setState(() => _room = room);
        changed = true;
      }
    }, errorMessage: _sipErrorMessage);
    if (changed && mounted) {
      _reloadSipDialInInstructions();
    }
  }

  Widget _buildSipDialInPanel(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final pin = _room?.attendeePin?.trim();
    final instructions = _sipDialInInstructions;
    return ListTile(
      key: const Key('room-details-sip-dial-in'),
      leading: const Icon(Icons.phone_in_talk_outlined),
      title: Text(strings.roomDetailsSipDialInHeader),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          FutureBuilder<String>(
            future: instructions,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox.square(
                    key: Key('room-details-sip-instructions-loading'),
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              if (snapshot.hasError) {
                return Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.roomDetailsSipInstructionsLoadError,
                        key: const Key('room-details-sip-instructions-error'),
                      ),
                    ),
                    TextButton(
                      key: const Key('room-details-sip-instructions-retry'),
                      onPressed: _reloadSipDialInInstructions,
                      child: Text(strings.retry),
                    ),
                  ],
                );
              }
              final value = snapshot.data?.trim() ?? '';
              return SelectableText(
                value.isEmpty
                    ? strings.roomDetailsSipInstructionsUnavailable
                    : value,
                key: const Key('room-details-sip-instructions'),
              );
            },
          ),
          const SizedBox(height: 12),
          _SipDialInValue(
            label: strings.roomDetailsSipMeetingId,
            value: _readableSipIdentifier(widget.conversation.token),
            valueKey: const Key('room-details-sip-meeting-id'),
          ),
          if (_sipState == RoomSipState.enabledWithPin) ...[
            const SizedBox(height: 8),
            _SipDialInValue(
              label: strings.roomDetailsSipPersonalPin,
              value: pin == null || pin.isEmpty
                  ? strings.roomDetailsSipPinUnavailable
                  : _readableSipIdentifier(pin),
              valueKey: const Key('room-details-sip-personal-pin'),
            ),
          ],
        ],
      ),
    );
  }
}

final class _SipDialInValue extends StatelessWidget {
  const _SipDialInValue({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        SelectableText(value, key: valueKey),
      ],
    );
  }
}

/// Mirrors Talk's `readableNumber`: groups from the left by three and avoids
/// leaving a single-character final group.
String _readableSipIdentifier(String value) {
  if (value.length <= 3) {
    return value;
  }
  final chunks = <String>[];
  for (var offset = 0; offset < value.length; offset += 3) {
    final end = offset + 3 < value.length ? offset + 3 : value.length;
    chunks.add(value.substring(offset, end));
  }
  if (chunks.last.length == 1 && chunks.length > 1) {
    final last = chunks.removeLast();
    chunks[chunks.length - 1] += last;
  }
  return chunks.join(' ');
}
