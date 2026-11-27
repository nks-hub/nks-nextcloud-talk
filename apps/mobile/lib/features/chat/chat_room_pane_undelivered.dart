part of 'chat_room_pane.dart';

extension _ChatRoomUndelivered on _ChatRoomPaneState {
  /// [operations] with the rows of the replies sent from this pane.
  ///
  /// Without them a reply's stand-in was never replaced: its row never showed
  /// up, so the line stayed "queued" under a message long delivered.
  List<StoredTextSendOperation> _withOwnReplies(
    List<StoredTextSendOperation> operations,
  ) {
    if (_replyTargets.isEmpty) {
      return operations;
    }
    return [
      ...operations,
      for (final target in _replyTargets)
        ...?ref
            .watch(
              textSendOperationsProvider((
                accountId: _key.accountId,
                roomToken: _key.roomToken,
                threadId: target,
              )),
            )
            .valueOrNull
            ?.where((operation) => operation.replyTo == target),
    ]..sort((a, b) => a.enqueueSequence.compareTo(b.enqueueSequence));
  }

  UndeliveredMessage? _selectedUndeliveredMessage() {
    final selectedIssue = ref.watch(undeliveredSelectionProvider);
    if (selectedIssue != null &&
        selectedIssue.account == _key.accountId &&
        selectedIssue.room == _key.roomToken &&
        selectedIssue.thread == _key.threadId) {
      _openedIssue = selectedIssue;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            ref.read(undeliveredSelectionProvider) != selectedIssue) {
          return;
        }
        ref.read(undeliveredSelectionProvider.notifier).state = null;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
      });
    }
    return _openedIssue;
  }

  List<StoredTextSendOperation> _withUndeliveredSelection(
    List<StoredTextSendOperation> currentOperations,
    UndeliveredMessage? issue,
  ) {
    final selectedOperation =
        issue == null || issue.id.startsWith(_refusedDraftPrefix)
        ? null
        : ref.watch(selectedUndeliveredOperationProvider(issue)).valueOrNull;
    return selectedOperation != null &&
            !currentOperations.any(
              (row) => row.operationId == selectedOperation.operationId,
            )
        ? ([...currentOperations, selectedOperation]
            ..sort((a, b) => a.enqueueSequence.compareTo(b.enqueueSequence)))
        : currentOperations;
  }
}

extension _TimelineAnchor on _ChatTimeline {
  /// Chronological index the centre sliver ends at.
  ///
  /// Without an anchor that is the newest item, so nothing lands in the sliver
  /// before the centre. Once the reader has scrolled away the pane freezes the
  /// anchor on the newest message they had seen, and everything that arrives
  /// after it goes into the sliver that cannot move them.
  int _anchorChronologicalIndex(int itemCount) {
    if (selectedOperationId != null) {
      final index = pending.indexWhere(
        (p) => p.operationId == selectedOperationId,
      );
      if (index >= 0) return (hasOlder ? 1 : 0) + messages.length + index;
    }
    final anchor = anchorMessageId;
    if (anchor == null) {
      return itemCount - 1;
    }
    final offset = hasOlder ? 1 : 0;
    for (var index = messages.length - 1; index >= 0; index--) {
      if (messages[index].messageId <= anchor) {
        return index + offset;
      }
    }
    return itemCount - 1;
  }
}
