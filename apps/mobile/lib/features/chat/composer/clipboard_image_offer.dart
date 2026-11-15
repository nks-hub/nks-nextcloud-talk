import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'clipboard_image_source.dart';
import 'pasted_image.dart';

/// Offers the image waiting on the clipboard — usually a screenshot copied a
/// moment ago — as a tile floating over the end of the message list, to be
/// sent or dismissed in one tap. It takes no room in the composer: nothing
/// moves when it comes or goes.
///
/// The clipboard is only looked at while the field has focus and the app is
/// in front, and its content is only read for a clip that was not offered
/// before. The bytes stay in memory and are dropped when the offer is
/// dismissed, when this widget goes away (its key carries the room) and when
/// the app leaves the foreground.
final class ClipboardImageOffer extends ConsumerStatefulWidget {
  const ClipboardImageOffer({
    required this.focusNode,
    required this.blocked,
    required this.refresh,
    required this.sending,
    required this.onAttach,
    required this.onSend,
    super.key,
  });

  /// The message field's focus: nothing is read while it is elsewhere.
  final FocusNode focusNode;

  /// Whether something else already occupies the composer: a prepared
  /// attachment, a voice recording, a send in flight.
  final bool Function() blocked;

  /// Fires when [blocked] may answer differently.
  final Listenable refresh;
  final bool sending;

  /// Puts the image into the composer like a pasted one; true once it waits
  /// there.
  final Future<bool> Function(PastedImage image) onAttach;

  /// Sends what the composer holds, same as the send button.
  final VoidCallback onSend;

  /// Forgets which clip was last sent or dismissed, as a restart of the app
  /// does to what is only held in memory.
  @visibleForTesting
  static void debugForgetHandledClip() {
    _ClipboardImageOfferState._handledClip = null;
    _ClipboardImageOfferState._restored = false;
  }

  @override
  ConsumerState<ClipboardImageOffer> createState() =>
      _ClipboardImageOfferState();
}

typedef _Offer = ({String id, PastedImage image, ui.Image thumbnail});

