part of 'chat_room_pane.dart';

extension _ChatRoomPaneTyping on _ChatRoomPaneState {
  void _handleComposerChanged() {
    _scheduleDraftSave();
    _syncTypingActivity(composerChanged: true);
  }

  void _handleComposerFocusChanged() => _syncTypingActivity();

  void _setTypingScope(ChatTypingRoomKey? key, {required bool canPost}) {
    if (_activeTypingKey == key && _typingCanPost == canPost) {
      return;
    }
    final previous = _activeTypingKey;
    _activeTypingKey = key;
    _typingCanPost = canPost;
    if (previous != null && previous != key) {
      unawaited(
        ref.read(chatTypingActivityProvider(previous))(_typingSource, false),
      );
    }
    _scheduleTypingActivitySync();
  }

  void _scheduleTypingActivitySync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncTypingActivity();
      }
    });
  }

  void _syncTypingActivity({
    bool composerChanged = false,
    bool forceInactive = false,
  }) {
    final key = _activeTypingKey;
    if (key == null) {
      return;
    }
    final update = chatTypingActivityUpdate(
      composerChanged: composerChanged,
      canPost: _typingCanPost,
      hasFocus: _composerFocusNode.hasFocus,
      text: _composer.text,
      forceInactive: forceInactive,
    );
    if (update == ChatTypingActivityUpdate.unchanged) {
      return;
    }
    final active = update == ChatTypingActivityUpdate.active;
    unawaited(ref.read(chatTypingActivityProvider(key))(_typingSource, active));
  }

  List<String> _typingDisplayNames(
    ChatTypingState? state, {
    required List<CachedChatMessage> messages,
    required CachedConversation conversation,
    required String guestLabel,
  }) {
    if (state == null ||
        state.availability != ChatTypingAvailability.available ||
        state.participants.isEmpty) {
      return const <String>[];
    }
    final messageNames = <String, String>{};
    for (final message in messages) {
      final name = message.actorDisplayName.trim();
      if (message.actorId.isNotEmpty && name.isNotEmpty) {
        messageNames[message.actorId] = name;
      }
    }
    final identities = <String>{};
    final names = <String>[];
    for (final participant in state.participants) {
      if (!identities.add(participant.identity)) {
        continue;
      }
      final name = participant.displayName.trim().isNotEmpty
          ? participant.displayName.trim()
          : messageNames[participant.actorId] ??
                (conversation.roomType == _oneToOneRoomType
                    ? conversation.displayName
                    : guestLabel);
      names.add(name);
    }
    return names;
  }
}

final class ChatTypingBanner extends StatelessWidget {
  const ChatTypingBanner({super.key, required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final text = _text(AppLocalizations.of(context));
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.bottomCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: text == null
          ? const SizedBox.shrink(key: Key('chat-typing-indicator-hidden'))
          : Semantics(
              key: const Key('chat-typing-indicator'),
              liveRegion: true,
              label: text,
              excludeSemantics: true,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  String? _text(AppLocalizations strings) => switch (names.length) {
    0 => null,
    1 => strings.typingOne(names[0]),
    2 => strings.typingTwo(names[0], names[1]),
    3 => strings.typingThree(names[0], names[1], names[2]),
    4 => strings.typingOneOther(names[0], names[1], names[2]),
    _ => strings.typingOthers(names[0], names[1], names[2], names.length - 3),
  };
}
