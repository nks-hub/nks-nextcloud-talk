part of 'room_details_screen.dart';

extension _RoomDetailsBackground on _RoomDetailsScreenState {
  ({String accountId, String roomToken}) get _chatBackgroundKey =>
      (accountId: widget.account.id, roomToken: widget.conversation.token);

  Future<void> _changeChatBackground() => _runChatBackgroundAction(() async {
    final strings = AppLocalizations.of(context);
    final store = await ref.read(chatBackgroundStoreProvider.future);
    if (!mounted) {
      return;
    }
    final current = await store.read(_chatBackgroundKey);
    if (!mounted) {
      return;
    }
    final pick = await pickColor(
      context: context,
      title: strings.roomDetailsChatBackgroundAction,
      current: current,
      fieldLabel: strings.roomDetailsAvatarColorLabel,
      normalize: (text) =>
          parseChatBackgroundColor(text) == null ? null : text.toUpperCase(),
      onInvalid: () => _showMessage(strings.roomDetailsActionErrorGeneric),
      paletteKey: const Key('chat-background-palette'),
      promptKey: const Key('chat-background-dialog'),
      fieldKey: const Key('chat-background-field'),
      confirmKey: const Key('chat-background-save'),
    );
    if (!mounted || pick == null) {
      return;
    }
    final value = pick.value;
    if (value == null) {
      await store.remove(_chatBackgroundKey);
      return;
    }
    await store.write(_chatBackgroundKey, value);
  });

  Future<void> _resetChatBackground() => _runChatBackgroundAction(() async {
    final store = await ref.read(chatBackgroundStoreProvider.future);
    await store.remove(_chatBackgroundKey);
  });

  Future<void> _runChatBackgroundAction(Future<void> Function() action) async {
    if (_busy || !mounted) {
      return;
    }
    _setBusy(true);
    try {
      await action();
    } on Object {
      // Path-provider and filesystem backends do not share one stable error
      // type, but a preference write must never escape the settings UI.
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).roomDetailsActionErrorGeneric,
        );
      }
    } finally {
      if (mounted) {
        _setBusy(false);
      }
    }
  }
}
