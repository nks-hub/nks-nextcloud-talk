import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';

/// The conversation's pin, as the room reports it.
///
/// Talk keeps the pin on the room, not on the message: `lastPinnedId` is the
/// pinned message for everyone, `hiddenPinnedId` is what this account chose to
/// hide via `pin/self`. Pinning again resets every attendee's hidden ID
/// server-side, so equality is the only "hidden" state there is.
@immutable
final class PinnedMessageState {
  const PinnedMessageState({required this.messageId, required this.hidden});

  /// Reads the pin out of a cached conversation's stored room payload.
  ///
  /// The payload is read leniently on purpose: a conversation row cached by
  /// an older schema, or one a test wrote without a full room body, must
  /// simply report "no pin" rather than break the room.
  factory PinnedMessageState.fromCachedConversation(
    CachedConversation conversation,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(conversation.rawJson);
    } on FormatException {
      return const PinnedMessageState(messageId: 0, hidden: false);
    }
    if (decoded is! Map<String, Object?>) {
      return const PinnedMessageState(messageId: 0, hidden: false);
    }
    final pinned = decoded['lastPinnedId'];
    final hidden = decoded['hiddenPinnedId'];
    if (pinned is! int || pinned < 1) {
      return const PinnedMessageState(messageId: 0, hidden: false);
    }
    return PinnedMessageState(
      messageId: pinned,
      hidden: hidden is int && hidden == pinned,
    );
  }

  final int messageId;
  final bool hidden;

  bool get isVisible => messageId > 0 && !hidden;

  @override
  bool operator ==(Object other) =>
      other is PinnedMessageState &&
      other.messageId == messageId &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(messageId, hidden);
}

/// How many messages this account has scheduled in the conversation.
///
/// The room reports the count, not a flag, and only when the server has the
/// `scheduled-messages` capability - so an older cached row simply reports
/// zero. Read from the stored room payload for the same reason the pin is:
/// the Drift row keeps only the columns the conversation list needs.
int scheduledMessageCount(CachedConversation conversation) {
  final Object? decoded;
  try {
    decoded = jsonDecode(conversation.rawJson);
  } on FormatException {
    return 0;
  }
  if (decoded is! Map<String, Object?>) {
    return 0;
  }
  final count = decoded['hasScheduledMessages'];
  return count is int && count > 0 ? count : 0;
}

