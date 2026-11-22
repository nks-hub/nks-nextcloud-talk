part of 'chat_media_composer.dart';

final class ChatMediaComposerStatus extends StatelessWidget {
  const ChatMediaComposerStatus.loading({
    super.key,
    this.leadingAction,
    this.idleActions = const <Widget>[],
    this.trailingActions = const <Widget>[],
  }) : unavailable = false,
       onRetry = null;

  const ChatMediaComposerStatus.unavailable({
    super.key,
    required this.onRetry,
    this.leadingAction,
    this.idleActions = const <Widget>[],
    this.trailingActions = const <Widget>[],
  }) : unavailable = true;

  final bool unavailable;
  final VoidCallback? onRetry;
  final Widget? leadingAction;
  final List<Widget> idleActions;
  final List<Widget> trailingActions;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final compact = usesCompactChatComposerLayout(context);
    final compactPinnedAction = compact && trailingActions.isNotEmpty
        ? trailingActions.last
        : null;
    final remainingTrailingActions = compact && trailingActions.isNotEmpty
        ? trailingActions.take(trailingActions.length - 1)
        : trailingActions;
    final status = unavailable
        ? strings.mediaCapabilityUnavailable
        : strings.mediaCapabilityChecking;
    if (compact) {
      return Semantics(
        label: status,
        child: SizedBox(
          key: Key(
            unavailable
                ? 'chat-media-composer-unavailable'
                : 'chat-media-composer-loading',
          ),
          height: 48,
          child: _ComposerActionToolbar(
            compact: true,
            compactPinnedAction: compactPinnedAction,
            leadingAction: leadingAction,
            actions: <Widget>[
              if (unavailable)
                IconButton(
                  key: const Key('retry-media-capabilities'),
                  onPressed: onRetry,
                  tooltip: strings.retryMediaCapabilities,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                ),
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
              ...remainingTrailingActions,
            ],
          ),
        ),
      );
    }
    return Column(
      key: Key(
        unavailable
            ? 'chat-media-composer-unavailable'
            : 'chat-media-composer-loading',
      ),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                status,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (unavailable)
              IconButton(
                key: const Key('retry-media-capabilities'),
                onPressed: onRetry,
                tooltip: strings.retryMediaCapabilities,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.refresh_rounded),
              ),
          ],
        ),
        _ComposerActionToolbar(
          leadingAction: leadingAction,
          actions: <Widget>[
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
            ...trailingActions,
          ],
        ),
      ],
    );
  }
}

final class _ComposerActionToolbar extends StatelessWidget {
  const _ComposerActionToolbar({
    required this.leadingAction,
    required this.actions,
    this.compact = false,
    this.compactPinnedAction,
  });

  final Widget? leadingAction;
  final List<Widget> actions;
  final bool compact;
  final Widget? compactPinnedAction;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Row(
        key: const Key('chat-media-composer-actions'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          ?compactPinnedAction,
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
