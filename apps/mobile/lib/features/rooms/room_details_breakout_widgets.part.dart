part of 'room_details_screen.dart';

enum _BreakoutAction { create, start, stop, broadcast, remove }

/// What a moderator can do with the breakout rooms right now: create them
/// while there are none; start, stop, broadcast to and remove them afterwards.
final class _BreakoutActionsSheet extends StatelessWidget {
  const _BreakoutActionsSheet({
    required this.strings,
    required this.configured,
    required this.started,
  });

  final AppLocalizations strings;
  final bool configured;
  final bool started;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          if (!configured)
            ListTile(
              key: const Key('room-details-breakout-create'),
              leading: const Icon(Icons.add_rounded),
              title: Text(strings.roomDetailsBreakoutCreate),
              onTap: () => Navigator.of(context).pop(_BreakoutAction.create),
            ),
          if (configured && !started)
            ListTile(
              key: const Key('room-details-breakout-start'),
              leading: const Icon(Icons.play_arrow_rounded),
              title: Text(strings.roomDetailsBreakoutStart),
              onTap: () => Navigator.of(context).pop(_BreakoutAction.start),
            ),
          if (configured && started)
            ListTile(
              key: const Key('room-details-breakout-stop'),
              leading: const Icon(Icons.stop_rounded),
              title: Text(strings.roomDetailsBreakoutStop),
              onTap: () => Navigator.of(context).pop(_BreakoutAction.stop),
            ),
          if (configured)
            ListTile(
              key: const Key('room-details-breakout-broadcast'),
              leading: const Icon(Icons.campaign_outlined),
              title: Text(strings.roomDetailsBreakoutBroadcast),
              onTap: () => Navigator.of(context).pop(_BreakoutAction.broadcast),
            ),
          if (configured)
            ListTile(
              key: const Key('room-details-breakout-remove'),
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(strings.roomDetailsBreakoutRemove),
              onTap: () => Navigator.of(context).pop(_BreakoutAction.remove),
            ),
        ],
      ),
    );
  }
}

/// How the breakout rooms are to be filled, and how many there are.
typedef _BreakoutPlan = ({BreakoutRoomMode mode, int amount});

/// How many breakout rooms to create — Talk allows 1 to 20 — and how people
/// end up in them: spread by the server, assigned by the moderator, or picked
/// by the attendees themselves.
final class _BreakoutAmountDialog extends StatefulWidget {
  const _BreakoutAmountDialog({required this.strings});

  final AppLocalizations strings;

  @override
  State<_BreakoutAmountDialog> createState() => _BreakoutAmountDialogState();
}

final class _BreakoutAmountDialogState extends State<_BreakoutAmountDialog> {
  int _amount = 2;
  BreakoutRoomMode _mode = BreakoutRoomMode.automatic;

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      key: const Key('room-details-breakout-create-dialog'),
      // Three radio rows and a title do not fit at 200 % text; without this
      // the buttons leave the screen and the dialog cannot be answered.
      scrollable: true,
      title: Text(strings.roomDetailsBreakoutCreateDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: _amountControls(context),
          ),
          const SizedBox(height: 12),
          RadioGroup<BreakoutRoomMode>(
            groupValue: _mode,
            onChanged: (picked) => setState(() => _mode = picked ?? _mode),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in BreakoutRoomMode.values)
                  RadioListTile<BreakoutRoomMode>(
                    key: Key('room-details-breakout-mode-${mode.name}'),
                    contentPadding: EdgeInsets.zero,
                    value: mode,
                    title: Text(switch (mode) {
                      BreakoutRoomMode.automatic =>
                        strings.roomDetailsBreakoutModeAutomatic,
                      BreakoutRoomMode.manual =>
                        strings.roomDetailsBreakoutModeManual,
                      BreakoutRoomMode.free =>
                        strings.roomDetailsBreakoutModeFree,
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('room-details-breakout-create-confirm'),
          onPressed: () =>
              Navigator.of(context).pop((mode: _mode, amount: _amount)),
          child: Text(strings.roomDetailsBreakoutCreate),
        ),
      ],
    );
  }

  List<Widget> _amountControls(BuildContext context) {
    return [
      IconButton(
        tooltip: AppLocalizations.of(context).roomDetailsBreakoutFewer,
        onPressed: _amount > breakoutRoomsMinimum
            ? () => setState(() => _amount--)
            : null,
        icon: const Icon(Icons.remove_rounded),
      ),
      Text(
        '$_amount',
        key: const Key('room-details-breakout-amount'),
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      IconButton(
        tooltip: AppLocalizations.of(context).roomDetailsBreakoutMore,
        onPressed: _amount < breakoutRoomsMaximum
            ? () => setState(() => _amount++)
            : null,
        icon: const Icon(Icons.add_rounded),
      ),
    ];
  }
}

