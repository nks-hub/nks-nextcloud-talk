import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'call_controls.dart';
import 'call_join_controller.dart';
import 'call_media_session.dart';
import 'call_participants_sheet.dart';
import 'call_picture_in_picture.dart';
import 'call_transport_service.dart';

/// Opens the full-screen view of a joined call.
Future<void> showCallScreen(BuildContext context, CallRoomKey key) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/call'),
      builder: (context) => CallScreen(roomKey: key),
    ),
  );
}

/// The call as a grid: one tile per participant (video when they send it,
/// their initial otherwise), this side's preview among them, the controls
/// underneath. It shows the same state the banner does and leaves when the
/// call does — the banner remains the place a call is joined from.
///
/// While it is showing, leaving the app shrinks the call into a small window
/// (where the platform has one); in that window only the tiles are drawn.
final class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.roomKey});

  final CallRoomKey roomKey;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

final class _CallScreenState extends ConsumerState<CallScreen> {
  CallRoomKey get roomKey => widget.roomKey;
  late final CallPictureInPicture _pictureInPicture;
  StreamSubscription<bool>? _pictureInPictureModes;
  bool _inPictureInPicture = false;

  @override
  void initState() {
    super.initState();
    _pictureInPicture = ref.read(callPictureInPictureProvider);
    _pictureInPictureModes = _pictureInPicture.active.listen((active) {
      if (mounted && active != _inPictureInPicture) {
        setState(() => _inPictureInPicture = active);
      }
    });
    unawaited(_pictureInPicture.setAvailable(true));
  }

  @override
  void dispose() {
    unawaited(_pictureInPictureModes?.cancel());
    unawaited(_pictureInPicture.setAvailable(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final join = ref.watch(callJoinControllerProvider(roomKey));
    final names =
        ref.watch(callParticipantNamesProvider(roomKey)).valueOrNull ??
        const <String, String>{};
    // The call ended (or failed) under this screen: nothing to show here any
    // more, the banner explains why.
    ref.listen(callJoinControllerProvider(roomKey), (previous, next) {
      if (next.phase == CallJoinPhase.idle ||
          next.phase == CallJoinPhase.failed) {
        Navigator.of(context).maybePop();
      }
    });
    final media = join.media;
    final tiles = <Widget>[
      _SelfTile(media: media, strings: strings),
      for (final peer in media.participants)
        _PeerTile(peer: peer, names: names, strings: strings),
    ];
    // A shared screen is worth the whole width; the participants share the
    // space below it.
    final sharing = media.participants
        .where((peer) => peer.screen != null)
        .toList(growable: false);
    final columns = tiles.length <= 1 ? 1 : 2;
    final gap = _inPictureInPicture ? 2.0 : 8.0;
    if (_inPictureInPicture) {
      // The window is small: the tiles share it exactly, whatever its shape.
      final rows = (tiles.length + columns - 1) ~/ columns;
      return Scaffold(
        key: const Key('call-screen-pip'),
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) => GridView.count(
            key: const Key('call-grid'),
            padding: EdgeInsets.all(gap),
            crossAxisCount: columns,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio:
                ((constraints.maxWidth - gap * (columns + 1)) / columns) /
                ((constraints.maxHeight - gap * (rows + 1)) / rows),
            children: tiles,
          ),
        ),
      );
    }
    final grid = GridView.count(
      key: const Key('call-grid'),
      padding: EdgeInsets.all(gap),
      crossAxisCount: columns,
      mainAxisSpacing: gap,
      crossAxisSpacing: gap,
      childAspectRatio: 3 / 4,
      children: tiles,
    );
    return Scaffold(
      key: const Key('call-screen'),
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(strings.callScreenTitle(tiles.length)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            for (final peer in sharing)
              Padding(
                key: Key('call-screen-shared-${peer.peerId}'),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _Tile(
                    name: strings.callScreenSharedBy(
                      _PeerTile.nameOf(peer, names),
                    ),
                    initial: '',
                    video: peer.screen!.build(context),
                    muted: false,
                    handRaised: false,
                    subtitle: null,
                  ),
                ),
              ),
            Expanded(child: grid),
            if (media.reaction != null)
              Padding(
                key: const Key('call-screen-reaction'),
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${media.reaction!.emoji}  '
                  '${names['actor:${_actorKey(media, media.reaction!.peerId)}'] ?? ''}',
                  style: const TextStyle(color: Colors.white, fontSize: 20),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CallControls(
                    roomKey: roomKey,
                    join: join,
                    color: Colors.white,
                    keyPrefix: 'call-screen',
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const Key('call-screen-leave'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                    onPressed: join.isBusy
                        ? null
                        : () => unawaited(
                            ref
                                .read(
                                  callJoinControllerProvider(roomKey).notifier,
                                )
                                .leave(),
                          ),
                    icon: const Icon(Icons.call_end_rounded),
                    label: Text(strings.callBannerLeave),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _actorKey(CallMediaState media, String peerId) {
    for (final peer in media.participants) {
      if (peer.peerId == peerId) {
        return '${peer.actorType}:${peer.actorId}';
      }
    }
    return '';
  }
}

final class _SelfTile extends StatelessWidget {
  const _SelfTile({required this.media, required this.strings});

  final CallMediaState media;
  final AppLocalizations strings;

  @override
  Widget build(BuildContext context) {
    final preview = media.localVideo;
    return _Tile(
      key: const Key('call-tile-self'),
      name: strings.callParticipantsYou,
      initial: '',
      video: preview?.buildPreview(context),
      muted: media.muted,
      handRaised: media.handRaised,
      subtitle: null,
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

  static String nameOf(CallPeerState peer, Map<String, String> names) =>
      names['actor:${peer.actorType}:${peer.actorId}'] ??
      (peer.actorId.isEmpty ? peer.peerId : peer.actorId);

  @override
  Widget build(BuildContext context) {
    final name = nameOf(peer, names);
    return _Tile(
      key: Key('call-tile-${peer.peerId}'),
      name: name,
      initial: name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
      video: peer.video?.build(context),
      muted: peer.audioMuted,
      handRaised: peer.handRaised,
      subtitle: peer.connected ? null : strings.callParticipantConnecting,
    );
  }
}

final class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.name,
    required this.initial,
    required this.video,
    required this.muted,
    required this.handRaised,
    required this.subtitle,
  });

  final String name;
  final String initial;
  final Widget? video;
  final bool muted;
  final bool handRaised;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: scheme.surfaceContainerHighest),
          if (video != null)
            video!
          else
            Center(
              child: CircleAvatar(
                radius: 36,
                child: initial.isEmpty
                    ? const Icon(Icons.person_rounded, size: 36)
                    : Text(initial, style: const TextStyle(fontSize: 28)),
              ),
            ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    subtitle == null ? name : '$name · $subtitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 4)],
                    ),
                  ),
                ),
                if (handRaised)
                  const Icon(
                    Icons.front_hand_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                if (muted)
                  const Icon(
                    Icons.mic_off_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
