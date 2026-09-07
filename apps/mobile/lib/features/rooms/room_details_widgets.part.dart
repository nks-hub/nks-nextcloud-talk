part of 'room_details_screen.dart';

final class _RoomSummary extends StatelessWidget {
  const _RoomSummary({required this.account, required this.conversation});

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: ConversationAvatar(
                  account: account,
                  conversation: conversation,
                  radius: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  conversation.displayName,
                  key: const Key('room-details-name'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          if (conversation.description.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            _InfoRow(
              label: strings.roomDetailsDescriptionLabel,
              value: conversation.description,
            ),
          ],
          const SizedBox(height: 12),
          _InfoRow(
            label: strings.roomDetailsTypeLabel,
            value: _roomTypeLabel(strings, conversation.roomType),
            valueKey: const Key('room-details-summary-type'),
          ),
          const SizedBox(height: 12),
          _InfoRow(
            label: strings.roomDetailsReadOnlyLabel,
            value: conversation.readOnly != 0
                ? strings.roomDetailsReadOnlyYes
                : strings.roomDetailsReadOnlyNo,
            valueKey: const Key('room-details-summary-read-only'),
          ),
        ],
      ),
    );
  }
}

final class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        Text(
          value,
          key: valueKey,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

final class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.account,
    required this.participant,
    required this.actions,
    required this.onAction,
  });

  final StoredAccount account;
  final Participant participant;

  /// Moderation actions to offer for this attendee; empty for anyone the
  /// signed-in account may not moderate, which hides the menu entirely.
  final List<ParticipantAction> actions;
  final void Function(ParticipantAction)? onAction;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final online = participant.status == 'online';
    return ListTile(
      key: Key('room-participant-${participant.attendeeId}'),
      leading: ExcludeSemantics(
        child: ChatParticipantAvatar(
          account: account,
          actorType: participant.actorType,
          actorId: participant.actorId,
          displayName: participant.displayName,
        ),
      ),
      title: Text(participant.displayName),
      subtitle: Text(_roleLabel(strings, participant.role)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (participant.status != null)
            Icon(
              Icons.circle,
              size: 10,
              color: online ? Colors.green : scheme.outline,
              semanticLabel: online
                  ? strings.presenceOnline
                  : participant.status,
            ),
          if (actions.isNotEmpty)
            PopupMenuButton<ParticipantAction>(
              key: Key('room-participant-menu-${participant.attendeeId}'),
              tooltip: strings.roomDetailsParticipantActionsTooltip,
              enabled: onAction != null,
              onSelected: onAction,
              itemBuilder: (context) => [
                for (final action in actions)
                  PopupMenuItem(
                    key: Key(
                      'room-participant-${participant.attendeeId}-'
                      '${action.name}',
                    ),
                    value: action,
                    child: Text(_moderationActionLabel(strings, action)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Asks for a new conversation password.
///
/// Stateful so the dialog itself owns the controller and disposes it: the
/// field holds a secret, and a controller outliving its dialog would keep it
/// in memory after the dialog is gone.
final class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.strings});

  final AppLocalizations strings;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

final class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _obscured = true;

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      key: const Key('room-details-password-dialog'),
      title: Text(strings.roomDetailsPasswordDialogTitle),
      // Large text can make the body taller than the screen; without this
      // the actions are pushed off the bottom and the dialog cannot be
      // answered at all.
      scrollable: true,
      content: TextField(
        key: const Key('room-details-password-field'),
        controller: _controller,
        autofocus: true,
        obscureText: _obscured,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: strings.roomDetailsPasswordFieldLabel,
          suffixIcon: IconButton(
            key: const Key('room-details-password-reveal'),
            icon: Icon(
              _obscured
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
            onPressed: () => setState(() => _obscured = !_obscured),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-password-save'),
          onPressed: () {
            final value = _controller.text;
            // An empty value would silently clear the protection instead of
            // setting one; that is what the separate removal action is for.
            if (value.isEmpty) {
              Navigator.of(context).pop();
              return;
            }
            Navigator.of(context).pop(value);
          },
          child: Text(strings.roomDetailsSave),
        ),
      ],
    );
  }
}

/// What the lobby dialog answers with: the lobby goes on, optionally with the
/// moment it lifts itself.
final class _LobbyChoice {
  const _LobbyChoice({this.timerSecondsSinceEpoch});

  final int? timerSecondsSinceEpoch;
}

/// Turns the lobby on, with an optional end time.
final class _LobbyDialog extends StatefulWidget {
  const _LobbyDialog({required this.strings, required this.now});

  final AppLocalizations strings;
  final DateTime now;

  @override
  State<_LobbyDialog> createState() => _LobbyDialogState();
}

final class _LobbyDialogState extends State<_LobbyDialog> {
  DateTime? _until;

  Future<void> _pick() async {
    final date = await showDatePicker(
      context: context,
      initialDate: widget.now.add(const Duration(hours: 1)),
      firstDate: widget.now,
      lastDate: widget.now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(widget.now),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _until = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final until = _until;
    return AlertDialog(
      key: const Key('room-details-lobby-dialog'),
      title: Text(strings.roomDetailsLobbyDialogTitle),
      // Large text can make the body taller than the screen; without this
      // the actions are pushed off the bottom and the dialog cannot be
      // answered at all.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.roomDetailsLobbyDialogMessage),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('room-details-lobby-timer'),
            icon: const Icon(Icons.schedule),
            label: Text(
              until == null
                  ? strings.roomDetailsLobbyTimerPick
                  : _formatLobbyTimer(until.millisecondsSinceEpoch ~/ 1000),
            ),
            onPressed: _pick,
          ),
          if (until != null)
            TextButton(
              key: const Key('room-details-lobby-timer-clear'),
              onPressed: () => setState(() => _until = null),
              child: Text(strings.roomDetailsLobbyTimerNone),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-lobby-confirm'),
          onPressed: () => Navigator.of(context).pop(
            _LobbyChoice(
              // A timer in the past would be refused by the server, so it is
              // simply dropped and the lobby stays on until switched off.
              timerSecondsSinceEpoch: until != null && until.isAfter(widget.now)
                  ? until.millisecondsSinceEpoch ~/ 1000
                  : null,
            ),
          ),
          child: Text(strings.roomDetailsLobbyDialogConfirm),
        ),
      ],
    );
  }
}

/// What the avatar dialog answers with: either a picked emoji, or a request
/// to open the gallery instead.
final class _AvatarChoice {
  const _AvatarChoice.emoji(this.emoji, {this.hexColor}) : pickImage = false;
  const _AvatarChoice.image() : emoji = null, hexColor = null, pickImage = true;

  final String? emoji;

  /// Six hex digits without the leading `#`, or null for the server's own
  /// bright/dark-mode default. The contract validates the shape.
  final String? hexColor;
  final bool pickImage;
}

/// Background colours offered for an emoji avatar.
///
/// Six digits without `#`, which is the shape Talk documents. The first entry
/// is null on purpose: leaving the colour out lets the server pick the one
/// that follows the reader's bright or dark mode, which is a better default
/// than any fixed choice here.
const List<String?> _avatarColors = <String?>[
  null,
  '0082C9',
  '4CAF50',
  'FFB300',
  'E64A19',
  '8E24AA',
];

/// Picks an emoji or a picture as the conversation avatar.
final class _AvatarDialog extends StatefulWidget {
  const _AvatarDialog({required this.strings});

  final AppLocalizations strings;

  @override
  State<_AvatarDialog> createState() => _AvatarDialogState();
}

final class _AvatarDialogState extends State<_AvatarDialog> {
  String _selected = _avatarEmoji.first;
  String? _color = _avatarColors.first;

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('room-details-avatar-dialog'),
      title: Text(strings.roomDetailsAvatarDialogTitle),
      // Large text can make the body taller than the screen; without this
      // the actions are pushed off the bottom and the dialog cannot be
      // answered at all.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.roomDetailsAvatarDialogMessage),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('room-details-avatar-pick-image'),
            icon: const Icon(Icons.image_outlined),
            label: Text(strings.roomDetailsAvatarPickImage),
            onPressed: () =>
                Navigator.of(context).pop(const _AvatarChoice.image()),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final emoji in _avatarEmoji)
                Semantics(
                  label: strings.roomDetailsAvatarEmojiSemantics(emoji),
                  selected: emoji == _selected,
                  button: true,
                  child: InkWell(
                    key: Key('room-details-avatar-emoji-$emoji'),
                    onTap: () => setState(() => _selected = emoji),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: emoji == _selected
                            ? scheme.primaryContainer
                            : null,
                        border: Border.all(
                          color: emoji == _selected
                              ? scheme.primary
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: ExcludeSemantics(
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 22),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(strings.roomDetailsAvatarColorLabel),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final color in _avatarColors)
                Semantics(
                  label: color == null
                      ? strings.roomDetailsAvatarColorDefault
                      : strings.roomDetailsAvatarColorSemantics(color),
                  selected: color == _color,
                  button: true,
                  child: InkWell(
                    key: Key('room-details-avatar-color-${color ?? 'default'}'),
                    onTap: () => setState(() => _color = color),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: color == null
                            ? null
                            : Color(int.parse('FF$color', radix: 16)),
                        border: Border.all(
                          color: color == _color
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: color == _color ? 3 : 1,
                        ),
                      ),
                      child: color == null
                          ? const ExcludeSemantics(
                              child: Icon(Icons.brightness_auto_rounded),
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-avatar-save'),
          onPressed: () => Navigator.of(
            context,
          ).pop(_AvatarChoice.emoji(_selected, hexColor: _color)),
          child: Text(strings.roomDetailsAvatarSetAction),
        ),
      ],
    );
  }
}

