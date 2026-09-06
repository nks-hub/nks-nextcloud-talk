/// Actions in a conversation header, and the rule that keeps the conversation
/// name visible next to them.
///
/// Five icon buttons and a back affordance leave a phone-width header with
/// nothing for the name. Measured on a Galaxy S9+ (1080 px, 420 dpi) with build
/// 62: the header showed an avatar and five icons, and the conversation name
/// was gone entirely — not truncated, not ellipsised, absent. It happened at
/// the device's own density and text size, so the report that blamed density
/// 440 was reading a symptom.
///
/// The rule here is that the name is served FIRST: the header keeps a floor of
/// width for the avatar and the name, and whatever no longer fits in the rest
/// folds into an overflow menu, in the order the actions are given. Callers put
/// the call controls first, because a menu is a poor place to start a call from.
library;

import 'package:flutter/material.dart';

/// One action in a conversation header. The same description renders either as
/// an icon button or as a row of the overflow menu.
final class ConversationHeaderAction {
  const ConversationHeaderAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// Key of the rendered control in BOTH forms, so a caller reaches the action
  /// wherever the width put it.
  final Key id;

  final IconData icon;

  /// Tooltip of the icon button and text of the menu row.
  final String label;

  /// `null` leaves the action visible but disabled, as Material does.
  final VoidCallback? onPressed;
}

/// What one icon button takes across, which is [IconButton]'s own minimum.
const double _actionExtent = kMinInteractiveDimension;

/// Width the avatar and the name keep before any action gets a slot.
///
/// The name's share scales with the text size, because that is what decides how
/// much of a name a given width shows.
double conversationTitleFloor(
  BuildContext context, {
  required double avatarExtent,
  required double gap,
}) =>
    avatarExtent + gap + MediaQuery.textScalerOf(context).scale(84);

/// Lays [actions] out for a header [width] logical pixels wide, after
/// [titleFloor] of it has been reserved for the avatar and the name.
///
/// Everything that fits stays an icon; the remainder moves into one overflow
/// menu, which itself takes a slot.
List<Widget> conversationHeaderActions(
  List<ConversationHeaderAction> actions, {
  required double width,
  required double titleFloor,
}) {
  final slots = ((width - titleFloor) / _actionExtent).floor();
  if (slots >= actions.length) {
    return [for (final action in actions) _HeaderActionButton(action: action)];
  }
  final visible = slots < 1 ? 0 : slots - 1;
  return [
    for (final action in actions.take(visible))
      _HeaderActionButton(action: action),
    _HeaderActionOverflow(
      actions: actions.skip(visible).toList(growable: false),
    ),
  ];
}

final class _HeaderActionButton extends StatelessWidget {
  const _HeaderActionButton({required this.action});

  final ConversationHeaderAction action;

  @override
  Widget build(BuildContext context) => IconButton(
    key: action.id,
    tooltip: action.label,
    icon: Icon(action.icon),
    onPressed: action.onPressed,
  );
}

final class _HeaderActionOverflow extends StatelessWidget {
  const _HeaderActionOverflow({required this.actions});

  final List<ConversationHeaderAction> actions;

  @override
  Widget build(BuildContext context) =>
      PopupMenuButton<ConversationHeaderAction>(
        key: const Key('conversation-header-overflow'),
        tooltip: MaterialLocalizations.of(context).showMenuTooltip,
        onSelected: (action) => action.onPressed?.call(),
        itemBuilder: (context) => [
          for (final action in actions)
            PopupMenuItem<ConversationHeaderAction>(
              key: action.id,
              value: action,
              enabled: action.onPressed != null,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(action.icon),
                title: Text(action.label),
              ),
            ),
        ],
      );
}
