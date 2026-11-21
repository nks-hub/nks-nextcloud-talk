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

  Future<void> _pickCalendar() async {
    final selected = await showDialog<CalendarEntry>(
      context: context,
      builder: (context) => _MeetingCalendarDialog(
        calendars: widget.calendars,
        selectedUri: _calendarUri,
      ),
    );
    if (selected != null && mounted && !_submitted) {
      setState(() => _calendarUri = selected.uri);
    }
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
            _MeetingCalendarField(
              key: const Key('room-details-meeting-calendar'),
              label: strings.roomDetailsMeetingCalendarLabel,
              value: widget.calendars
                  .firstWhere((calendar) => calendar.uri == _calendarUri)
                  .displayName,
              onTap: _submitted ? null : _pickCalendar,
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
              isExpanded: true,
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

final class _MeetingCalendarField extends StatelessWidget {
  const _MeetingCalendarField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, enabled: onTap != null),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }
}

final class _MeetingCalendarDialog extends StatefulWidget {
  const _MeetingCalendarDialog({
    required this.calendars,
    required this.selectedUri,
  });

  final List<CalendarEntry> calendars;
  final String selectedUri;

  @override
  State<_MeetingCalendarDialog> createState() => _MeetingCalendarDialogState();
}

final class _MeetingCalendarDialogState extends State<_MeetingCalendarDialog> {
  var _query = '';

  List<CalendarEntry> get _visibleCalendars {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return widget.calendars;
    }
    return widget.calendars
        .where(
          (calendar) =>
              calendar.displayName.toLowerCase().contains(query) ||
              calendar.uri.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final calendars = _visibleCalendars;
    final material = MaterialLocalizations.of(context);
    final strings = AppLocalizations.of(context);
    return Dialog(
      key: const Key('room-details-meeting-calendar-dialog'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.roomDetailsMeetingCalendarLabel,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: material.closeButtonLabel,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('room-details-meeting-calendar-search'),
                autofocus: widget.calendars.length > 12,
                decoration: InputDecoration(
                  labelText: material.searchFieldLabel,
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  key: const Key('room-details-meeting-calendar-list'),
                  itemCount: calendars.length,
                  itemBuilder: (context, index) {
                    final calendar = calendars[index];
                    return ListTile(
                      key: Key(
                        'room-details-meeting-calendar-option-${calendar.uri}',
                      ),
                      title: Text(calendar.displayName),
                      trailing: calendar.uri == widget.selectedUri
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.of(context).pop(calendar),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
