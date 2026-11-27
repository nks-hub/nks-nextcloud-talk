part of 'chat_media_composer.dart';

final class ChatMediaComposerStatus extends StatelessWidget {
  const ChatMediaComposerStatus.loading({
    super.key,
    this.field,
    this.leadingAction,
    this.idleActions = const <Widget>[],
    this.trailingActions = const <Widget>[],
  }) : unavailable = false,
       onRetry = null;

  const ChatMediaComposerStatus.unavailable({
    super.key,
    required this.onRetry,
    this.field,
    this.leadingAction,
    this.idleActions = const <Widget>[],
    this.trailingActions = const <Widget>[],
  }) : unavailable = true;

  final bool unavailable;
  final VoidCallback? onRetry;
  final Widget? field;
  final Widget? leadingAction;
  final List<Widget> idleActions;
  final List<Widget> trailingActions;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final compact = usesCompactChatComposerLayout(context);
    final pinAction = (compact || field != null) && trailingActions.isNotEmpty;
    final status = unavailable
        ? strings.mediaCapabilityUnavailable
        : strings.mediaCapabilityChecking;
    final retry = IconButton(
      key: const Key('retry-media-capabilities'),
      onPressed: onRetry,
      tooltip: strings.retryMediaCapabilities,
      icon: const Icon(Icons.refresh_rounded),
    );
    return Semantics(
      key: Key(
        unavailable
            ? 'chat-media-composer-unavailable'
            : 'chat-media-composer-loading',
      ),
      label: compact || !unavailable ? status : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (unavailable && !compact)
            Row(
              children: [
                Expanded(
                  child: Text(
                    status,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                retry,
              ],
            ),
          _ComposerActionToolbar(
            field: field,
            compact: compact,
            pinnedAction: pinAction ? trailingActions.last : null,
            leadingAction: leadingAction,
            actions: [
              if (unavailable && compact) retry,
              ...idleActions,
              SizedBox.square(
                dimension: 48,
                child: IconButton(
                  key: const Key('voice-record-unavailable'),
                  onPressed: null,
                  tooltip: strings.voiceUnsupported,
                  icon: const Icon(Icons.mic_none_rounded),
                ),
              ),
              ...trailingActions.take(
                trailingActions.length - (pinAction ? 1 : 0),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _ComposerActionToolbar extends StatelessWidget {
  const _ComposerActionToolbar({
    this.field,
    required this.leadingAction,
    required this.actions,
    this.compact = false,
    this.pinnedAction,
  });

  final Widget? field;
  final Widget? leadingAction;
  final List<Widget> actions;
  final bool compact;
  final Widget? pinnedAction;

  @override
  Widget build(BuildContext context) {
    final entry = field;
    if (entry != null) {
      final colors = Theme.of(context).colorScheme;
      final decoration = BoxDecoration(
        color: colors.surfaceContainerHigh,
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(14),
      );
      return Row(
        key: const Key('chat-media-composer-actions'),
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (leadingAction != null) ...[
            DecoratedBox(decoration: decoration, child: leadingAction),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: DecoratedBox(
              decoration: decoration,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const buttonSize = 48.0;
                  const entryWidth = 90.0;
                  final pinnedWidth = pinnedAction == null ? 0.0 : buttonSize;
                  final available = (constraints.maxWidth - pinnedWidth).clamp(
                    0.0,
                    double.infinity,
                  );
                  final actionWidth = (available - entryWidth).clamp(
                    available.clamp(0.0, buttonSize),
                    available,
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Center(widthFactor: 1, child: entry),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: actionWidth),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: actions,
                          ),
                        ),
                      ),
                      ?pinnedAction,
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      );
    }
    if (compact) {
      return Row(
        key: const Key('chat-media-composer-actions'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          ?pinnedAction,
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: <Widget>[?leadingAction, ...actions]),
            ),
          ),
        ],
      );
    }
    return Row(
      key: const Key('chat-media-composer-actions'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ?leadingAction,
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ),
        ),
      ],
    );
  }
}

final class _RecordingToolbar extends StatelessWidget {
  const _RecordingToolbar({required this.field, required this.controls});

  final Widget? field;
  final Widget controls;

  @override
  Widget build(BuildContext context) {
    final entry = field;
    return Row(
      key: const Key('chat-media-composer-actions'),
      children: [
        if (entry != null) Flexible(child: entry),
        Expanded(
          flex: 3,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: controls,
          ),
        ),
      ],
    );
  }
}
