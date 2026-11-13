import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../chat/chat_background_theme.dart';
import 'owntalk_room_extras.dart';

/// Colours a bubble is drawn with. [meta] is for the clock and secondary text;
/// [shared] says a conversation colour replaced the theme's pairing.
typedef BubbleColors = ({
  Color background,
  Color foreground,
  Color meta,
  bool shared,
});

/// The shared bubble colours of the conversation on screen, as `#RRGGBB`.
/// Provided by the chat surface so every bubble can read it without each one
/// subscribing to the provider.
final class SharedChatAppearance extends InheritedWidget {
  const SharedChatAppearance({
    super.key,
    required this.ownBubble,
    required this.ownText,
    required this.otherBubble,
    required this.otherText,
    required super.child,
  });

  factory SharedChatAppearance.fromExtras(
    OwnTalkRoomExtras extras, {
    Key? key,
    required Widget child,
  }) => SharedChatAppearance(
    key: key,
    ownBubble: extras.valueOf(OwnTalkSettingField.bubbleOwnColor),
    ownText: extras.valueOf(OwnTalkSettingField.bubbleOwnTextColor),
    otherBubble: extras.valueOf(OwnTalkSettingField.bubbleOtherColor),
    otherText: extras.valueOf(OwnTalkSettingField.bubbleOtherTextColor),
    child: child,
  );

  final String? ownBubble;
  final String? ownText;
  final String? otherBubble;
  final String? otherText;

  static SharedChatAppearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SharedChatAppearance>();

  @override
  bool updateShouldNotify(SharedChatAppearance oldWidget) =>
      ownBubble != oldWidget.ownBubble ||
      ownText != oldWidget.ownText ||
      otherBubble != oldWidget.otherBubble ||
      otherText != oldWidget.otherText;
}

/// Minimum contrast for message text against its bubble.
const double bubbleTextMinimumContrast = 4.5;

/// [preferred] when it reads on [background], otherwise whichever of black and
/// white reads better. One of the two always reaches at least 4.5:1.
Color readableTextColor(Color background, Color preferred) {
  if (chatBackgroundContrast(preferred, background) >=
      bubbleTextMinimumContrast) {
    return preferred;
  }
  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  return chatBackgroundContrast(black, background) >=
          chatBackgroundContrast(white, background)
      ? black
      : white;
}

/// Bubble colours for one message. Without a shared colour this is exactly the
/// theme's own pairing; a shared bubble or text colour is applied through the
/// contrast fallback, never as given.
BubbleColors resolveBubbleColors({
  required bool outgoing,
  required ColorScheme scheme,
  String? sharedBubble,
  String? sharedText,
}) {
  final defaultBackground = outgoing
      ? scheme.primaryContainer
      : scheme.surfaceContainerHigh;
  final defaultForeground = outgoing
      ? scheme.onPrimaryContainer
      : scheme.onSurface;
  final defaultMeta = outgoing
      ? scheme.onPrimaryContainer
      : scheme.onSurfaceVariant;
  final bubble = parseChatBackgroundColor(sharedBubble);
  final text = parseChatBackgroundColor(sharedText);
  if (bubble == null && text == null) {
    return (
      background: defaultBackground,
      foreground: defaultForeground,
      meta: defaultMeta,
      shared: false,
    );
  }
  final background = bubble ?? defaultBackground;
  final foreground = readableTextColor(background, text ?? defaultForeground);
  return (
    background: background,
    foreground: foreground,
    meta: foreground,
    shared: true,
  );
}