/// The strip above the timeline that shows the conversation's pinned message.
///
/// It renders whatever the local cache already holds for the pinned ID, and
/// falls back to a neutral label when the message has not been fetched yet.
///
/// ponytail: no fetch of its own. Talk has no single-message GET; the
/// documented way to materialize an arbitrary message is
/// `GET /chat/{token}/{messageId}/context` behind the `chat-get-context`
/// capability. Tapping the banner instead runs the room's existing jump,
/// which already pages history back until the message appears. Add the
/// context fetch when a pin far outside the loaded history needs its preview
/// visible without a tap.
final class PinnedMessageBanner extends ConsumerWidget {
  const PinnedMessageBanner({
    super.key,
    required this.account,
    required this.conversation,
    required this.pinned,
    required this.canHide,
    required this.onOpen,
    required this.onHide,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final PinnedMessageState pinned;
  final bool canHide;
  final void Function(int messageId) onOpen;
  final void Function(int messageId) onHide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!pinned.isVisible) {
      return const SizedBox.shrink();
    }
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cached = ref
        .watch(
          chatMessagesProvider((
            accountId: account.id,
            roomToken: conversation.token,
            threadId: null,
          )),
        )
        .valueOrNull;
    final preview = _preview(cached, pinned.messageId);

    return Material(
      color: scheme.secondaryContainer,
      child: Semantics(
        button: true,
        label: strings.pinnedMessageOpen,
        child: InkWell(
          key: const Key('chat-pinned-banner'),
          onTap: () => onOpen(pinned.messageId),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(
              children: [
                Icon(
                  Icons.push_pin_rounded,
                  size: 18,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.pinnedMessageLabel,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: scheme.onSecondaryContainer),
                        ),
                        if (preview != null)
                          Text(
                            preview,
                            key: const Key('chat-pinned-banner-preview'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSecondaryContainer),
                          ),
                      ],
                    ),
                  ),
                ),
                if (canHide)
                  IconButton(
                    key: const Key('chat-pinned-banner-hide'),
                    tooltip: strings.pinnedMessageHide,
                    onPressed: () => onHide(pinned.messageId),
                    icon: Icon(
                      Icons.close_rounded,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String? _preview(List<CachedChatMessage>? messages, int messageId) {
    if (messages == null) {
      return null;
    }
    for (final message in messages) {
      if (message.messageId == messageId) {
        final text = message.displayText.trim();
        return text.isEmpty ? null : text;
      }
    }
    return null;
  }
}

/// What the user picked in the reminder sheet.
enum ReminderSheetAction { set, remove }

@immutable
final class ReminderSheetResult {
  const ReminderSheetResult.set(DateTime this.at)
    : action = ReminderSheetAction.set;
  const ReminderSheetResult.remove()
    : action = ReminderSheetAction.remove,
      at = null;

  final ReminderSheetAction action;
  final DateTime? at;
}

/// Stable semantic identity for one offered moment.
enum TimePresetId {
  laterToday('later-today'),
  tomorrow('tomorrow'),
  thisWeekend('this-weekend'),
  nextWeek('next-week');

  const TimePresetId(this.keySegment);

  final String keySegment;
}

/// One offered moment, e.g. "tomorrow morning".
@immutable
final class TimePreset {
  const TimePreset(this.id, this.label, this.at);

  final TimePresetId id;
  final String label;
  final DateTime at;
}

/// The presets Talk's own documentation suggests for reminders: 6pm today,
/// 8am tomorrow, Saturday 8am and Monday 8am. Anything already in the past is
/// dropped, so the list shrinks as the day goes on rather than offering a
/// moment the server would refuse.
List<TimePreset> timePresets(AppLocalizations strings, DateTime now) {
  DateTime at(int addDays, int hour) {
    final day = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(Duration(days: addDays));
    return DateTime(day.year, day.month, day.day, hour);
  }

  // `DateTime.weekday` is 1 for Monday through 7 for Sunday.
  final daysUntilSaturday = (DateTime.saturday - now.weekday) % 7;
  final daysUntilMonday = (DateTime.monday - now.weekday) % 7;
  final candidates = <TimePreset>[
    TimePreset(TimePresetId.laterToday, strings.reminderLaterToday, at(0, 18)),
    TimePreset(TimePresetId.tomorrow, strings.reminderTomorrow, at(1, 8)),
    TimePreset(
      TimePresetId.thisWeekend,
      strings.reminderThisWeekend,
      at(daysUntilSaturday == 0 ? 7 : daysUntilSaturday, 8),
    ),
    TimePreset(
      TimePresetId.nextWeek,
      strings.reminderNextWeek,
      at(daysUntilMonday == 0 ? 7 : daysUntilMonday, 8),
    ),
  ];
  return candidates
      .where((preset) => preset.at.isAfter(now))
      .toList(growable: false);
}

/// Asks for a moment using the platform's own date and time pickers.
///
/// Both dialogs own and dispose their state, so nothing here has to.
Future<DateTime?> pickDateTime(BuildContext context, DateTime now) async {
  final date = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: DateTime(now.year + 2, now.month, now.day),
  );
  if (date == null || !context.mounted) {
    return null;
  }
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
  );
  if (time == null) {
    return null;
  }
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// Reminder options for one message. [existing] is the reminder the server
/// already holds, which is what makes "remove" meaningful.
Future<ReminderSheetResult?> showReminderSheet({
  required BuildContext context,
  required DateTime now,
  required DateTime? existing,
}) {
  final strings = AppLocalizations.of(context);
  return showModalBottomSheet<ReminderSheetResult>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            key: const Key('reminder-sheet-title'),
            title: Text(strings.reminderTitle),
            subtitle: existing == null
                ? null
                : Text(
                    strings.reminderExisting(
                      _formatMoment(sheetContext, existing),
                    ),
                  ),
          ),
          const Divider(height: 1),
          for (final preset in timePresets(strings, now))
            ListTile(
              key: Key('reminder-preset-${preset.id.keySegment}'),
              leading: const Icon(Icons.schedule_rounded),
              title: Text(preset.label),
              subtitle: Text(_formatMoment(sheetContext, preset.at)),
              onTap: () => Navigator.of(
                sheetContext,
              ).pop(ReminderSheetResult.set(preset.at)),
            ),
          ListTile(
            key: const Key('reminder-custom'),
            leading: const Icon(Icons.event_rounded),
            title: Text(strings.reminderCustom),
            onTap: () async {
              final picked = await pickDateTime(sheetContext, now);
              if (!sheetContext.mounted) {
                return;
              }
              Navigator.of(
                sheetContext,
              ).pop(picked == null ? null : ReminderSheetResult.set(picked));
            },
          ),
          if (existing != null)
            ListTile(
              key: const Key('reminder-remove'),
              leading: const Icon(Icons.alarm_off_rounded),
              title: Text(strings.reminderRemove),
              onTap: () => Navigator.of(
                sheetContext,
              ).pop(const ReminderSheetResult.remove()),
            ),
        ],
      ),
    ),
  );
}

