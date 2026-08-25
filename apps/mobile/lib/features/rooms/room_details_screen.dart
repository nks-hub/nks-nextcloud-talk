import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_participant_avatar.dart';
import '../conversations/conversation_avatar_widget.dart';
import 'participants_service.dart';
import 'room_settings_service.dart';

const int _roomTypeOneToOne = 1;
const int _roomTypeGroup = 2;
const int _roomTypePublic = 3;
const int _roomTypeChangelog = 4;
const int _roomTypeFormerOneToOne = 5;
const int _roomTypeNoteToSelf = 6;

const int _notificationDefault = 0;
const int _notificationAlways = 1;
const int _notificationMention = 2;
const int _notificationNever = 3;

/// Conversation details: room metadata, the moderator-gated settings
/// actions (rename, description, notification level, favorite, leave) and
/// the participant list with each attendee's role and status.
final class RoomDetailsScreen extends ConsumerStatefulWidget {
  const RoomDetailsScreen({
    super.key,
    required this.account,
    required this.conversation,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  ConsumerState<RoomDetailsScreen> createState() => _RoomDetailsScreenState();
}

final class _RoomDetailsScreenState extends ConsumerState<RoomDetailsScreen> {
  late Future<List<Participant>> _participants;
  late ConversationRoom? _room;
  late bool _isFavorite;
  late int _notificationLevel;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _participants = _load();
    _room = _parseCachedRoom(widget.conversation);
    _isFavorite = widget.conversation.favorite;
    _notificationLevel = _room?.notificationLevel ?? _notificationDefault;
  }

  Future<List<Participant>> _load() {
    return ref
        .read(participantsServiceProvider)
        .fetchParticipants(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
        );
  }

  void _retry() {
    setState(() {
      _participants = _load();
    });
  }

  /// Owners, moderators and guest moderators may rename the conversation and
  /// change its description; a plain participant must never see these.
  bool get _isModerator {
    return switch (participantRoleFor(_room?.participantType ?? -1)) {
      ParticipantRole.owner ||
      ParticipantRole.moderator ||
      ParticipantRole.guestModerator => true,
      _ => false,
    };
  }

  /// The server is the source of truth for whether leaving is currently
  /// allowed (e.g. it is refused for the last moderator); default to hidden
  /// when that could not be determined from the cached room.
  bool get _canLeave => _room?.canLeaveConversation ?? false;

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on RoomSettingsException catch (error) {
      _showActionError(_actionErrorMessage, error.code);
    } on ParticipantsServiceException catch (error) {
      _showActionError(_participantActionErrorMessage, error.code);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showActionError<T>(
    String Function(AppLocalizations, T) message,
    T code,
  ) {
    if (!mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message(strings, code))));
  }

