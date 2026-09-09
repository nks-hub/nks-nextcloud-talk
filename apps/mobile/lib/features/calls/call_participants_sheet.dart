import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/media/chat_attachment_exporter.dart';
import '../rooms/participants_service.dart';
import '../rooms/room_settings_service.dart';
import 'call_join_controller.dart';
import 'call_media_session.dart';
import 'call_ring_service.dart';
import 'call_transport_service.dart';

/// The room's participants as the server lists them. One request per opening
/// of the sheet; a failure leaves the sheet without names and without the
/// absent list rather than showing an error over a running call.
final callRoomParticipantsProvider = FutureProvider.autoDispose
    .family<List<Participant>, CallRoomKey>((ref, key) async {
      try {
        return await ref
            .watch(participantsServiceProvider)
            .fetchParticipants(
              accountId: key.accountId,
              roomToken: key.roomToken,
            );
      } on Object {
        return const <Participant>[];
      }
    });

/// Display names keyed the way the signalling identifies a peer
/// (`actor:<type>:<id>`).
final callParticipantNamesProvider = FutureProvider.autoDispose
    .family<Map<String, String>, CallRoomKey>((ref, key) async {
      final participants = await ref.watch(
        callRoomParticipantsProvider(key).future,
      );
      return <String, String>{
        for (final participant in participants)
          if (participant.displayName.trim().isNotEmpty)
            'actor:${participant.actorType}:${participant.actorId}': participant
                .displayName
                .trim(),
      };
    });

/// Everybody in the room this call's own account could ring, before the
/// live call state is taken into account.
///
/// The account is the room key's, not whichever the shell has selected: a
/// call can be running in an account that is not on screen, and comparing
/// against the wrong login name would offer to ring the person holding the
/// phone.
final callRingCandidatesProvider = FutureProvider.autoDispose
    .family<List<Participant>, CallRoomKey>((ref, key) async {
      final participants = await ref.watch(
        callRoomParticipantsProvider(key).future,
      );
      final account = await ref
          .watch(accountRepositoryProvider)
          .getAccount(key.accountId);
      return callRingCandidates(
        participants: participants,
        peers: const <CallPeerState>[],
        selfActorId: account?.loginName,
      );
    });

/// Who the sheet offers to ring: a participant of the room who is not in the
/// call, is not this device, and is a real person the server can notify.
///
/// The server itself does not police this — measured, it answers `200` for an
/// attendee already in the call and even for a caller who has not joined — so
/// the decision of who is worth ringing is made here.
List<Participant> callRingCandidates({
  required List<Participant> participants,
  required Iterable<CallPeerState> peers,
  required String? selfActorId,
}) {
  final inCall = <String>{
    for (final peer in peers) '${peer.actorType}:${peer.actorId}',
  };
  return <Participant>[
    for (final participant in participants)
      if (participant.inCall == 0 &&
          participant.actorType == 'users' &&
          participant.actorId != selfActorId &&
          !inCall.contains('${participant.actorType}:${participant.actorId}'))
        participant,
  ];
}

/// The audio call's "grid": who is in the call, whether their audio is
/// connected to us and whether their hand is up. Opened from the banner.
Future<void> showCallParticipantsSheet(
  BuildContext context,
  CallRoomKey key, {
  ChatAttachmentSystem? exportSystem,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) =>
        CallParticipantsSheet(roomKey: key, exportSystem: exportSystem),
  );
}

final class CallParticipantsSheet extends ConsumerWidget {
  const CallParticipantsSheet({
    super.key,
    required this.roomKey,
    this.exportSystem,
  });

  final CallRoomKey roomKey;

  /// Where an exported attendance file is written. Injected by tests; the
  /// screen uses the platform picker.
  final ChatAttachmentSystem? exportSystem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final join = ref.watch(callJoinControllerProvider(roomKey));
    final names =
        ref.watch(callParticipantNamesProvider(roomKey)).valueOrNull ??
        const <String, String>{};
    final media = join.media;
    // The provider answers who is in the room; the peers change with every
    // frame of the call, so that half is applied here.
    final absent = callRingCandidates(
      participants:
          ref.watch(callRingCandidatesProvider(roomKey)).valueOrNull ??
          const <Participant>[],
      peers: media.participants,
      selfActorId: null,
    );
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
          if (media.localVideo != null)
            Padding(
              key: const Key('call-participant-self-video'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: media.localVideo!.buildPreview(context),
                ),
              ),
            ),
          for (final peer in media.participants)
            _PeerTile(peer: peer, names: names, strings: strings),
          // Everybody in the room who has not joined. Ringing exists for
          // exactly this: the call is running and they are not in it.
          if (absent.isNotEmpty && join.phase == CallJoinPhase.joined) ...[
            const Divider(height: 1),
            ListTile(
              key: const Key('call-ring-absent'),
              dense: true,
              title: Text(
                strings.callRingAbsentTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final participant in absent)
              _AbsentTile(roomKey: roomKey, participant: participant),
          ],
          // Moderator-only and only where the server advertises
          // `download-call-participants`. The list above is who this device
          // has media with; the export is what the server recorded, which is
          // not the same thing and includes whoever already left.
          if (join.canDownloadAttendance &&
              join.phase == CallJoinPhase.joined) ...[
            const Divider(height: 1),
            _AttendanceExportTile(roomKey: roomKey, exportSystem: exportSystem),
          ],
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (peer.audioMuted)
            Icon(
              Icons.mic_off_rounded,
              semanticLabel: strings.callParticipantMuted,
            ),
          if (peer.handRaised)
            Icon(
              Icons.front_hand_rounded,
              semanticLabel: strings.callParticipantHandRaised,
            ),
        ],
      ),
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