/// Delivery-time options for a message that is about to be scheduled.
Future<DateTime?> showSendLaterSheet({
  required BuildContext context,
  required DateTime now,
}) {
  final strings = AppLocalizations.of(context);
  return showModalBottomSheet<DateTime>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            key: const Key('send-later-title'),
            title: Text(strings.scheduleMessageTitle),
          ),
          const Divider(height: 1),
          for (final preset in timePresets(strings, now))
            ListTile(
              key: Key('send-later-preset-${preset.id.keySegment}'),
              leading: const Icon(Icons.schedule_send_outlined),
              title: Text(preset.label),
              subtitle: Text(_formatMoment(sheetContext, preset.at)),
              onTap: () => Navigator.of(sheetContext).pop(preset.at),
            ),
          ListTile(
            key: const Key('send-later-custom'),
            leading: const Icon(Icons.event_rounded),
            title: Text(strings.reminderCustom),
            onTap: () async {
              final picked = await pickDateTime(sheetContext, now);
              if (!sheetContext.mounted) {
                return;
              }
              Navigator.of(sheetContext).pop(picked);
            },
          ),
        ],
      ),
    ),
  );
}

/// Lists what this account has scheduled in one conversation, and lets it
/// delete an entry.
///
/// The list is fetched once when the sheet opens. It is also the documented
/// way to settle an ambiguous schedule create: if the POST result was unclear,
/// what the server actually holds shows up here.
///
/// ponytail: no editing. `POST .../schedule/{id}` can change the text and the
/// time, but delete-and-schedule-again covers the same ground with no extra
/// UI; wire the edit route up when in-place editing is actually asked for.
final class ScheduledMessagesSheet extends ConsumerStatefulWidget {
  const ScheduledMessagesSheet({
    super.key,
    required this.accountId,
    required this.roomToken,
  });

  final String accountId;
  final String roomToken;

  @override
  ConsumerState<ScheduledMessagesSheet> createState() =>
      _ScheduledMessagesSheetState();
}

final class _ScheduledMessagesSheetState
    extends ConsumerState<ScheduledMessagesSheet> {
  List<RichChatScheduledMessage>? _messages;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final messages = await ref
          .read(chatMessageActionsServiceProvider)
          .listScheduledMessages(
            accountId: widget.accountId,
            roomToken: widget.roomToken,
          );
      if (mounted) {
        setState(() {
          _messages = messages;
          _failed = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  Future<void> _delete(RichChatScheduledMessage message) async {
    final strings = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .deleteScheduledMessage(
            accountId: widget.accountId,
            roomToken: widget.roomToken,
            scheduleId: message.scheduleId.value,
          );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('scheduled-message-deleted'),
            content: Text(strings.scheduledMessageDeleted),
          ),
        );
      await _load();
    } on Object {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final messages = _messages;
    return SafeArea(
      child: Column(
        key: const Key('scheduled-messages-sheet'),
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(strings.scheduledMessagesTitle)),
          const Divider(height: 1),
          // A bounded status line rather than a spinner: an indeterminate
          // progress indicator here would keep the whole tree animating.
          if (_failed)
            ListTile(
              key: const Key('scheduled-messages-error'),
              leading: const Icon(Icons.error_outline_rounded),
              title: Text(strings.chatUnavailable),
            )
          else if (messages == null)
            ListTile(
              key: const Key('scheduled-messages-loading'),
              title: Text(strings.syncing),
            )
          else if (messages.isEmpty)
            ListTile(
              key: const Key('scheduled-messages-empty'),
              title: Text(strings.scheduledMessagesEmpty),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: messages.length,
                itemBuilder: (itemContext, index) {
                  final message = messages[index];
                  return ListTile(
                    key: Key('scheduled-message-${message.scheduleId.value}'),
                    title: Text(
                      message.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _formatMoment(
                        itemContext,
                        DateTime.fromMillisecondsSinceEpoch(
                          message.sendAt * 1000,
                        ).toLocal(),
                      ),
                    ),
                    trailing: IconButton(
                      key: Key('delete-scheduled-${message.scheduleId.value}'),
                      tooltip: strings.scheduledMessageDelete,
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => unawaited(_delete(message)),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// A date and a clock time, both in the platform's own locale format.
String formatMoment(BuildContext context, DateTime value) =>
    _formatMoment(context, value);

String _formatMoment(BuildContext context, DateTime value) {
  final localizations = MaterialLocalizations.of(context);
  final local = value.toLocal();
  return '${localizations.formatMediumDate(local)} '
      '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}
