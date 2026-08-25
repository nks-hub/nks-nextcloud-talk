import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_participant_avatar.dart';
import '../conversations/conversation_avatar_widget.dart';
import 'participants_service.dart';

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

/// Read-only conversation details: room metadata plus the participant list
/// with each attendee's role and, when the server returned it, user status.
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

  @override
  void initState() {
    super.initState();
    _participants = _load();
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

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('room-details-screen'),
      appBar: AppBar(title: Text(strings.roomDetailsTitle)),
      body: ListView(
        children: [
          _RoomSummary(account: widget.account, conversation: widget.conversation),
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
  const _RoomSummary({required this.account, required this.conversation});

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final room = _parseCachedRoom(conversation);
    final notificationLevel = room?.notificationLevel;
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
          ),
          const SizedBox(height: 12),
          _InfoRow(
            label: strings.roomDetailsReadOnlyLabel,
            value: conversation.readOnly != 0
                ? strings.roomDetailsReadOnlyYes
                : strings.roomDetailsReadOnlyNo,
          ),
          if (notificationLevel != null) ...[
            const SizedBox(height: 12),
            _InfoRow(
              label: strings.roomDetailsNotificationLabel,
              value: _notificationLabel(strings, notificationLevel),
            ),
          ],
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
  const _ParticipantTile({required this.account, required this.participant});

  final StoredAccount account;
  final Participant participant;

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
      trailing: participant.status == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: online ? Colors.green : scheme.outline,
                  semanticLabel: online
                      ? strings.presenceOnline
                      : participant.status,
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

String _notificationLabel(AppLocalizations strings, int notificationLevel) {
  return switch (notificationLevel) {
    _notificationDefault => strings.roomDetailsNotificationDefault,
    _notificationAlways => strings.roomDetailsNotificationAlways,
    _notificationMention => strings.roomDetailsNotificationMention,
    _notificationNever => strings.roomDetailsNotificationNever,
    _ => strings.roomDetailsNotificationUnknown,
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

/// The cached room JSON is written from the same validated decoder that
/// produces it, so this only fails on local corruption; the summary simply
/// omits fields (like notification level) that are not otherwise cached.
ConversationRoom? _parseCachedRoom(CachedConversation conversation) {
  try {
    return ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
  } on Object {
    return null;
  }
}
