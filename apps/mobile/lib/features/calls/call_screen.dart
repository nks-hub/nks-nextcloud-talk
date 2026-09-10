import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'call_controls.dart';
import 'call_join_controller.dart';
import 'call_media_session.dart';
import 'call_participants_sheet.dart';
import 'call_picture_in_picture.dart';
import 'call_transport_service.dart';

/// Below this a tile is too small to read a name in, so the grid keeps its
/// fixed shape and scrolls rather than squeezing everyone onto one screen.
const double _minimumTileHeight = 140;

/// Presents an admitted call while its initiating view still owns navigation.
Future<void> joinCallAndPresent(
  BuildContext context,
  WidgetRef ref,
  CallRoomKey key, {
  required bool Function() isCurrent,
  bool withCamera = false,
}) async {
  bool ownsView() => context.mounted && ref.context.mounted && isCurrent();
  if (!ownsView()) return;
  final origin = ModalRoute.of(context);
  final navigator = Navigator.of(context);
  bool canPresent() =>
      ownsView() &&
      (origin?.isCurrent ?? true) &&
      identical(Navigator.of(context), navigator);
  if (!canPresent()) return;
  final state = ref.read(callJoinControllerProvider(key));
  if (state.isBusy || state.phase == CallJoinPhase.joined) return;
  final controller = ref.read(callJoinControllerProvider(key).notifier);
  bool sameJoinedCall() =>
      identical(
        ref.read(callJoinControllerProvider(key).notifier),
        controller,
      ) &&
      ref.read(callJoinControllerProvider(key)).phase == CallJoinPhase.joined;
  await controller.join();
  if (!canPresent() || !sameJoinedCall()) return;
  if (withCamera) await controller.setCameraEnabled(true);
  if (!context.mounted || !canPresent() || !sameJoinedCall()) return;
  await showCallScreen(context, key);
}

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
  bool _pictureInPictureAvailable = false;
  String? _windowTrackId;
  String? _expandedTile;
  LocalHistoryEntry? _tileHistory;
  bool _disposing = false;

  @override
  void initState() {
    super.initState();
    _pictureInPicture = ref.read(callPictureInPictureProvider);
    _pictureInPictureModes = _pictureInPicture.active.listen((active) {
      if (mounted && active != _inPictureInPicture) {
        setState(() => _inPictureInPicture = active);
        if (!active && _ended(ref.read(callJoinControllerProvider(roomKey)))) {
          _removeCallRoute();
        }
      }
    });
  }

  @override
  void dispose() {
    _disposing = true;
    _tileHistory?.remove();
    unawaited(_pictureInPictureModes?.cancel());
    _setPictureInPictureAvailable(false);
    super.dispose();
  }

  void _expand(String id) {
    if (_expandedTile != null) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    _tileHistory = LocalHistoryEntry(
      onRemove: () {
        _tileHistory = null;
        if (!_disposing && mounted) setState(() => _expandedTile = null);
      },
    );
    route.addLocalHistoryEntry(_tileHistory!);
    setState(() => _expandedTile = id);
  }

  Widget _expandable(
    String id,
    Widget tile,
    AppLocalizations strings,
    String name,
  ) => Stack(
    fit: StackFit.expand,
    children: [
      GestureDetector(onTap: () => _expand(id), child: tile),
      Positioned(
        top: 4,
        right: 4,
        child: IconButton.filledTonal(
          key: Key('call-expand-$id'),
          // Named, because a grid of five identically labelled buttons tells
          // a screen reader nothing about which video it would open.
          tooltip: strings.callScreenExpand(name),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: () => _expand(id),
          icon: const Icon(Icons.fullscreen_rounded),
        ),
      ),
    ],
  );

  bool _ended(CallJoinState join) =>
      join.phase == CallJoinPhase.idle || join.phase == CallJoinPhase.failed;

  void _setPictureInPictureAvailable(bool available) {
    if (_pictureInPictureAvailable == available) return;
    _pictureInPictureAvailable = available;
    if (!available) {
      _windowTrackId = null;
      unawaited(_pictureInPicture.setVideoTrack(null));
    }
    unawaited(_pictureInPicture.setAvailable(available));
  }

  void _removeCallRoute() {
    final route = ModalRoute.of(context);
    if (route != null && route.isActive && !route.isFirst) {
      Navigator.of(context).removeRoute(route);
    }
  }

  /// The one picture a picture-in-picture window can hold: a shared screen if
  /// somebody is sharing, otherwise the first participant who sends video.
  /// The order matters — a share is what people open the window to keep an
  /// eye on.
  String? _windowTrack(CallMediaState media) {
    for (final peer in media.participants) {
      final screen = peer.screen?.videoTrackId;
      if (screen != null) {
        return screen;
      }
    }
    for (final peer in media.participants) {
      final video = peer.video?.videoTrackId;
      if (video != null) {
        return video;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final join = ref.watch(callJoinControllerProvider(roomKey));
    final route = ModalRoute.of(context);
    final ended = _ended(join);
    _setPictureInPictureAvailable(!ended && (route?.isCurrent ?? true));
    final names =
        ref.watch(callParticipantNamesProvider(roomKey)).valueOrNull ??
        const <String, String>{};
    // The call ended (or failed) under this screen: nothing to show here any
    // more, the banner explains why.
    ref.listen(callJoinControllerProvider(roomKey), (previous, next) {
      if (_ended(next)) {
        _setPictureInPictureAvailable(false);
        if (!_inPictureInPicture) _removeCallRoute();
      }
    });
    if (ended) {
      if (!_inPictureInPicture) {
        final endedKey = roomKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              roomKey == endedKey &&
              !_inPictureInPicture &&
              _ended(ref.read(callJoinControllerProvider(endedKey)))) {
            _removeCallRoute();
          }
        });
      }
      return Scaffold(
        key: const Key('call-screen-pip-ended'),
        backgroundColor: Colors.black,
        body: Center(
          child: Semantics(
            liveRegion: true,
            child: Text(
              strings.callScreenEnded,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      );
    }
    final media = join.media;
    // Recomputed on every build rather than watched: the participants list is
    // rebuilt whenever a track appears or goes away, and the port drops a
    // repeat of the same id on the platform side.
    final windowTrack = _windowTrack(media);
    if (_pictureInPictureAvailable && windowTrack != _windowTrackId) {
      _windowTrackId = windowTrack;
      unawaited(_pictureInPicture.setVideoTrack(windowTrack));
    }
    // A shared screen is worth the whole width; the participants share the
    // space below it.
    final sharing = media.participants
        .where((peer) => peer.screen != null)
        .toList(growable: false);
    // Identity, not list position: a participant who leaves or is reordered
    // must not hand the expansion to somebody else.
    final peers = <String, CallPeerState>{
      for (final peer in media.participants) 'peer-${peer.peerId}': peer,
    };
    final shares = <String, CallPeerState>{
      for (final peer in sharing) 'screen-${peer.peerId}': peer,
    };
    // The grid crops camera tiles to fill them; a shared screen and anything
    // expanded keep the whole frame instead.
    Widget? tileOf(String id, {required bool contain}) {
      if (id == 'self') {
        return _SelfTile(media: media, strings: strings, contain: contain);
      }
      final peer = peers[id];
      if (peer != null) {
        return _PeerTile(
          peer: peer,
          names: names,
          strings: strings,
          contain: contain,
        );
      }
      final share = shares[id];
      if (share == null) return null;
      return _Tile(
        name: strings.callScreenSharedBy(_PeerTile.nameOf(share, names)),
        initial: '',
        video: share.screen!.build(context, contain: true),
        muted: false,
        handRaised: false,
        subtitle: null,
      );
    }

    String nameOf(String id) => id == 'self'
        ? strings.callParticipantsYou
        : _PeerTile.nameOf(peers[id] ?? shares[id]!, names);
    final tileIds = ['self', ...peers.keys];
    final tiles = [for (final id in tileIds) tileOf(id, contain: false)!];
    final selected = _expandedTile == null
        ? null
        : tileOf(_expandedTile!, contain: true);
    if (_expandedTile != null && selected == null) {
      final missing = _expandedTile;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _expandedTile == missing) _tileHistory?.remove();
      });
    }
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
            key: const PageStorageKey('call-grid'),
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
    final rows = (tiles.length + columns - 1) ~/ columns;
    final grid = LayoutBuilder(
      builder: (context, constraints) {
        // Whatever the shared screen and the padding leave over belongs to
        // the participants: two people on a phone used to sit in a third of
        // the view with the rest black. Below a legible tile height the grid
        // goes back to a fixed shape and scrolls instead of shrinking faces.
        final shareHeight = sharing.isEmpty
            ? 0.0
            : sharing.length * ((constraints.maxWidth - 16) * 9 / 16 + 8);
        final tileHeight =
            (constraints.maxHeight - shareHeight - gap * (rows + 1)) / rows;
        final tileWidth =
            (constraints.maxWidth - gap * (columns + 1)) / columns;
        final fills = tileHeight >= _minimumTileHeight;
        return CustomScrollView(
          // Page storage, so collapsing an expanded tile returns to the same
          // scroll offset rather than jumping back to the first row.
          key: const PageStorageKey('call-grid'),
          slivers: [
            for (final peer in sharing)
              SliverToBoxAdapter(
                child: Padding(
                  key: Key('call-screen-shared-${peer.peerId}'),
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _expandable(
                      'screen-${peer.peerId}',
                      tileOf('screen-${peer.peerId}', contain: true)!,
                      strings,
                      _PeerTile.nameOf(peer, names),
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.all(gap),
              sliver: SliverGrid.count(
                crossAxisCount: columns,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
                childAspectRatio: fills ? tileWidth / tileHeight : 3 / 4,
                children: [
                  for (var i = 0; i < tileIds.length; i++)
                    _expandable(
                      tileIds[i],
                      tiles[i],
                      strings,
                      nameOf(tileIds[i]),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
    return CallbackShortcuts(
      bindings: {
        if (selected != null)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _tileHistory?.remove(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('call-screen'),
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(strings.callScreenTitle(tiles.length)),
            actions: [
              if (selected != null)
                IconButton(
                  key: const Key('call-collapse-tile'),
                  tooltip: strings.callScreenCollapse,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: () => _tileHistory?.remove(),
                  icon: const Icon(Icons.fullscreen_exit_rounded),
                ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: selected == null
                      ? grid
                      : SizedBox.expand(
                          key: const Key('call-expanded-tile'),
                          child: selected,
                        ),
                ),
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
                  // Wrap, not Row: six round controls plus a labelled leave
                  // button do not fit across a 411 dp phone, and a Row simply
                  // clips — on the emulator the red button ran off the right
                  // edge reading "Leave c". Wrapping puts the button on its own
                  // line when it has to, which keeps every control at full size
                  // rather than shrinking the targets to fit.
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      CallControls(
                        roomKey: roomKey,
                        join: join,
                        color: Colors.white,
                        keyPrefix: 'call-screen',
                      ),
                      FilledButton.icon(
                        key: const Key('call-screen-leave'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onError,
                        ),
                        onPressed: join.isBusy
                            ? null
                            : () => unawaited(
                                ref
                                    .read(
                                      callJoinControllerProvider(
                                        roomKey,
                                      ).notifier,
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
  const _SelfTile({
    required this.media,
    required this.strings,
    this.contain = false,
  });

  final CallMediaState media;
  final AppLocalizations strings;
  final bool contain;

  @override
  Widget build(BuildContext context) {
    final preview = media.localVideo;
    return _Tile(
      key: const Key('call-tile-self'),
      name: strings.callParticipantsYou,
      initial: '',
      video: preview?.buildPreview(context, contain: contain),
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
    this.contain = false,
  });

  final CallPeerState peer;
  final Map<String, String> names;
  final AppLocalizations strings;
  final bool contain;

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
      video: peer.video?.build(context, contain: contain),
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Dark on purpose in both themes: the name and the icons painted
          // over this tile are white, and on the light scheme's own container
          // colour that reads at about 1.2:1. The rest of the call screen is
          // black anyway, so the tile was the one place that drifted.
          const ColoredBox(color: Color(0xFF1C1B1F)),
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
