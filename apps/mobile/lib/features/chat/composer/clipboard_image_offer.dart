import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'clipboard_image_source.dart';
import 'pasted_image.dart';

/// Offers the image waiting on the clipboard — usually a screenshot copied a
/// moment ago — above the message field, to be sent or dismissed in one tap.
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

  /// Forgets which clip was last sent or dismissed.
  @visibleForTesting
  static void debugForgetHandledClip() =>
      _ClipboardImageOfferState._handledClip = null;

  @override
  ConsumerState<ClipboardImageOffer> createState() =>
      _ClipboardImageOfferState();
}

typedef _Offer = ({String id, PastedImage image, ui.Image thumbnail});

final class _ClipboardImageOfferState extends ConsumerState<ClipboardImageOffer>
    with WidgetsBindingObserver {
  static const _thumbnailHeight = 72.0;

  /// The clip the user already answered, in any room: it is not offered again
  /// until something new is copied.
  // shortcut: kept for the life of the process, so a dismissed clip comes
  // back after an app restart; persist it if that turns out to annoy.
  static String? _handledClip;

  ClipboardImageSource? _source;
  _Offer? _offer;
  int _round = 0;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _source = ref.read(clipboardImageSourceProvider);
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
          (_thumbnailHeight * pixelRatio).round(),
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
  /// thread; the full screenshot never becomes a bitmap here.
  static Future<ui.Image> _decodeThumbnail(Uint8List bytes, int height) async {
    final codec = await ui.instantiateImageCodec(bytes, targetHeight: height);
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

  void _dismiss() {
    _handledClip = _offer?.id ?? _handledClip;
    _drop();
  }

  Future<void> _take({required bool send}) async {
    final offer = _offer;
    if (offer == null) {
      return;
    }
    // Cleared before the first await, so a second tap finds nothing to send.
    _handledClip = offer.id;
    _drop();
    final attached = await widget.onAttach(offer.image);
    if (send && attached && mounted) {
      widget.onSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = _offer;
    final child = offer == null
        ? const SizedBox.shrink()
        // Part of the field's own tap region, so a tap on the card does not
        // take the focus, and with it the soft keyboard, away.
        : TextFieldTapRegion(
            key: ValueKey<String>(offer.id),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipboardImageOfferCard(
                thumbnail: offer.thumbnail,
                onAttach: () => unawaited(_take(send: false)),
                onDismiss: _dismiss,
                onSend: widget.sending
                    ? null
                    : () => unawaited(_take(send: true)),
              ),
            ),
          );
    // Leaving the foreground skips the exit transition too: the frames that
    // would play it are not coming.
    if (MediaQuery.disableAnimationsOf(context) ||
        (offer == null && !_foreground)) {
      return child;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.bottomCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: child,
    );
  }
}

/// The suggestion itself: the picture, what it is, and the two answers.
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
  static const _thumbnailHeight = _ClipboardImageOfferState._thumbnailHeight;

  @override
  void dispose() {
    widget.thumbnail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final image = widget.thumbnail;
    // The picture keeps its shape; only a panorama or a very tall capture is
    // cropped to stay a thumbnail.
    final thumbnailWidth = (_thumbnailHeight * image.width / image.height)
        .clamp(48.0, _thumbnailHeight * 1.5);
    final thumbnail = Tooltip(
      message: strings.clipboardImageOfferAttach,
      child: Semantics(
        button: true,
        child: Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('clipboard-image-offer-attach'),
            onTap: widget.onAttach,
            child: RawImage(
              image: image,
              width: thumbnailWidth,
              height: _thumbnailHeight,
              fit: BoxFit.cover,
            ),
          ),
        ),
      ),
    );
    final title = Text(
      strings.clipboardImageOfferTitle,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurface),
    );
    final actions = <Widget>[
      IconButton(
        key: const Key('clipboard-image-offer-dismiss'),
        tooltip: strings.clipboardImageOfferDismiss,
        onPressed: widget.onDismiss,
        icon: const Icon(Icons.close_rounded),
      ),
      SizedBox.square(
        dimension: 48,
        child: IconButton.filled(
          key: const Key('clipboard-image-offer-send'),
          tooltip: strings.clipboardImageOfferSend,
          onPressed: widget.onSend,
          icon: const Icon(Icons.send_rounded),
        ),
      ),
    ];
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        key: const Key('clipboard-image-offer'),
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 4, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // What is left for the words beside the picture and the two
              // buttons. In a split view, with a wide picture or with large
              // text that is a column a few letters wide, so the title moves
              // above the row instead.
              final beside = constraints.maxWidth - thumbnailWidth - 12 - 96;
              final needed = MediaQuery.textScalerOf(context).scale(14) * 8.5;
              if (beside < needed) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 8, 8),
                      child: title,
                    ),
                    Row(children: [thumbnail, const Spacer(), ...actions]),
                  ],
                );
              }
              return Row(
                children: [
                  thumbnail,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        title,
                        const SizedBox(height: 2),
                        Text(
                          strings.clipboardImageOfferHint,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ...actions,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
