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
/// On a phone the clipboard is looked at while the field has focus and the
/// app is in front; on a desktop while the window is on screen, focused or
/// not, because the screenshot is taken next to it. A clip's content is read
/// once and kept until the clip is answered or replaced, or the app is
/// hidden.
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

  /// The message field's focus: on a phone nothing is read while it is
  /// elsewhere.
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

  /// The identity of the image now on the clipboard, for [answer] once that
  /// image went into the composer some other way, such as Ctrl+V.
  static Future<String?> currentClip(ClipboardImageSource? source) async {
    try {
      return await source?.peek();
    } on Object {
      return null;
    }
  }

  /// Marks the clip [id] as answered in every pane, so no tile offers it
  /// again until something new is copied.
  static void answer(
    String id,
    ClipboardImageSource source,
    ClipboardOfferMemory memory,
  ) => _ClipboardImageOfferState._answer(id, source, memory);

  /// Forgets which clip was last sent or dismissed, as a restart of the app
  /// does to what is only held in memory.
  @visibleForTesting
  static void debugForgetHandledClip() {
    _ClipboardImageOfferState._handledClip.value = null;
    _ClipboardImageOfferState._unreadable = null;
    _ClipboardImageOfferState._restoring = null;
    _ClipboardImageOfferState._lastRead = null;
    _ClipboardImageOfferState._inFlight = null;
  }

  @override
  ConsumerState<ClipboardImageOffer> createState() =>
      _ClipboardImageOfferState();
}

/// [raw] and [thumbnail] are null where the content may only be read once
/// the person takes the suggestion.
typedef _Offer = ({String id, Uint8List? raw, ui.Image? thumbnail});

