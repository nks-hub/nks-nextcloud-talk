part of 'room_details_screen.dart';

/// How long a meeting lasts unless the person changes it.
const Duration _defaultMeetingDuration = Duration(hours: 1);

extension _RoomDetailsMeetingState on _RoomDetailsStateLogic {
  /// Talk gates this behind its own capability. Not moderator-only: the server
  /// accepts it from any participant, measured on 9 September 2026.
  bool get _canScheduleMeeting =>
      _talkFeatures.contains(_scheduleMeetingCapability);

  Future<void> _scheduleMeeting() async {
    if (_busy) {
      return;
    }
    final strings = AppLocalizations.of(context);
    _setBusy(true);
    final List<CalendarEntry> calendars;
    try {
      calendars = await ref
          .read(roomSettingsServiceProvider)
          .listCalendars(accountId: widget.account.id);
    } on RoomSettingsException catch (error) {
      if (mounted) {
        _setBusy(false);
        _showMessage(_actionErrorMessage(strings, error.code));
      }
      return;
    } finally {
      if (mounted && _busy) {
        _setBusy(false);
      }
    }
    if (!mounted) {
      return;
    }
    if (calendars.isEmpty) {
      _showMessage(strings.roomDetailsMeetingNoCalendars);
      return;
    }

    final draft = await showDialog<_MeetingDraft>(
      context: context,
      builder: (context) => _MeetingDialog(calendars: calendars),
    );
    if (draft == null || !mounted) {
      return;
    }

    _setBusy(true);
    try {
      await ref
          .read(roomSettingsServiceProvider)
          .scheduleMeeting(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            calendarUri: draft.calendarUri,
            start: draft.start,
            end: draft.start.add(draft.duration),
            title: draft.title,
          );
      if (mounted) {
        _showMessage(strings.roomDetailsMeetingScheduled);
      }
    } on RoomSettingsException catch (error) {
      if (mounted) {
        _showMessage(_meetingErrorMessage(strings, error));
      }
    } finally {
      if (mounted) {
        _setBusy(false);
      }
    }
  }
}

String _meetingErrorMessage(
  AppLocalizations strings,
  RoomSettingsException error,
) {
  if (error.code == RoomSettingsError.ambiguous) {
    return strings.roomDetailsMeetingAmbiguous;
  }
  if (error.code == RoomSettingsError.rejected) {
    return switch (error.message) {
      'calendar' => strings.roomDetailsMeetingCalendarRefused,
      'email' => strings.roomDetailsMeetingNoEmail,
      'start' => strings.roomDetailsMeetingStartInThePast,
      'end' => strings.roomDetailsMeetingEndBeforeStart,
      _ => strings.roomDetailsMeetingFailed,
    };
  }
  if (error.code == RoomSettingsError.serviceUnavailable) {
    return strings.roomDetailsMeetingCalendarRefused;
  }
  return _actionErrorMessage(strings, error.code);
}

@immutable
final class _MeetingDraft {
  const _MeetingDraft({
    required this.calendarUri,
    required this.start,
    required this.duration,
    required this.title,
  });

  final String calendarUri;
  final DateTime start;
  final Duration duration;
  final String title;
}

/// Asks for the calendar, the moment and the name of the meeting.
///
/// The confirm button is disabled while the request runs, because the endpoint
/// does not deduplicate: a second tap writes a second event and invites
/// everybody again.
final class _MeetingDialog extends StatefulWidget {
  const _MeetingDialog({required this.calendars});

  final List<CalendarEntry> calendars;

  @override
  State<_MeetingDialog> createState() => _MeetingDialogState();
}

final class _MeetingDialogState extends State<_MeetingDialog> {
  late String _calendarUri = widget.calendars.first.uri;
  late DateTime _start = _nextWholeHour();
  Duration _duration = _defaultMeetingDuration;
  final _title = TextEditingController();
  bool _submitted = false;

  static DateTime _nextWholeHour() {
    final now = DateTime.now();
    return DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
    ).add(const Duration(hours: 1));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final strings = AppLocalizations.of(context);
    final day = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: strings.roomDetailsMeetingStartLabel,
    );
    if (day == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _start = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final startsInThePast = !_start.isAfter(DateTime.now());
    return AlertDialog(
      key: const Key('room-details-meeting-dialog'),
      title: Text(strings.roomDetailsMeetingAction),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const Key('room-details-meeting-calendar'),
              initialValue: _calendarUri,
              decoration: InputDecoration(
                labelText: strings.roomDetailsMeetingCalendarLabel,
              ),
              items: [
                for (final calendar in widget.calendars)
                  DropdownMenuItem<String>(
                    value: calendar.uri,
                    child: Text(calendar.displayName),
                  ),
              ],
              onChanged: _submitted
                  ? null
                  : (value) => setState(() => _calendarUri = value!),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('room-details-meeting-title'),
              controller: _title,
              enabled: !_submitted,
              maxLength: meetingMaximumTitleCharacters,
              decoration: InputDecoration(
                labelText: strings.roomDetailsMeetingTitleLabel,
              ),
            ),
            ListTile(
              key: const Key('room-details-meeting-start'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(strings.roomDetailsMeetingStartLabel),
              subtitle: Text(
                '${MaterialLocalizations.of(context).formatFullDate(_start)}, '
                '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_start))}',
              ),
              onTap: _submitted ? null : () => unawaited(_pickStart()),
            ),
            DropdownButtonFormField<int>(
              key: const Key('room-details-meeting-duration'),
              initialValue: _duration.inMinutes,
              decoration: InputDecoration(
                labelText: strings.roomDetailsMeetingDurationLabel,
              ),
              items: [
                for (final minutes in const <int>[15, 30, 60, 120, 240])
                  DropdownMenuItem<int>(
                    value: minutes,
                    child: Text(
                      strings.roomDetailsMeetingDurationMinutes(minutes),
                    ),
                  ),
              ],
              onChanged: _submitted
                  ? null
                  : (value) =>
                        setState(() => _duration = Duration(minutes: value!)),
            ),
            if (startsInThePast)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  strings.roomDetailsMeetingStartInThePast,
                  key: const Key('room-details-meeting-past-notice'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('room-details-meeting-cancel'),
          onPressed: _submitted ? null : () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('room-details-meeting-confirm'),
          onPressed: _submitted || startsInThePast
              ? null
              : () {
                  setState(() => _submitted = true);
                  Navigator.of(context).pop(
                    _MeetingDraft(
                      calendarUri: _calendarUri,
                      start: _start,
                      duration: _duration,
                      title: _title.text.trim(),
                    ),
                  );
                },
          child: Text(strings.roomDetailsMeetingConfirm),
        ),
      ],
    );
  }
}
