part of 'room_details_screen.dart';

extension _RoomDetailsClearHistoryState on _RoomDetailsScreenState {
  bool get _canClearHistory =>
      _isModerator && _talkFeatures.contains(_clearHistoryCapability);

  Future<void> _confirmClearHistory() async {
    if (_busy) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-clear-history-dialog'),
        title: Text(strings.roomDetailsClearHistoryDialogTitle),
        content: Text(strings.roomDetailsClearHistoryDialogMessage),
        actions: [
          TextButton(
            key: const Key('room-details-clear-history-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('room-details-clear-history-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsClearHistoryConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    _setBusy(true);
    try {
      final result = await ref
          .read(roomSettingsServiceProvider)
          .clearHistory(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          );

      var refreshFailed = false;
      try {
        await ref
            .read(conversationSyncServiceProvider)
            .sync(widget.account.id, forceFull: true);
      } on Object {
        // The destructive request already succeeded. A refresh failure must
        // never make the user repeat a non-idempotent DELETE.
        refreshFailed = true;
      }
      if (!mounted) {
        return;
      }
      final message = result.externalCopiesMayRemain
          ? strings.roomDetailsClearHistoryExternalCopiesWarning
          : refreshFailed
          ? strings.roomDetailsClearHistoryRefreshFailed
          : strings.roomDetailsClearHistorySucceeded;
      _showMessage(message);
    } on RoomSettingsException catch (error) {
      _showActionError(_actionErrorMessage, error.code);
    } finally {
      if (mounted) {
        _setBusy(false);
      }
    }
  }
}
