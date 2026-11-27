part of 'chat_room_pane.dart';

extension _ChatRoomPaneReminders on _ChatRoomPaneState {
  /// Opens the reminder options for [message] and applies the choice.
  ///
  /// The existing reminder is read first so the sheet can offer to remove it;
  /// Talk answers "no reminder here" with a `404`, which the service reports
  /// as `null` rather than as a failure.
  Future<void> _openReminder(CachedChatMessage message) =>
      _runGuardedMessageAction(
        pending: _pendingReminderActions,
        messageId: message.messageId,
        action: (targetKey) => _openReminderGuarded(message, targetKey),
      );

  Future<void> _openConditionalReminder(
    CachedChatMessage message,
    ChatMessage? parsed,
  ) => _runGuardedMessageAction(
    pending: _pendingReminderActions,
    messageId: message.messageId,
    action: (key) => _openConditionalReminderGuarded(message, parsed, key),
  );

  Future<void> _openConditionalReminderGuarded(
    CachedChatMessage message,
    ChatMessage? parsed,
    ChatRoomProviderKey key,
  ) async {
    final service = ref.read(ownTalkExtensionsServiceProvider);
    Future<Map<String, dynamic>> call(
      String method, [
      Map<String, Object?>? values,
    ]) => service.roomMessageTool(
      accountId: key.accountId,
      roomToken: key.roomToken,
      messageId: message.messageId,
      tool: RoomMessageTool.followup,
      method: method,
      values: values,
    );
    try {
      final current = await call('GET');
      if (!mounted || _key != key) return;
      final due = current['dueAt'] as int?;
      final selected = await showReminderSheet(
        context: context,
        now: DateTime.now(),
        title: AppLocalizations.of(context).unansweredReminder,
        existing: due == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(due * 1000),
      );
      if (selected == null || !mounted || _key != key) return;
      final at = selected.at;
      if (selected.action == ReminderSheetAction.remove) {
        await call('DELETE');
      } else if (at != null) {
        if (!at.isAfter(DateTime.now())) {
          _showActionNotice(
            AppLocalizations.of(context).scheduleTimeInPast,
            const Key('conditional-reminder-past'),
          );
          return;
        }
        final saved = await call('PUT', {
          'dueAt': at.millisecondsSinceEpoch ~/ 1000,
          'threadId':
              key.threadId ??
              (parsed?.isThread == true ? parsed?.threadId : null) ??
              0,
        });
        if (saved['dueAt'] == null) {
          if (mounted && _key == key) {
            _showActionNotice(
              AppLocalizations.of(context).unansweredReminderAlreadyAnswered,
              const Key('conditional-reminder-answered'),
            );
          }
          return;
        }
      }
      if (!mounted || _key != key) return;
      final strings = AppLocalizations.of(context);
      _showActionNotice(
        at == null
            ? strings.reminderRemoved
            : strings.reminderSet(formatMoment(context, at)),
        const Key('conditional-reminder-updated'),
      );
    } catch (_) {
      if (mounted && _key == key) {
        _showActionNotice(
          AppLocalizations.of(context).roomToolFailure,
          const Key('conditional-reminder-error'),
        );
      }
    }
  }

  Future<void> _openReminderGuarded(
    CachedChatMessage message,
    ChatRoomProviderKey targetKey,
  ) async {
    final service = ref.read(chatMessageActionsServiceProvider);
    RichChatReminder? existing;
    try {
      existing = await service.getReminder(
        accountId: targetKey.accountId,
        roomToken: targetKey.roomToken,
        messageId: message.messageId,
      );
    } on ChatMessageActionException catch (error) {
      _showScopedActionError(targetKey, error.code);
      return;
    } on Object {
      _showScopedActionError(targetKey, ChatMessageActionError.invalidResponse);
      return;
    }
    if (!mounted || targetKey != _key) {
      return;
    }
    final existingAt = existing == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            existing.timestamp * 1000,
          ).toLocal();
    final now = DateTime.now();
    final result = await showReminderSheet(
      context: context,
      now: now,
      existing: existingAt,
    );
    if (result == null || !mounted || targetKey != _key) {
      return;
    }
    final strings = AppLocalizations.of(context);
    try {
      switch (result.action) {
        case ReminderSheetAction.remove:
          await service.deleteReminder(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
          );
          if (mounted && targetKey == _key) {
            _showActionNotice(
              strings.reminderRemoved,
              const Key('chat-reminder-removed'),
            );
          }
        case ReminderSheetAction.set:
          final at = result.at!;
          if (!at.isAfter(DateTime.now())) {
            _showActionNotice(
              strings.scheduleTimeInPast,
              const Key('chat-reminder-past'),
            );
            return;
          }
          await service.setReminder(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
            timestamp: at.toUtc().millisecondsSinceEpoch ~/ 1000,
          );
          if (mounted && targetKey == _key) {
            _showActionNotice(
              strings.reminderSet(formatMoment(context, at)),
              const Key('chat-reminder-set'),
            );
          }
      }
    } on ChatMessageActionException catch (error) {
      _showScopedActionError(targetKey, error.code);
    } on Object {
      _showScopedActionError(targetKey, ChatMessageActionError.invalidResponse);
    }
  }
}