final class _ClipboardImageOfferState extends ConsumerState<ClipboardImageOffer>
    with WidgetsBindingObserver {
  final LayerLink _anchor = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  /// The clip the user already answered, in any room: it is not offered again
  /// until something new is copied. Restored from [ClipboardOfferMemory] the
  /// first time a clip is looked at.
  static String? _handledClip;
  static bool _restored = false;

  ClipboardImageSource? _source;
  _Offer? _offer;
  int _round = 0;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _source = ref.read(clipboardImageSourceProvider);
    _portal.show();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.focusNode.addListener(_check);
    widget.refresh.addListener(_handleRefresh);
    _source?.changes?.addListener(_check);
    // The field can already hold the focus when a room opens on desktop.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  @override
  void didUpdateWidget(covariant ClipboardImageOffer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      oldWidget.focusNode.removeListener(_check);
      widget.focusNode.addListener(_check);
    }
    if (!identical(oldWidget.refresh, widget.refresh)) {
      oldWidget.refresh.removeListener(_handleRefresh);
      widget.refresh.addListener(_handleRefresh);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.focusNode.removeListener(_check);
    widget.refresh.removeListener(_handleRefresh);
    _source?.changes?.removeListener(_check);
    _round++;
    _offer = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_check());
    } else if (state != AppLifecycleState.inactive) {
      // Inactive is also a desktop window that merely lost focus, or a
      // permission dialog; the image only has to go once the app is hidden.
      _round++;
      if (_offer != null) {
        _drop();
        // A hidden app gets no frames on its own, and the card on screen
        // still holds the picture until one is built.
        WidgetsBinding.instance.scheduleForcedFrame();
      }
    }
  }

  void _handleRefresh() {
    if (_offer != null && widget.blocked()) {
      _drop();
    }
  }

  Future<void> _check() async {
    final source = _source;
    if (source == null ||
        !mounted ||
        !_foreground ||
        !widget.focusNode.hasFocus ||
        widget.blocked()) {
      return;
    }
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final round = ++_round;
    bool stale() =>
        !mounted || round != _round || !_foreground || widget.blocked();
    String? id;
    try {
      id = await source.peek().timeout(const Duration(seconds: 1));
    } on Object {
      id = null;
    }
    if (stale()) {
      return;
    }
    if (id == null) {
      _drop();
      return;
    }
    if (!_restored) {
      _restored = true;
      _handledClip ??= await ref.read(clipboardOfferMemoryProvider).read();
      if (stale()) {
        return;
      }
    }
    if (id == _handledClip || id == _offer?.id) {
      return;
    }
    PastedImage? image;
    ui.Image? thumbnail;
    try {
      // A clipboard owner may produce its data only when asked, and take as
      // long as it likes; the suggestion is not worth waiting for.
      final raw = await source.read().timeout(const Duration(seconds: 3));
      image = raw == null ? null : await normalizePastedImage(raw);
      if (image != null) {
        thumbnail = await _decodeThumbnail(
          image.bytes,
          (ClipboardImageOfferCard.thumbnailExtent * pixelRatio).round(),
        );
      }
    } on Object {
      thumbnail = null;
    }
    if (image == null || thumbnail == null) {
      // Unreadable once is unreadable again; do not ask on every focus.
      _handledClip = id;
      return;
    }
    if (stale()) {
      thumbnail.dispose();
      return;
    }
    final offer = (id: id, image: image, thumbnail: thumbnail);
    setState(() => _offer = offer);
  }

  /// The picture at the size it is shown, decoded by the engine off the UI
  /// thread; the full screenshot never becomes a bitmap here. [extent] is
  /// what the shorter side needs, the most the cropped tile can show of it.
  static Future<ui.Image> _decodeThumbnail(Uint8List bytes, int extent) async {
    final codec = await ui.instantiateImageCodecWithSize(
      await ui.ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: (width, height) {
        final scale = math.min(1.0, extent / math.min(width, height));
        return ui.TargetImageSize(
          width: math.max(1, (width * scale).round()),
          height: math.max(1, (height * scale).round()),
        );
      },
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  void _drop() {
    final offer = _offer;
    if (offer == null) {
      return;
    }
    // The card disposes the thumbnail once it has left the screen.
    _offer = null;
    if (!mounted) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      setState(() {});
    }
  }

  void _answered(String id) {
    _handledClip = id;
    if (_source?.survivesRestart(id) ?? false) {
      unawaited(ref.read(clipboardOfferMemoryProvider).write(id));
    }
  }

  void _dismiss() {
    final offer = _offer;
    if (offer != null) {
      _answered(offer.id);
      _drop();
    }
  }

  Future<void> _take({required bool send}) async {
    final offer = _offer;
    if (offer == null) {
      return;
    }
    // Cleared before the first await, so a second tap finds nothing to send.
    _answered(offer.id);
    _drop();
    final attached = await widget.onAttach(offer.image);
    if (send && attached && mounted) {
      widget.onSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nothing of the offer takes part in the composer's layout: this is a
    // point at the composer's top edge, and the tile hangs above it in the
    // overlay, over the end of the message list.
    return CompositedTransformTarget(
      link: _anchor,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildOverlay,
        child: const SizedBox(width: double.infinity),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final offer = _offer;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final child = offer == null
        ? const SizedBox.shrink()
        // Part of the field's own tap region, so a tap on the tile does not
        // take the focus, and with it the soft keyboard, away.
        : TextFieldTapRegion(
            key: ValueKey<String>(offer.id),
            child: ClipboardImageOfferCard(
              thumbnail: offer.thumbnail,
              onAttach: () => unawaited(_take(send: false)),
              onDismiss: _dismiss,
              onSend: widget.sending
                  ? null
                  : () => unawaited(_take(send: true)),
            ),
          );
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _anchor,
        showWhenUnlinked: false,
        targetAnchor: rtl ? Alignment.topLeft : Alignment.topRight,
        followerAnchor: rtl ? Alignment.bottomLeft : Alignment.bottomRight,
        // The anchor sits inside the composer's 8 dp padding; the tile keeps
        // another 8 dp clear of the composer itself.
        offset: const Offset(0, -16),
        // Leaving the foreground skips the exit transition too: the frames
        // that would play it are not coming.
        child:
            MediaQuery.disableAnimationsOf(context) ||
                (offer == null && !_foreground)
            ? child
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) => Stack(
                  alignment: AlignmentDirectional.bottomEnd,
                  children: [...previous, ?current],
                ),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
                    alignment: rtl
                        ? Alignment.bottomLeft
                        : Alignment.bottomRight,
                    child: child,
                  ),
                ),
                child: child,
              ),
      ),
    );
  }
}

