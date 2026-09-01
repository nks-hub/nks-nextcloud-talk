part of 'room_details_screen.dart';

mixin _RoomBotsStateLogic
    on ConsumerState<RoomDetailsScreen>, _RoomDetailsStateLogic {
  Future<List<TalkBot>>? _bots;
  final Set<int> _pendingBotIds = <int>{};

  bool get _canManageBots {
    final role = participantRoleFor(_room?.participantType ?? -1);
    final attributes = _room?.wire['attributes'];
    final classified =
        attributes is int &&
        (attributes & _classifiedRoomAttribute) == _classifiedRoomAttribute;
    return (role == ParticipantRole.owner ||
            role == ParticipantRole.moderator) &&
        !classified &&
        _talkFeatures.contains(_botsCapability);
  }

  Future<List<TalkBot>> _loadBots() {
    return ref
        .read(botsServiceProvider)
        .fetchBots(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
        );
  }

  void _expandBots(bool expanded) {
    if (!expanded || _bots != null) {
      return;
    }
    setState(() {
      _bots = _loadBots();
    });
  }

  void _retryBots() {
    setState(() {
      _bots = _loadBots();
    });
  }

  Future<void> _changeBotState(
    TalkBot bot,
    List<TalkBot> currentBots,
    bool enabled,
  ) async {
    if (_pendingBotIds.contains(bot.id)) {
      return;
    }
    setState(() => _pendingBotIds.add(bot.id));
    try {
      final updated = await ref
          .read(botsServiceProvider)
          .setEnabled(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            botId: bot.id,
            enabled: enabled,
          );
      if (!mounted) {
        return;
      }
      final next = <TalkBot>[
        for (final item in currentBots) item.id == updated.id ? updated : item,
      ];
      setState(() {
        _bots = Future<List<TalkBot>>.value(next);
      });
    } on BotsServiceException {
      if (mounted) {
        setState(() {
          _bots = _loadBots();
        });
        _showMessage(AppLocalizations.of(context).roomDetailsBotsLoadFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _pendingBotIds.remove(bot.id));
      }
    }
  }

  Widget _buildBotsSection(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return ExpansionTile(
      key: const Key('room-details-bots'),
      leading: const Icon(Icons.smart_toy_outlined),
      title: Text(strings.roomDetailsBotsTitle),
      onExpansionChanged: _expandBots,
      children: [
        FutureBuilder<List<TalkBot>>(
          future: _bots,
          builder: (context, snapshot) {
            if (_bots == null ||
                snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                key: Key('room-details-bots-loading'),
                height: 72,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                key: const Key('room-details-bots-error'),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Column(
                  children: [
                    Text(strings.roomDetailsBotsLoadFailed),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 48,
                      child: TextButton.icon(
                        key: const Key('room-details-bots-retry'),
                        onPressed: _retryBots,
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          MaterialLocalizations.of(
                            context,
                          ).refreshIndicatorSemanticLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            final bots = snapshot.data ?? const <TalkBot>[];
            if (bots.isEmpty) {
              return Padding(
                key: const Key('room-details-bots-empty'),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(strings.roomDetailsBotsEmpty),
                ),
              );
            }
            return Column(
              children: [
                for (final bot in bots)
                  _BotTile(
                    bot: bot,
                    pending: _pendingBotIds.contains(bot.id),
                    onChanged: bot.state == BotState.noSetup
                        ? null
                        : (enabled) => _changeBotState(bot, bots, enabled),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

final class _BotTile extends StatelessWidget {
  const _BotTile({
    required this.bot,
    required this.pending,
    required this.onChanged,
  });

  final TalkBot bot;
  final bool pending;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final enabled = bot.state != BotState.disabled;
    final stateLabel = enabled
        ? strings.roomDetailsBotEnabled
        : strings.roomDetailsBotDisabled;
    final actionLabel = enabled
        ? strings.roomDetailsBotDisable
        : strings.roomDetailsBotEnable;
    return Semantics(
      label: onChanged == null ? stateLabel : actionLabel,
      child: SwitchListTile(
        key: Key('room-details-bot-${bot.id}'),
        secondary: pending
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.smart_toy_outlined),
        title: Text(bot.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (bot.description case final description?
                when description.isNotEmpty)
              Text(description),
            Text(stateLabel),
          ],
        ),
        value: enabled,
        onChanged: pending ? null : onChanged,
      ),
    );
  }
}