/// Confirms a ban and collects the optional moderator-only note.
final class _BanDialog extends StatefulWidget {
  const _BanDialog({required this.strings, required this.displayName});

  final AppLocalizations strings;
  final String displayName;

  @override
  State<_BanDialog> createState() => _BanDialogState();
}

final class _BanDialogState extends State<_BanDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      key: const Key('room-details-ban-dialog'),
      title: Text(strings.roomDetailsBanDialogTitle),
      // Large text can make the body taller than the screen; without this
      // the actions are pushed off the bottom and the dialog cannot be
      // answered at all.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.roomDetailsBanDialogMessage(widget.displayName)),
          const SizedBox(height: 16),
          TextField(
            key: const Key('room-details-ban-note-field'),
            controller: _controller,
            maxLength: banNoteMaximumLength,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(
              labelText: strings.roomDetailsBanNoteLabel,
              counterText: '',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-ban-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(strings.roomDetailsBanDialogConfirm),
        ),
      ],
    );
  }
}

/// Lists the bans on a conversation and lifts them one at a time.
final class _BansDialog extends ConsumerStatefulWidget {
  const _BansDialog({required this.account, required this.roomToken});

  final StoredAccount account;
  final String roomToken;

  @override
  ConsumerState<_BansDialog> createState() => _BansDialogState();
}

