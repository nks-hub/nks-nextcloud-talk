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
  double get listPaneWidth => _pointerFirst
      ? 300
      : (MediaQuery.sizeOf(this).width >= 1100 ? 390 : 330);

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
}
