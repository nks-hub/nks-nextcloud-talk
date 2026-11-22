part of 'chat_media_composer.dart';

bool _usesCompactChatComposerLayout(FlutterView view) {
  if (view.viewInsets.bottom <= 0) {
    return false;
  }
  final availableHeight =
      (view.physicalSize.height - view.viewInsets.bottom) /
      view.devicePixelRatio;
  return availableHeight < 240;
}

bool usesCompactChatComposerLayout(BuildContext context) {
  final scoped = context
      .dependOnInheritedWidgetOfExactType<_ChatComposerLayoutScope>();
  return scoped?.compactHeight ??
      _usesCompactChatComposerLayout(View.of(context));
}

final class ChatComposerViewportLayout extends StatefulWidget {
  const ChatComposerViewportLayout({super.key, required this.builder});

  final Widget Function(BuildContext context, bool compactHeight) builder;

  static EdgeInsets padding(bool compactHeight) =>
      EdgeInsets.symmetric(horizontal: 12, vertical: compactHeight ? 2 : 10);

  @override
  State<ChatComposerViewportLayout> createState() =>
      _ChatComposerViewportLayoutState();
}

final class _ChatComposerViewportLayoutState
    extends State<ChatComposerViewportLayout>
    with WidgetsBindingObserver {
  bool? _compactHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }
    final compactHeight = _usesCompactChatComposerLayout(View.of(context));
    if (compactHeight != _compactHeight) {
      setState(() => _compactHeight = compactHeight);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compactHeight = _usesCompactChatComposerLayout(View.of(context));
    _compactHeight = compactHeight;
    return _ChatComposerLayoutScope(
      compactHeight: compactHeight,
      child: widget.builder(context, compactHeight),
    );
  }
}

final class _ChatComposerLayoutScope extends InheritedWidget {
  const _ChatComposerLayoutScope({
    required this.compactHeight,
    required super.child,
  });

  final bool compactHeight;

  @override
  bool updateShouldNotify(_ChatComposerLayoutScope oldWidget) =>
      compactHeight != oldWidget.compactHeight;
}

final class AdaptiveChatComposerLayout extends StatelessWidget {
  const AdaptiveChatComposerLayout({
    super.key,
    required this.compact,
    required this.field,
    required this.mediaComposer,
    required this.dividerColor,
  });

  final bool compact;
  final Widget field;
  final Widget mediaComposer;
  final Color dividerColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const fieldFloor = 96.0;
        const actionsViewport = 344.0;
        final mediaWidth = compact
            ? (constraints.maxWidth - fieldFloor - 1).clamp(
                0.0,
                actionsViewport,
              )
            : null;
        final fieldWidth = compact
            ? (constraints.maxWidth - (mediaWidth ?? 0) - 1).clamp(
                fieldFloor,
                constraints.maxWidth,
              )
            : null;
        return Flex(
          direction: compact ? Axis.horizontal : Axis.vertical,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: compact
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: fieldWidth, child: field),
            SizedBox(
              width: compact ? 1 : null,
              height: compact ? 48 : 1,
              child: ColoredBox(color: dividerColor),
            ),
            SizedBox(
              width: mediaWidth,
              height: compact ? 48 : null,
              child: Padding(
                padding: compact
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: mediaComposer,
              ),
            ),
          ],
        );
      },
    );
  }
}
