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
      EdgeInsets.symmetric(horizontal: 10, vertical: compactHeight ? 2 : 8);

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
    required this.mediaComposer,
    this.compactReply,
  });

  final bool compact;
  final Widget mediaComposer;
  final Widget? compactReply;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final reply = compact ? compactReply : null;
      return Row(
        children: [
          Expanded(child: mediaComposer),
          if (reply != null)
            SizedBox(
              width: (constraints.maxWidth / 4).clamp(48, 192),
              height: 48,
              child: reply,
            ),
        ],
      );
    },
  );
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
