part of 'room_details_screen.dart';

final class _RoomSummary extends StatelessWidget {
  const _RoomSummary({
    required this.account,
    required this.conversation,
    required this.displayName,
    required this.description,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// The live name and description, which may already reflect a rename or
  /// description edit made in this screen; [conversation] itself never
  /// changes for the lifetime of the widget.
  final String displayName;
  final String description;

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
                  displayName,
                  key: const Key('room-details-name'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          if (description.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            _InfoRow(
              label: strings.roomDetailsDescriptionLabel,
              value: description,
            ),
          ],
          const SizedBox(height: 12),
          _InfoRow(
            label: strings.roomDetailsTypeLabel,
            value: _roomTypeLabel(strings, conversation.roomType),
          ),
          const SizedBox(height: 12),
          _InfoRow(
            label: strings.roomDetailsReadOnlyLabel,
            value: conversation.readOnly != 0
                ? strings.roomDetailsReadOnlyYes
                : strings.roomDetailsReadOnlyNo,
          ),
        ],
      ),
    );
  }
}

final class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

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
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
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
  const _AvatarChoice.emoji(this.emoji) : pickImage = false;
  const _AvatarChoice.image() : emoji = null, pickImage = true;

  final String? emoji;
  final bool pickImage;
}

/// Picks an emoji or a picture as the conversation avatar.
final class _AvatarDialog extends StatefulWidget {
  const _AvatarDialog({required this.strings});

  final AppLocalizations strings;

  @override
  State<_AvatarDialog> createState() => _AvatarDialogState();
}

final class _AvatarDialogState extends State<_AvatarDialog> {
  String _selected = _avatarEmoji.first;

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('room-details-avatar-dialog'),
      title: Text(strings.roomDetailsAvatarDialogTitle),
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-avatar-save'),
          onPressed: () =>
              Navigator.of(context).pop(_AvatarChoice.emoji(_selected)),
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