final class _BansDialogState extends ConsumerState<_BansDialog> {
  late Future<List<RoomBan>> _bans;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bans = _load();
  }

  Future<List<RoomBan>> _load() {
    return ref
        .read(participantsServiceProvider)
        .fetchBans(accountId: widget.account.id, roomToken: widget.roomToken);
  }

  Future<void> _unban(RoomBan ban) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(participantsServiceProvider)
          .unbanActor(
            accountId: widget.account.id,
            roomToken: widget.roomToken,
            banId: ban.id,
          );
    } on ParticipantsServiceException {
      // The reload below is what tells the moderator whether it worked; a
      // dialog on top of a dialog would only get in the way.
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _bans = _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('room-details-bans-dialog'),
      title: Text(strings.roomDetailsBansDialogTitle),
      content: SizedBox(
        width: 320,
        child: FutureBuilder<List<RoomBan>>(
          future: _bans,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  // A bounded indicator: an indeterminate one never settles,
                  // which would hang every pumpAndSettle in this tree.
                  child: CircularProgressIndicator(value: 0),
                ),
              );
            }
            if (snapshot.hasError) {
              return Text(strings.roomDetailsBansLoadError);
            }
            final bans = snapshot.data ?? const <RoomBan>[];
            if (bans.isEmpty) {
              return Text(strings.roomDetailsBansEmpty);
            }
            return ListView(
              shrinkWrap: true,
              children: [
                for (final ban in bans)
                  ListTile(
                    key: Key('room-ban-${ban.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(ban.bannedDisplayName),
                    subtitle: ban.internalNote.isEmpty
                        ? null
                        : Text(ban.internalNote),
                    trailing: TextButton(
                      key: Key('room-ban-${ban.id}-lift'),
                      onPressed: _busy ? null : () => _unban(ban),
                      child: Text(strings.roomDetailsUnbanAction),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const Key('room-details-bans-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.close),
        ),
      ],
    );
  }
}

final class _ParticipantsError extends StatelessWidget {
  const _ParticipantsError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(strings.roomDetailsLoadError),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('room-details-retry'),
            onPressed: onRetry,
            child: Text(strings.retry),
          ),
        ],
      ),
    );
  }
}

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

