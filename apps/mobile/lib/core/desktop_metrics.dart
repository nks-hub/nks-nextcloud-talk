import 'package:flutter/material.dart';

/// The three widget dimensions that dominate how big the app feels.
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

  /// Height of one conversation row in the list.
  double get listRowHeight => _pointerFirst ? 56 : 80;

  /// Radius of the avatar shown in a conversation row.
  double get listAvatarRadius => _pointerFirst ? 20 : 24;

  /// Minimum height of a pane header — the conversation list header and the
  /// chat room header both use it, so they stay aligned with each other.
  double get paneHeaderHeight => _pointerFirst ? 52 : 72;
}
