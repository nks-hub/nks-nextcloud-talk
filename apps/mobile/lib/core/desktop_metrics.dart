import 'package:flutter/material.dart';

/// The fixed widget dimensions that dominate how big the app feels.
///
/// `VisualDensity` cannot reach them — they are fixed box constraints and
/// avatar radii — so they need a platform-aware source of their own. The
/// platform decision is read back from the theme's [VisualDensity], which
/// Flutter already resolves per platform, rather than introducing a second
/// signal that could disagree with the theme.
///
/// Reference for the desktop values is Nextcloud's own web client: a two-line
/// conversation row is 53 px, an avatar in that row is 44 px and the server
/// header is 44 px.
extension AppMetrics on BuildContext {
  bool get _pointerFirst => Theme.of(this).visualDensity.vertical < 0;

  /// Width of the conversation list pane. Nextcloud's own navigation column is
  /// a flat 300 regardless of window size; the wider touch values only pay off
  /// when the row has to stay readable under a finger.
  // ponytail: fixed per platform, not a draggable splitter. Add the splitter
  // when someone actually asks to resize it — it needs its own Dart-side
  // persistence, since the window bounds live in the native runner.
  double get listPaneWidth =>
      _pointerFirst ? 300 : (MediaQuery.sizeOf(this).width >= 1100 ? 390 : 330);

  /// Height of one conversation row in the list.
  double get listRowHeight => _pointerFirst ? 56 : 80;

  /// Radius of the avatar shown in a conversation row.
  double get listAvatarRadius => _pointerFirst ? 20 : 24;

  /// Minimum height of a pane header — the conversation list header and the
  /// chat room header both use it, so they stay aligned with each other.
  double get paneHeaderHeight => _pointerFirst ? 52 : 72;

  /// Height of a secondary list row, such as a thread in the thread list.
  /// Shorter than [listRowHeight] because the row carries no unread badge.
  double get secondaryRowHeight => _pointerFirst ? 52 : 72;

  /// Height of an action row inside a card, such as "Rename thread".
  double get actionRowHeight => _pointerFirst ? 44 : 56;

  /// Whether Enter sends a message and Shift+Enter breaks the line.
  ///
  /// The desktop convention, and what `nextcloud/talk-desktop` does. On touch
  /// the send button is the only way to send and Enter is the only way to get
  /// a new line, so it stays a plain newline there.
  bool get sendsOnEnter => _pointerFirst;

  /// Maximum width of a settings-style column of rows.
  ///
  /// A row that stretches the whole window puts its label at one edge and its
  /// control at the other, which on a 1400 px window leaves over a thousand
  /// pixels of nothing between them and reads as a blown-up phone screen.
  /// Reference is Nextcloud's own `#app-content .section`, which caps at
  /// 700 px. Touch keeps the full width: a phone is never wide enough for the
  /// gap to matter.
  double get contentColumnWidth => _pointerFirst ? 700 : double.infinity;
}

/// Caps [child] at [AppMetrics.contentColumnWidth] and centres it.
///
/// Wraps a whole scroll view rather than each row, so every row inside picks
/// the cap up at once and none of them can drift out of agreement.
final class ContentColumn extends StatelessWidget {
  const ContentColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: context.contentColumnWidth),
        child: child,
      ),
    );
  }
}