/// Who goes into which breakout room, in manual mode.
///
/// The answer travels as attendee id to a zero-based room number; anybody the
/// moderator leaves alone is absent from it, which is how the server is told
/// to put them nowhere.
final class _BreakoutAssignDialog extends StatefulWidget {
  const _BreakoutAssignDialog({
    required this.strings,
    required this.participants,
    required this.amount,
  });

  final AppLocalizations strings;
  final List<Participant> participants;
  final int amount;

  @override
  State<_BreakoutAssignDialog> createState() => _BreakoutAssignDialogState();
}

final class _BreakoutAssignDialogState extends State<_BreakoutAssignDialog> {
  final Map<int, int> _assignment = <int, int>{};

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      key: const Key('room-details-breakout-assign-dialog'),
      title: Text(strings.roomDetailsBreakoutAssignTitle),
      content: SizedBox(
        width: 400,
        height: 360,
        child: ListView.builder(
          itemCount: widget.participants.length,
          itemBuilder: (context, index) {
            final participant = widget.participants[index];
            final id = participant.attendeeId;
            return ListTile(
              key: Key('room-details-breakout-assign-\$id'),
              title: Text(participant.displayName),
              trailing: DropdownButton<int?>(
                key: Key('room-details-breakout-assign-room-\$id'),
                value: _assignment[id],
                onChanged: (room) => setState(() {
                  if (room == null) {
                    _assignment.remove(id);
                  } else {
                    _assignment[id] = room;
                  }
                }),
                items: [
                  DropdownMenuItem<int?>(
                    child: Text(strings.roomDetailsBreakoutAssignUnassigned),
                  ),
                  for (var room = 0; room < widget.amount; room++)
                    DropdownMenuItem<int?>(
                      value: room,
                      child: Text(
                        strings.roomDetailsBreakoutAssignRoom(room + 1),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('room-details-breakout-assign-confirm'),
          onPressed: () =>
              Navigator.of(context).pop(Map<int, int>.of(_assignment)),
          child: Text(strings.roomDetailsBreakoutAssignConfirm),
        ),
      ],
    );
  }
}

/// The breakout room to move into, in free mode.
final class _BreakoutSwitchDialog extends StatelessWidget {
  const _BreakoutSwitchDialog({required this.strings, required this.rooms});

  final AppLocalizations strings;
  final List<ConversationRoom> rooms;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('room-details-breakout-switch-dialog'),
      title: Text(strings.roomDetailsBreakoutSwitchTitle),
      content: SizedBox(
        width: 400,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final room in rooms)
              ListTile(
                key: Key('room-details-breakout-switch-${room.token.value}'),
                leading: const Icon(Icons.meeting_room_outlined),
                title: Text(room.displayName),
                onTap: () => Navigator.of(context).pop(room),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ],
    );
  }
}

final class _BreakoutBroadcastDialog extends StatefulWidget {
  const _BreakoutBroadcastDialog({required this.strings});

  final AppLocalizations strings;

  @override
  State<_BreakoutBroadcastDialog> createState() =>
      _BreakoutBroadcastDialogState();
}

final class _BreakoutBroadcastDialogState
    extends State<_BreakoutBroadcastDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      key: const Key('room-details-breakout-broadcast-dialog'),
      scrollable: true,
      title: Text(strings.roomDetailsBreakoutBroadcast),
      content: TextField(
        key: const Key('room-details-breakout-broadcast-field'),
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: breakoutBroadcastMaximumLength,
        decoration: InputDecoration(
          hintText: strings.roomDetailsBreakoutBroadcastHint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('room-details-breakout-broadcast-confirm'),
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isNotEmpty) {
              Navigator.of(context).pop(text);
            }
          },
          child: Text(strings.roomDetailsBreakoutBroadcastSend),
        ),
      ],
    );
  }
}
