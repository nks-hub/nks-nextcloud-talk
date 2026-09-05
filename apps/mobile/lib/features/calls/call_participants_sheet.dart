import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../rooms/participants_service.dart';
import 'call_media_session.dart';
import 'call_transport_service.dart';

/// Display names for the call's participants, keyed the way the signalling
/// identifies them (`actor:<type>:<id>`). One request per opening of the
/// sheet; a failure leaves the ids on screen rather than an error.
final callParticipantNamesProvider = FutureProvider.autoDispose
    .family<Map<String, String>, CallRoomKey>((ref, key) async {
      final List<Participant> participants;
      try {
        participants = await ref
            .watch(participantsServiceProvider)
            .fetchParticipants(
              accountId: key.accountId,
              roomToken: key.roomToken,
            );
      } on Object {
        return const <String, String>{};
      }
      return <String, String>{
        for (final participant in participants)
          if (participant.displayName.trim().isNotEmpty)
            'actor:${participant.actorType}:${participant.actorId}': participant
                .displayName
                .trim(),
      };
    });

/// The audio call's "grid": who is in the call, whether their audio is
/// connected to us and whether their hand is up. Opened from the banner.
Future<void> showCallParticipantsSheet(BuildContext context, CallRoomKey key) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => CallParticipantsSheet(roomKey: key),
  );
}

final class CallParticipantsSheet extends ConsumerWidget {
  const CallParticipantsSheet({super.key, required this.roomKey});

  final CallRoomKey roomKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final join = ref.watch(callJoinControllerProvider(roomKey));
    final names =
        ref.watch(callParticipantNamesProvider(roomKey)).valueOrNull ??
        const <String, String>{};
    final media = join.media;
    return SafeArea(
      child: ListView(
        key: const Key('call-participants'),
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(
              strings.callParticipantsTitle(media.participants.length + 1),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            key: const Key('call-participant-self'),
            leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
            title: Text(strings.callParticipantsYou),
            subtitle: Text(
              media.muted
                  ? strings.callParticipantMuted
                  : strings.callParticipantConnected,
            ),
            trailing: media.handRaised
                ? Icon(
                    Icons.front_hand_rounded,
                    semanticLabel: strings.callParticipantHandRaised,
                  )
                : null,
          ),
          for (final peer in media.participants)
            _PeerTile(peer: peer, names: names, strings: strings),
        ],
      ),
    );
  }
}

final class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.peer,
    required this.names,
    required this.strings,
  });

  final CallPeerState peer;
  final Map<String, String> names;
  final AppLocalizations strings;

  @override
  Widget build(BuildContext context) {
    final name =
        names['actor:${peer.actorType}:${peer.actorId}'] ??
        (peer.actorId.isEmpty ? peer.peerId : peer.actorId);
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return ListTile(
      key: Key('call-participant-${peer.peerId}'),
      leading: CircleAvatar(child: Text(initial)),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        peer.connected
            ? strings.callParticipantConnected
            : strings.callParticipantConnecting,
      ),
      trailing: peer.handRaised
          ? Icon(
              Icons.front_hand_rounded,
              semanticLabel: strings.callParticipantHandRaised,
            )
          : null,
    );
  }
}