final class _ClipboardImageOfferState extends ConsumerState<ClipboardImageOffer>
    with WidgetsBindingObserver {
  final LayerLink _anchor = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  /// The clip the user already answered, in any room and any pane: it is not
  /// offered again until something new is copied. Every pane listens, so a
  /// tile answered in a thread does not stay behind in the room under it.
  static final ValueNotifier<String?> _handledClip = ValueNotifier<String?>(
    null,
  );

  /// A clip whose content arrived and is no image the engine decodes. Not
  /// stored: it only keeps the same clip from being read on every look.
  static String? _unreadable;

  /// Restores [_handledClip] from [ClipboardOfferMemory] once; every look
  /// waits for it, so none offers a clip answered before a restart.
  static Future<void>? _restoring;

  /// The content of the last clip read. Another room, or a return from a
  /// lost focus, offers it again without reading it again, which on Android
  /// would raise the system's paste notice each time.
  static ({String id, Uint8List raw})? _lastRead;

  /// The read under way, which a second pane looking at the same clip joins
  /// instead of copying the whole bitmap once more.
  static ({String id, Future<Uint8List?> bytes})? _inFlight;

  ClipboardImageSource? _source;
  _Offer? _offer;
  int _round = 0;

  /// The clip being read right now and the round reading it. A check that
  /// finds the same clip leaves that read alone instead of starting over.
  ({String id, int round})? _reading;

  /// The clip being taken: while the system asks the person, the app goes
  /// inactive and back, and that must not offer the same clip again.
  String? _taking;
  bool _foreground = true;
  bool _listening = false;

  /// Logical pixels between the top bar and the composer, measured after
  /// layout. The tile is fitted into them, and left out where it does not
  /// fit, such as a phone held sideways with the keyboard open.
  double? _spaceAbove;

  static void _answer(
    String id,
    ClipboardImageSource source,
    ClipboardOfferMemory memory,
  ) {
    _handledClip.value = id;
    if (_lastRead?.id == id) {
      _lastRead = null;
    }
    if (source.survivesRestart(id)) {
      unawaited(memory.write(id));
    }
  }

  @override
  void initState() {
    super.initState();
    _source = ref.read(clipboardImageSourceProvider);
    _portal.show();
    _foreground = _visible(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    widget.focusNode.addListener(_check);
    widget.refresh.addListener(_handleRefresh);
    _handledClip.addListener(_handleAnswered);
    _listen(_foreground);
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
    if (oldWidget.sending && !widget.sending) {
      // A screenshot taken while the last message went out was skipped.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.focusNode.removeListener(_check);
    widget.refresh.removeListener(_handleRefresh);
    _handledClip.removeListener(_handleAnswered);
    _listen(false);
    _round++;
    _offer = null;
    super.dispose();
  }

  /// Follows the clipboard's change signal only while the app is on screen;
  /// on Windows that signal is a timer.
  void _listen(bool on) {
    final changes = _source?.changes;
    if (changes == null || on == _listening) {
      return;
    }
    _listening = on;
    if (on) {
      changes.addListener(_check);
    } else {
      changes.removeListener(_check);
    }
  }

  /// Resumed, and on a desktop also inactive: a window that lost the focus
  /// to the screenshot tool is still on screen.
  bool _visible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      (state == AppLifecycleState.inactive &&
          (_source?.offersWhileVisible ?? false));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _visible(state);
    _listen(_foreground);
    if (_foreground) {
      unawaited(_check());
    } else if (state != AppLifecycleState.inactive) {
      // Inactive is also a desktop window that merely lost focus, or a
      // permission dialog; the image only has to go once the app is hidden.
      _round++;
      _reading = null;
      _lastRead = null;
      if (_offer != null) {
        _drop();
        // A hidden app gets no frames on its own, and the card on screen
        // still holds the picture until one is built.
        WidgetsBinding.instance.scheduleForcedFrame();
      }
    }
  }

  @override
  void didChangeMetrics() {
    // The keyboard or a resize moved the composer.
    if (_offer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureSpace());
    }
  }

  void _handleRefresh() {
    if (widget.blocked()) {
      _drop();
    } else {
      // A screenshot taken while the composer was busy was skipped.
      unawaited(_check());
    }
  }

  void _handleAnswered() {
    final offer = _offer;
    if (offer != null && offer.id == _handledClip.value) {
      _drop();
    }
  }

  void _measureSpace() {
    final box = mounted ? context.findRenderObject() : null;
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return;
    }
    final view = View.of(context);
    final top = view.padding.top / view.devicePixelRatio + kToolbarHeight;
    final space = box.localToGlobal(Offset.zero).dy - top;
    if (_spaceAbove == null || (space - _spaceAbove!).abs() >= 1) {
      setState(() => _spaceAbove = space);
    }
  }

  Future<void> _check() async {
    final source = _source;
    if (source == null ||
        !mounted ||
        !_foreground ||
        (!source.offersWhileVisible && !widget.focusNode.hasFocus) ||
        widget.blocked()) {
      return;
    }
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    bool gone() => !mounted || !_foreground || widget.blocked();
    final id = await ClipboardImageOffer.currentClip(
      source,
    ).timeout(const Duration(seconds: 1), onTimeout: () => null);
    if (gone()) {
      return;
    }
    if (id == null) {
      // A read still running is for an image that is no longer there.
      _round++;
      _reading = null;
      _lastRead = null;
      _drop();
      return;
    }
    await (_restoring ??= () async {
      _handledClip.value ??= await ref
          .read(clipboardOfferMemoryProvider)
          .read();
    }());
    if (gone()) {
      return;
    }
    if (id == _handledClip.value || id == _unreadable) {
      _drop();
      return;
    }
    if (id == _offer?.id || id == _reading?.id || id == _taking) {
      return;
    }
    final round = ++_round;
    bool stale() => gone() || round != _round;
    // The tile must not keep showing, and sending, the picture before this
    // one while the new one is read, or when reading it fails.
    _drop();
    if (source.readNeedsConsent) {
      final offer = (id: id, raw: null, thumbnail: null);
      setState(() => _offer = offer);
      return;
    }
    _reading = (id: id, round: round);
    try {
      await _readAndOffer(source, id, pixelRatio, stale);
    } finally {
      if (_reading?.round == round) {
        _reading = null;
      }
    }
  }

  Future<void> _readAndOffer(
    ClipboardImageSource source,
    String id,
    double pixelRatio,
    bool Function() stale,
  ) async {
    var raw = _lastRead?.id == id ? _lastRead!.raw : null;
    if (raw == null) {
      // Null is a clipboard another program still holds open, or one that
      // changed in the meantime; neither says anything about this clip, so
      // it is asked again on a later look. No time limit: an owner that
      // renders on demand may take a while, and a newer clip makes this
      // read stale anyway.
      for (var attempt = 0; attempt < 3 && raw == null; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (stale()) {
            return;
          }
        }
        try {
          raw = await _readOnce(source, id);
        } on Object {
          raw = null;
        }
      }
      if (raw == null || stale()) {
        return;
      }
      // The identity was taken before the content. A tool that writes in
      // steps may have moved on in between; that newer clip is read anew.
      if (await ClipboardImageOffer.currentClip(source) != id) {
        if (!stale()) {
          unawaited(_check());
        }
        return;
      }
      _lastRead = (id: id, raw: raw);
    }
    ui.Image? thumbnail;
    try {
      thumbnail = await _decodeThumbnail(
        raw,
        (ClipboardImageOfferCard.maximumHeight * pixelRatio).round(),
      );
    } on Object {
      thumbnail = null;
    }
    if (thumbnail == null) {
      _unreadable = id;
      if (_lastRead?.id == id) {
        _lastRead = null;
      }
      return;
    }
    if (stale() || id == _handledClip.value) {
      thumbnail.dispose();
      return;
    }
    final offer = (id: id, raw: raw, thumbnail: thumbnail);
    setState(() => _offer = offer);
  }

  static Future<Uint8List?> _readOnce(ClipboardImageSource source, String id) {
    final running = _inFlight;
    if (running != null && running.id == id) {
      return running.bytes;
    }
    final bytes = source.read();
    _inFlight = (id: id, bytes: bytes);
    void done() {
      if (identical(_inFlight?.bytes, bytes)) {
        _inFlight = null;
      }
    }

    unawaited(bytes.then<void>((_) => done(), onError: (Object _) => done()));
    return bytes;
  }

  /// The picture at the size it is shown, decoded by the engine off the UI
  /// thread; the full screenshot never becomes a bitmap here. [extent] is
  /// what the shorter side needs, the most the cropped tile can show of it.
  /// A picture smaller than that keeps its own size.
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
    final source = _source;
    if (source != null) {
      _answer(id, source, ref.read(clipboardOfferMemoryProvider));
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
    final source = _source;
    if (offer == null || source == null) {
      return;
    }
    // Cleared before the first await, so a second tap finds nothing to send.
    _drop();
    _taking = offer.id;
    try {
      // Only what the tile showed: the clipboard may hold something newer by
      // now, and the tile for that is on its way.
      if (await ClipboardImageOffer.currentClip(source) != offer.id) {
        return;
      }
      var raw = offer.raw;
      if (raw == null) {
        // The system asks the person here and waits for the answer. A
        // refusal leaves the clip unanswered, for the next look to offer.
        try {
          raw = await source.read().timeout(const Duration(minutes: 1));
        } on Object {
          raw = null;
        }
      }
      final image = raw == null ? null : await normalizePastedImage(raw);
      if (image == null || !mounted) {
        return;
      }
      _answered(offer.id);
      final attached = await widget.onAttach(image);
      if (send && attached && mounted) {
        widget.onSend();
      }
    } finally {
      _taking = null;
      if (mounted) {
        unawaited(_check());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nothing of the offer takes part in the composer's layout: this is a
    // point at the composer's top edge, and the tile hangs above it in the
    // overlay, over the end of the message list.
    return LayoutBuilder(
      builder: (context, constraints) => CompositedTransformTarget(
        link: _anchor,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) =>
              _buildOverlay(context, constraints.maxWidth),
          child: const SizedBox(width: double.infinity),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context, double paneWidth) {
    final offer = _offer;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    if (offer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureSpace());
    }
    final space = _spaceAbove;
    final maxHeight = space == null
        ? 0.0
        : math.min(
            ClipboardImageOfferCard.maximumHeight,
            space - 16 - ClipboardImageOfferCard.overhang,
          );
    final child =
        offer == null || maxHeight < ClipboardImageOfferCard.minimumSide
        ? const SizedBox.shrink()
        // Part of the field's own tap region, so a tap on the tile does not
        // take the focus, and with it the soft keyboard, away.
        : TextFieldTapRegion(
            key: ValueKey<String>(offer.id),
            child: ClipboardImageOfferCard(
              thumbnail: offer.thumbnail,
              // Half the pane at most, so the tile never covers a narrow chat.
              maxWidth: paneWidth / 2,
              maxHeight: maxHeight,
              onAttach: () => unawaited(_take(send: false)),
              onDismiss: _dismiss,
              // Without a preview the person has not seen the picture yet:
              // it goes into the composer first, where they do.
              offersSend: offer.raw != null,
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
        child: AnimatedSwitcher(
          // A hidden app gets no frames to play an exit in, so a new switcher
          // drops the card at once. A change of the motion setting keeps
          // this one, and with it the card and its picture.
          key: ValueKey<bool>(offer == null && !_foreground),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
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
              alignment: rtl ? Alignment.bottomLeft : Alignment.bottomRight,
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
    this.maxWidth = maximumWidth,
    this.maxHeight = maximumHeight,
    this.offersSend = true,
    super.key,
  });

  /// The box the picture is fitted into; it keeps its own shape inside.
  static const double maximumWidth = 220;
  static const double maximumHeight = 160;

  /// Neither side gets smaller than this, so a thin strip stays a tile and
  /// the middle of the picture stays clear of the send button's 48 dp
  /// target. Also the side of the tile shown without a preview.
  static const double minimumSide = 96;

  /// How far the two buttons reach past the picture, both together: the
  /// badge is centred on its corner, the send button sits a quarter out.
  static const double overhang = _badgeOverhang + _sendOverhang;
  static const double _badgeOverhang = 18;
  static const double _sendOverhang = 12;

  /// How large a picture of [width] x [height] pixels is drawn: in its own
  /// shape, cropped past 3:1, and never larger than it is on a screen of
  /// [pixelRatio], than [maximumWidth] x [maximumHeight], or than [maxWidth]
  /// x [maxHeight].
  static Size tileSize(
    int width,
    int height, {
    double maxWidth = maximumWidth,
    double maxHeight = maximumHeight,
    double pixelRatio = 1,
  }) {
    final aspect = (width / height).clamp(1 / 3, 3.0);
    var tileWidth = math.min(
      math.min(maximumWidth, maxWidth),
      width / pixelRatio,
    );
    var tileHeight = tileWidth / aspect;
    final heightLimit = math.min(maximumHeight, maxHeight);
    if (tileHeight > heightLimit) {
      tileHeight = heightLimit;
      tileWidth = tileHeight * aspect;
    }
    return Size(
      math.max(minimumSide, tileWidth),
      math.max(minimumSide, tileHeight),
    );
  }

  /// Null where the content is read only once the suggestion is taken.
  final ui.Image? thumbnail;
  final double maxWidth;
  final double maxHeight;

  /// Moves the image into the composer, where it can get a caption.
  final VoidCallback onAttach;
  final VoidCallback onDismiss;

  /// Whether the tile has its own send button.
  final bool offersSend;

  /// Null while a send is already in flight.
  final VoidCallback? onSend;

  @override
  State<ClipboardImageOfferCard> createState() =>
      _ClipboardImageOfferCardState();
}

final class _ClipboardImageOfferCardState
    extends State<ClipboardImageOfferCard> {
  @override
  void dispose() {
    widget.thumbnail?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final image = widget.thumbnail;
    final size = image == null
        ? const Size.square(ClipboardImageOfferCard.minimumSide)
        : ClipboardImageOfferCard.tileSize(
            image.width,
            image.height,
            maxWidth: widget.maxWidth,
            maxHeight: widget.maxHeight,
            pixelRatio: MediaQuery.devicePixelRatioOf(context),
          );
    return Semantics(
      container: true,
      liveRegion: true,
      label: strings.clipboardImageOfferTitle,
      child: SizedBox(
        key: const Key('clipboard-image-offer'),
        width: size.width + ClipboardImageOfferCard.overhang,
        height: size.height + ClipboardImageOfferCard.overhang,
        child: Stack(
          children: [
            PositionedDirectional(
              start: ClipboardImageOfferCard._badgeOverhang,
              top: ClipboardImageOfferCard._badgeOverhang,
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
                      child: image == null
                          ? SizedBox.fromSize(
                              size: size,
                              child: Icon(
                                Icons.image_outlined,
                                size: 40,
                                color: scheme.onSurfaceVariant,
                              ),
                            )
                          : RawImage(
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
            if (widget.offersSend)
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