/// The suggestion itself: the picture, with a close badge on one corner and
/// the send button on the opposite one.
///
/// Owns [thumbnail] and disposes it when it leaves the tree.
final class ClipboardImageOfferCard extends StatefulWidget {
  const ClipboardImageOfferCard({
    required this.thumbnail,
    required this.onAttach,
    required this.onDismiss,
    required this.onSend,
    super.key,
  });

  /// The longer side of the picture on screen.
  static const double thumbnailExtent = 112;

  final ui.Image thumbnail;

  /// Moves the image into the composer, where it can get a caption.
  final VoidCallback onAttach;
  final VoidCallback onDismiss;

  /// Null while a send is already in flight.
  final VoidCallback? onSend;

  @override
  State<ClipboardImageOfferCard> createState() =>
      _ClipboardImageOfferCardState();
}

final class _ClipboardImageOfferCardState
    extends State<ClipboardImageOfferCard> {
  // How far the two buttons reach past the picture. Both are 48 dp targets:
  // the badge is centred on its corner, the send button sits a quarter out.
  static const _badgeOverhang = 18.0;
  static const _sendOverhang = 12.0;

  @override
  void dispose() {
    widget.thumbnail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final image = widget.thumbnail;
    // The picture keeps its shape up to 16:9 either way; a panorama or a
    // very tall capture is cropped to stay a tile.
    final aspect = (image.width / image.height).clamp(9 / 16, 16 / 9);
    const extent = ClipboardImageOfferCard.thumbnailExtent;
    final size = aspect >= 1
        ? Size(extent, extent / aspect)
        : Size(extent * aspect, extent);
    return Semantics(
      container: true,
      liveRegion: true,
      label: strings.clipboardImageOfferTitle,
      child: SizedBox(
        key: const Key('clipboard-image-offer'),
        width: _badgeOverhang + size.width + _sendOverhang,
        height: _badgeOverhang + size.height + _sendOverhang,
        child: Stack(
          children: [
            PositionedDirectional(
              start: _badgeOverhang,
              top: _badgeOverhang,
              child: Tooltip(
                message: strings.clipboardImageOfferAttach,
                child: Semantics(
                  button: true,
                  child: Material(
                    color: scheme.surfaceContainerHigh,
                    elevation: 6,
                    shadowColor: scheme.shadow,
                    surfaceTintColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: scheme.outlineVariant),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: const Key('clipboard-image-offer-attach'),
                      onTap: widget.onAttach,
                      child: RawImage(
                        image: image,
                        width: size.width,
                        height: size.height,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            PositionedDirectional(
              start: 0,
              top: 0,
              child: IconButton(
                key: const Key('clipboard-image-offer-dismiss'),
                tooltip: strings.clipboardImageOfferDismiss,
                onPressed: widget.onDismiss,
                iconSize: 16,
                // A 24 dp disc inside the full 48 dp touch target.
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.padded,
                  minimumSize: const Size.square(24),
                  fixedSize: const Size.square(24),
                  padding: EdgeInsets.zero,
                  backgroundColor: scheme.surfaceContainerHighest,
                  foregroundColor: scheme.onSurface,
                  elevation: 2,
                  shadowColor: scheme.shadow,
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            PositionedDirectional(
              end: 0,
              bottom: 0,
              child: IconButton.filled(
                key: const Key('clipboard-image-offer-send'),
                tooltip: strings.clipboardImageOfferSend,
                onPressed: widget.onSend,
                // Smaller than the composer's own send button, so the two
                // are not read as one control; the target stays 48 dp.
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.padded,
                  minimumSize: const Size.square(40),
                  fixedSize: const Size.square(40),
                  iconSize: 20,
                  elevation: 3,
                  shadowColor: scheme.shadow,
                ),
                icon: const Icon(Icons.send_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