  Future<void> _renameRoom() async {
    final strings = AppLocalizations.of(context);
    final controller = TextEditingController(text: widget.conversation.displayName);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.roomDetailsRenameDialogTitle),
        content: TextField(
          key: const Key('room-details-rename-field'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: strings.roomDetailsRenameFieldLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-rename-save'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.roomDetailsSave),
          ),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty || !mounted) {
      return;
    }
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .renameRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            name: newName,
          );
      if (mounted) {
        setState(() => _room = room);
      }
    });
  }

  Future<void> _editDescription() async {
    final strings = AppLocalizations.of(context);
    final controller = TextEditingController(text: widget.conversation.description);
    final newDescription = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.roomDetailsDescriptionDialogTitle),
        content: TextField(
          key: const Key('room-details-description-field'),
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(labelText: strings.roomDetailsDescriptionFieldLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-description-save'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.roomDetailsSave),
          ),
        ],
      ),
    );
    if (newDescription == null || !mounted) {
      return;
    }
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .updateDescription(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            description: newDescription,
          );
      if (mounted) {
        setState(() => _room = room);
      }
    });
  }

  Future<void> _changeNotificationLevel() async {
    final strings = AppLocalizations.of(context);
    final current = switch (_notificationLevel) {
      _notificationAlways => RoomNotificationLevel.always,
      _notificationMention => RoomNotificationLevel.mentions,
      _notificationNever => RoomNotificationLevel.never,
      _ => null,
    };
    final selected = await showDialog<RoomNotificationLevel>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const Key('room-details-notification-dialog'),
        title: Text(strings.roomDetailsNotificationDialogTitle),
        children: [
          for (final level in RoomNotificationLevel.values)
            SimpleDialogOption(
              key: Key('room-details-notification-${level.name}'),
              onPressed: () => Navigator.of(dialogContext).pop(level),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: level == current ? const Icon(Icons.check, size: 20) : null,
                  ),
                  const SizedBox(width: 8),
                  Text(_notificationLevelLabel(strings, level)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .setNotificationLevel(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            level: selected,
          );
      if (mounted) {
        setState(() => _notificationLevel = selected.wireValue);
      }
    });
  }

  Future<void> _toggleFavorite(bool value) async {
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .setFavorite(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            favorite: value,
          );
      if (mounted) {
        setState(() => _isFavorite = value);
      }
    });
  }

  Future<void> _confirmLeave() async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-leave-dialog'),
        title: Text(strings.roomDetailsLeaveDialogTitle),
        content: Text(strings.roomDetailsLeaveDialogMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-leave-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsLeaveDialogConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    var left = false;
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .leaveRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          );
      left = true;
    });
    if (left && mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Runs a moderation change and refetches the list, because the endpoints
  /// answer with an empty payload and the new roles are only visible after a
  /// reload.
  Future<void> _moderate(
    Participant participant,
    ParticipantModerationAction action,
  ) async {
    if (action == ParticipantModerationAction.remove &&
        !await _confirmRemoval(participant)) {
      return;
    }
    var changed = false;
    await _runAction(() async {
      await ref
          .read(participantsServiceProvider)
          .moderateParticipant(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            attendeeId: participant.attendeeId,
            action: action,
          );
      changed = true;
    });
    if (changed && mounted) {
      _retry();
    }
  }

  Future<bool> _confirmRemoval(Participant participant) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-remove-participant-dialog'),
        title: Text(strings.roomDetailsRemoveDialogTitle),
        content: Text(
          strings.roomDetailsRemoveDialogMessage(participant.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-remove-participant-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsRemoveDialogConfirm),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  /// Which moderation actions the server would accept for this attendee, so
  /// the menu never offers a change that is guaranteed to come back as an
  /// error. The server stays the authority; this only trims the obvious ones.
  List<ParticipantModerationAction> _availableActions(Participant participant) {
    if (!_isModerator || _isSelf(participant)) {
      return const [];
    }
    return switch (participant.role) {
      ParticipantRole.user ||
      ParticipantRole.userSelfJoined ||
      ParticipantRole.guest => const [
        ParticipantModerationAction.promote,
        ParticipantModerationAction.remove,
      ],
      ParticipantRole.moderator || ParticipantRole.guestModerator => const [
        ParticipantModerationAction.demote,
      ],
      // Owners cannot be demoted or removed, and an unknown role means a
      // participant type this build does not understand.
      ParticipantRole.owner || null => const [],
    };
  }

  /// Best-effort self match so a moderator is not offered actions on their own
  /// row; the login name is usually the user id, and the server refuses
  /// self-demotion anyway when it is not.
  bool _isSelf(Participant participant) {
    return participant.actorType == 'users' &&
        participant.actorId == widget.account.loginName;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('room-details-screen'),
      appBar: AppBar(title: Text(strings.roomDetailsTitle)),
      body: ListView(
        children: [
          _RoomSummary(
            account: widget.account,
            conversation: widget.conversation,
            displayName: _room?.displayName ?? widget.conversation.displayName,
            description: _room?.description ?? widget.conversation.description,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              strings.roomDetailsActionsHeader,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_isModerator)
            ListTile(
              key: const Key('room-details-rename'),
              leading: const Icon(Icons.edit_outlined),
              title: Text(strings.roomDetailsRenameAction),
              onTap: _busy ? null : _renameRoom,
            ),
          if (_isModerator)
            ListTile(
              key: const Key('room-details-description-edit'),
              leading: const Icon(Icons.short_text),
              title: Text(strings.roomDetailsDescriptionEditAction),
              onTap: _busy ? null : _editDescription,
            ),
          ListTile(
            key: const Key('room-details-notification-picker'),
            leading: const Icon(Icons.notifications_outlined),
            title: Text(strings.roomDetailsNotificationLabel),
            subtitle: Text(
              _notificationLabel(strings, _notificationLevel),
              key: const Key('room-details-notification-subtitle'),
            ),
            onTap: _busy ? null : _changeNotificationLevel,
          ),
          SwitchListTile(
            key: const Key('room-details-favorite-toggle'),
            secondary: const Icon(Icons.star_outline),
            title: Text(strings.roomDetailsFavoriteLabel),
            value: _isFavorite,
            onChanged: _busy ? null : _toggleFavorite,
          ),
          if (_canLeave)
            ListTile(
              key: const Key('room-details-leave'),
              leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
              title: Text(
                strings.roomDetailsLeaveAction,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: _busy ? null : _confirmLeave,
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              strings.roomDetailsParticipantsHeader,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          FutureBuilder<List<Participant>>(
            key: const Key('room-details-participants'),
            future: _participants,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return _ParticipantsError(onRetry: _retry);
              }
              final participants = snapshot.data ?? const <Participant>[];
              if (participants.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(strings.roomDetailsParticipantsEmpty),
                );
              }
              return Column(
                children: [
                  for (final participant in participants)
                    _ParticipantTile(
                      account: widget.account,
                      participant: participant,
                      actions: _availableActions(participant),
                      onAction: _busy
                          ? null
                          : (action) => _moderate(participant, action),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

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
  final List<ParticipantModerationAction> actions;
  final void Function(ParticipantModerationAction)? onAction;

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
            PopupMenuButton<ParticipantModerationAction>(
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

String _roomTypeLabel(AppLocalizations strings, int roomType) {
  return switch (roomType) {
    _roomTypeOneToOne => strings.roomDetailsTypeOneToOne,
    _roomTypeGroup => strings.roomDetailsTypeGroup,
    _roomTypePublic => strings.roomDetailsTypePublic,
    _roomTypeChangelog => strings.roomDetailsTypeChangelog,
    _roomTypeFormerOneToOne => strings.roomDetailsTypeFormerOneToOne,
    _roomTypeNoteToSelf => strings.roomDetailsTypeNoteToSelf,
    _ => strings.roomDetailsTypeUnknown,
  };
}

/// Labels the wire-level notification value shown as read-only room
/// metadata, including the `default` value the picker never offers.
String _notificationLabel(AppLocalizations strings, int notificationLevel) {
  return switch (notificationLevel) {
    _notificationDefault => strings.roomDetailsNotificationDefault,
    _notificationAlways => strings.roomDetailsNotificationAlways,
    _notificationMention => strings.roomDetailsNotificationMention,
    _notificationNever => strings.roomDetailsNotificationNever,
    _ => strings.roomDetailsNotificationUnknown,
  };
}

String _notificationLevelLabel(AppLocalizations strings, RoomNotificationLevel level) {
  return switch (level) {
    RoomNotificationLevel.always => strings.roomDetailsNotificationAlways,
    RoomNotificationLevel.mentions => strings.roomDetailsNotificationMention,
    RoomNotificationLevel.never => strings.roomDetailsNotificationNever,
  };
}

String _roleLabel(AppLocalizations strings, ParticipantRole? role) {
  return switch (role) {
    ParticipantRole.owner => strings.roomDetailsRoleOwner,
    ParticipantRole.moderator => strings.roomDetailsRoleModerator,
    ParticipantRole.user => strings.roomDetailsRoleUser,
    ParticipantRole.guest => strings.roomDetailsRoleGuest,
    ParticipantRole.userSelfJoined => strings.roomDetailsRoleUser,
    ParticipantRole.guestModerator => strings.roomDetailsRoleGuestModerator,
    null => strings.roomDetailsRoleUnknown,
  };
}

String _moderationActionLabel(
  AppLocalizations strings,
  ParticipantModerationAction action,
) {
  return switch (action) {
    ParticipantModerationAction.promote => strings.roomDetailsPromoteModerator,
    ParticipantModerationAction.demote => strings.roomDetailsDemoteModerator,
    ParticipantModerationAction.remove => strings.roomDetailsRemoveParticipant,
  };
}

String _participantActionErrorMessage(
  AppLocalizations strings,
  ParticipantsServiceError code,
) {
  return switch (code) {
    ParticipantsServiceError.reauthenticationRequired =>
      strings.roomDetailsActionErrorReauth,
    ParticipantsServiceError.forbidden =>
      strings.roomDetailsActionErrorForbidden,
    ParticipantsServiceError.roomMissing =>
      strings.roomDetailsActionErrorRoomMissing,
    ParticipantsServiceError.rejected =>
      strings.roomDetailsParticipantActionRejected,
    ParticipantsServiceError.accountMissing ||
    ParticipantsServiceError.credentialMissing ||
    ParticipantsServiceError.rateLimited ||
    ParticipantsServiceError.serviceUnavailable ||
    ParticipantsServiceError.invalidResponse ||
    ParticipantsServiceError.network => strings.roomDetailsActionErrorGeneric,
  };
}

String _actionErrorMessage(AppLocalizations strings, RoomSettingsError code) {
  return switch (code) {
    RoomSettingsError.reauthenticationRequired => strings.roomDetailsActionErrorReauth,
    RoomSettingsError.forbidden => strings.roomDetailsActionErrorForbidden,
    RoomSettingsError.roomMissing => strings.roomDetailsActionErrorRoomMissing,
    RoomSettingsError.rejected => strings.roomDetailsLeaveRejected,
    RoomSettingsError.accountMissing ||
    RoomSettingsError.credentialMissing ||
    RoomSettingsError.rateLimited ||
    RoomSettingsError.serviceUnavailable ||
    RoomSettingsError.invalidResponse ||
    RoomSettingsError.network => strings.roomDetailsActionErrorGeneric,
  };
}

/// The cached room JSON is written from the same validated decoder that
/// produces it, so this only fails on local corruption; the screen simply
/// hides the actions (like rename) that need it when parsing fails.
ConversationRoom? _parseCachedRoom(CachedConversation conversation) {
  try {
    return ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
  } on Object {
    return null;
  }
}
