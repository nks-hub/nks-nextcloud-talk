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
    this.compactReply,
  });

  final bool compact;
  final Widget field;
  final Widget mediaComposer;
  final Color dividerColor;
  final Widget? compactReply;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const fieldFloor = 96.0;
        const actionsViewport = 344.0;
        const actionSize = 48.0;
        final reply = compact ? compactReply : null;
        final replyWidth = reply == null
            ? 0.0
            : (constraints.maxWidth / 4).clamp(actionSize, 192.0);
        final contentWidth = (constraints.maxWidth - replyWidth - 1).clamp(
          0.0,
          double.infinity,
        );
        final mediaWidth = compact
            ? (contentWidth - fieldFloor).clamp(
                contentWidth.clamp(0.0, actionSize),
                actionsViewport,
              )
            : null;
        final fieldWidth = mediaWidth == null
            ? null
            : contentWidth - mediaWidth;
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
              height: compact ? actionSize : 1,
              child: ColoredBox(color: dividerColor),
            ),
            SizedBox(
              width: mediaWidth,
              height: compact ? actionSize : null,
              child: Padding(
                padding: compact
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: mediaComposer,
              ),
            ),
            if (reply != null)
              SizedBox(width: replyWidth, height: actionSize, child: reply),
          ],
        );
      },
    );
  }
}

final class CompactChatReplyPreview extends StatelessWidget {
  const CompactChatReplyPreview({
    super.key,
    required this.label,
    required this.cancel,
  });

  final String label;
  final Widget cancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: Tooltip(
              message: label,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        SizedBox.square(dimension: 48, child: cancel),
      ],
    );
  }
}