/// Saves the attendance the server recorded for the running call.
final class _AttendanceExportTile extends ConsumerStatefulWidget {
  const _AttendanceExportTile({required this.roomKey, this.exportSystem});

  final CallRoomKey roomKey;
  final ChatAttachmentSystem? exportSystem;

  @override
  ConsumerState<_AttendanceExportTile> createState() =>
      _AttendanceExportTileState();
}

final class _AttendanceExportTileState
    extends ConsumerState<_AttendanceExportTile> {
  bool _running = false;
  String? _notice;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final notice = _notice;
    return ListTile(
      key: const Key('call-attendance-export'),
      leading: _running
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.file_download_outlined),
      title: Text(strings.callAttendanceExportAction),
      subtitle: Text(notice ?? strings.callAttendanceExportHint),
      enabled: !_running,
      onTap: _running ? null : () => unawaited(_export()),
    );
  }

  Future<void> _export() async {
    setState(() {
      _running = true;
      _notice = null;
    });
    final strings = AppLocalizations.of(context);
    String? notice;
    try {
      final csv = await ref
          .read(roomSettingsServiceProvider)
          .downloadCallAttendance(
            accountId: widget.roomKey.accountId,
            roomToken: widget.roomKey.roomToken,
          );
      final system = widget.exportSystem ?? PlatformChatAttachmentSystem();
      final result = await system.save(
        // A byte-order mark so a spreadsheet reads the names as UTF-8; the
        // participants of this server have accented ones.
        bytes: Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode(csv)]),
        fileName: _fileName(),
        contentType: 'text/csv',
      );
      notice = switch (result) {
        ChatAttachmentSystemResult.completed =>
          strings.callAttendanceExportSaved,
        ChatAttachmentSystemResult.cancelled => null,
        _ => strings.callAttendanceExportFailed,
      };
    } on RoomSettingsException catch (error) {
      notice = switch (error.code) {
        RoomSettingsError.preconditionFailed =>
          strings.callAttendanceExportNoCall,
        RoomSettingsError.forbidden => strings.callAttendanceExportForbidden,
        _ => strings.callAttendanceExportFailed,
      };
    } on Object {
      notice = strings.callAttendanceExportFailed;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _notice = notice;
    });
  }

  String _fileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'call-attendance-${widget.roomKey.roomToken}-'
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}.csv';
  }
}

/// One participant of the room who is not in the call, with the ring action.
final class _AbsentTile extends ConsumerStatefulWidget {
  const _AbsentTile({required this.roomKey, required this.participant});

  final CallRoomKey roomKey;
  final Participant participant;

  @override
  ConsumerState<_AbsentTile> createState() => _AbsentTileState();
}

final class _AbsentTileState extends ConsumerState<_AbsentTile> {
  bool _ringing = false;
  String? _notice;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final name = widget.participant.displayName.trim().isEmpty
        ? widget.participant.actorId
        : widget.participant.displayName.trim();
    return ListTile(
      key: Key('call-ring-${widget.participant.attendeeId}'),
      leading: CircleAvatar(
        child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: _notice == null ? null : Text(_notice!),
      trailing: _ringing
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              key: Key('call-ring-button-${widget.participant.attendeeId}'),
              tooltip: strings.callRingAction,
              icon: const Icon(Icons.notifications_active_outlined),
              onPressed: () => unawaited(_ring(name)),
            ),
    );
  }

  Future<void> _ring(String name) async {
    if (_ringing) {
      return;
    }
    setState(() => _ringing = true);
    final strings = AppLocalizations.of(context);
    String message;
    try {
      await ref
          .read(callRingServiceProvider)
          .ring(
            accountId: widget.roomKey.accountId,
            roomToken: widget.roomKey.roomToken,
            attendeeId: widget.participant.attendeeId,
          );
      message = strings.callRingSent(name);
    } on CallRingException catch (error) {
      message = error.code == CallRingError.noCallRunning
          ? strings.callRingNoCall
          : strings.callRingFailed(name);
    } on Object {
      message = strings.callRingFailed(name);
    }
    if (!mounted) return;
    // Written into the row, not into a snack bar: this sheet covers the bottom
    // of the screen, so a snack bar appears behind it and the person who
    // pressed the button never learns what happened. Found on a real phone.
    setState(() {
      _ringing = false;
      _notice = message;
    });
  }
}