/// Search for somebody to add, and pick them.
///
/// Debounced by hand rather than through a package: one field, one request in
/// flight, and a query that changed while a request was out wins over its
/// answer.
final class _AddParticipantDialog extends StatefulWidget {
  const _AddParticipantDialog({
    required this.accountId,
    required this.roomToken,
    required this.search,
  });

  final String accountId;
  final String roomToken;
  final Future<List<ParticipantCandidate>> Function(String query) search;

  @override
  State<_AddParticipantDialog> createState() => _AddParticipantDialogState();
}

final class _AddParticipantDialogState extends State<_AddParticipantDialog> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  bool _searching = false;
  List<ParticipantCandidate> _results = const <ParticipantCandidate>[];
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    unawaited(_run(''));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_run(_controller.text.trim())),
    );
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _failed = false;
    });
    List<ParticipantCandidate> found;
    var failed = false;
    try {
      found = await widget.search(query);
    } on Object {
      found = const <ParticipantCandidate>[];
      failed = true;
    }
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _results = found;
      _searching = false;
      _failed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('add-participant-dialog'),
      title: Text(strings.roomDetailsAddParticipantTitle),
      content: SizedBox(
        width: 400,
        height: 360,
        child: Column(
          children: [
            TextField(
              key: const Key('add-participant-search'),
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: strings.roomDetailsAddParticipantSearch,
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _searching
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        _failed
                            ? strings.roomDetailsAddParticipantEmpty
                            : strings.roomDetailsAddParticipantEmpty,
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final candidate = _results[index];
                        return ListTile(
                          key: Key('add-participant-${candidate.id}'),
                          leading: Icon(switch (candidate.source) {
                            AddParticipantSource.groups => Icons.group_rounded,
                            AddParticipantSource.circles =>
                              Icons.circle_outlined,
                            AddParticipantSource.emails =>
                              Icons.mail_outline_rounded,
                            AddParticipantSource.federatedUsers =>
                              Icons.cloud_outlined,
                            AddParticipantSource.phones => Icons.phone_rounded,
                            AddParticipantSource.users => Icons.person_rounded,
                          }),
                          title: Text(candidate.label),
                          onTap: () => Navigator.of(context).pop(candidate),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.of(context).cancel),
        ),
      ],
    );
  }
}
