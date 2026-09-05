import 'dart:async';

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

/// A peer still connecting after this long is shown as not responding: the
/// usual cause is a session that left the call and has not timed out on the
/// server yet, and "Connecting…" forever would be a lie.
const _notRespondingAfter = Duration(seconds: 20);

final class _PeerTile extends StatefulWidget {
  const _PeerTile({
    required this.peer,
    required this.names,
    required this.strings,
  });

  final CallPeerState peer;
  final Map<String, String> names;
  final AppLocalizations strings;

  @override
  State<_PeerTile> createState() => _PeerTileState();
}

final class _PeerTileState extends State<_PeerTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Only a connecting peer needs the clock; the tile is rebuilt anyway when
    // the connection state changes.
    if (!widget.peer.connected) {
      _ticker = Timer.periodic(
        const Duration(seconds: 5),
        (_) => setState(() {}),
      );
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final names = widget.names;
    final strings = widget.strings;
    final notResponding =
        !peer.connected &&
        DateTime.now().difference(peer.since) > _notRespondingAfter;
    final name =
        names['actor:${peer.actorType}:${peer.actorId}'] ??
        (peer.actorId.isEmpty ? peer.peerId : peer.actorId);
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final video = peer.video;
    final tile = ListTile(
      key: Key('call-participant-${peer.peerId}'),
      leading: CircleAvatar(child: Text(initial)),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        peer.connected
            ? strings.callParticipantConnected
            : (notResponding
                  ? strings.callParticipantNotResponding
                  : strings.callParticipantConnecting),
      ),
      trailing: peer.handRaised
          ? Icon(
              Icons.front_hand_rounded,
              semanticLabel: strings.callParticipantHandRaised,
            )
          : null,
    );
    if (video == null) {
      return tile;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        tile,
        Padding(
          key: Key('call-participant-video-${peer.peerId}'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: video.build(context),
            ),
          ),
        ),
      ],
    );
  }
}
