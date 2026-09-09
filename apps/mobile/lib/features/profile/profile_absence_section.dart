import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../network/nextcloud_api.dart';
import 'profile_models.dart';

/// What the absence editor came back with, or `null` when it was dismissed.
typedef AbsenceDraft = ({
  DateTime firstDay,
  DateTime lastDay,
  String status,
  String message,
  String? replacementUserId,
});

/// This account's own absence: what the server holds, and the two actions
/// that change it.
///
/// The peer banner in a conversation reads somebody else's absence; this is
/// the same record from the other side, for the person who owns it.
final class ProfileAbsenceSection extends StatelessWidget {
  const ProfileAbsenceSection({
    required this.snapshot,
    required this.submitting,
    required this.onEdit,
    required this.onClear,
    super.key,
  });

  final OwnProfileSnapshot snapshot;
  final bool submitting;
  final VoidCallback onEdit;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (!snapshot.absenceCapability.supported) {
      return const SizedBox.shrink();
    }
    final strings = AppLocalizations.of(context);
    final absence = snapshot.absence;
    return Card(
      key: const Key('profile-absence'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.profileAbsenceTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (absence == null)
              Text(
                strings.profileAbsenceNone,
                key: const Key('profile-absence-none'),
              )
            else ...[
              Text(
                strings.profileAbsenceRange(
                  absenceDayText(absence.firstDay),
                  absenceDayText(absence.lastDay),
                ),
                key: const Key('profile-absence-range'),
              ),
              if (absence.status.isNotEmpty)
                Text(
                  absence.status,
                  key: const Key('profile-absence-status'),
                ),
              if (absence.message.isNotEmpty)
                Text(
                  absence.message,
                  key: const Key('profile-absence-message'),
                ),
              if (absence.replacementUserDisplayName case final String name
                  when name.isNotEmpty)
                Text(
                  strings.profileAbsenceReplacement(name),
                  key: const Key('profile-absence-replacement'),
                ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('profile-absence-edit'),
                  onPressed: submitting ? null : onEdit,
                  icon: const Icon(Icons.event_busy_outlined),
                  label: Text(
                    absence == null
                        ? strings.profileAbsenceSet
                        : strings.profileAbsenceEdit,
                  ),
                ),
                if (absence != null)
                  OutlinedButton.icon(
                    key: const Key('profile-absence-clear'),
                    onPressed: submitting ? null : onClear,
                    icon: const Icon(Icons.clear_rounded),
                    label: Text(strings.profileAbsenceClear),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Collects an absence. Returns `null` when the sheet is dismissed.
///
/// The days come from the platform's own range picker rather than two typed
/// fields: it already refuses a last day before the first, which is the one
/// mistake the server rejects outright.
Future<AbsenceDraft?> showAbsenceEditor(
  BuildContext context, {
  required OwnOutOfOffice? current,
  required bool replacementSupported,
}) {
  return showDialog<AbsenceDraft>(
    context: context,
    builder: (dialogContext) => _AbsenceDialog(
      current: current,
      replacementSupported: replacementSupported,
    ),
  );
}

final class _AbsenceDialog extends StatefulWidget {
  const _AbsenceDialog({
    required this.current,
    required this.replacementSupported,
  });

  final OwnOutOfOffice? current;
  final bool replacementSupported;

  @override
  State<_AbsenceDialog> createState() => _AbsenceDialogState();
}

final class _AbsenceDialogState extends State<_AbsenceDialog> {
  late DateTime _firstDay;
  late DateTime _lastDay;
  late final TextEditingController _status;
  late final TextEditingController _message;
  late final TextEditingController _replacement;

  @override
  void initState() {
    super.initState();
    final today = DateUtils.dateOnly(DateTime.now());
    _firstDay = widget.current?.firstDay ?? today;
    _lastDay = widget.current?.lastDay ?? today;
    _status = TextEditingController(text: widget.current?.status ?? '');
    _message = TextEditingController(text: widget.current?.message ?? '');
    _replacement = TextEditingController(
      text: widget.current?.replacementUserId ?? '',
    );
  }

  @override
  void dispose() {
    _status.dispose();
    _message.dispose();
    _replacement.dispose();
    super.dispose();
  }

  Future<void> _pickDays() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: _firstDay, end: _lastDay),
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 5),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _firstDay = DateUtils.dateOnly(picked.start);
      _lastDay = DateUtils.dateOnly(picked.end);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('profile-absence-dialog'),
      title: Text(strings.profileAbsenceTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              key: const Key('profile-absence-days'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.date_range_outlined),
              title: Text(strings.profileAbsenceDays),
              subtitle: Text(
                strings.profileAbsenceRange(
                  absenceDayText(_firstDay),
                  absenceDayText(_lastDay),
                ),
                key: const Key('profile-absence-days-value'),
              ),
              onTap: _pickDays,
            ),
            TextField(
              key: const Key('profile-absence-status-field'),
              controller: _status,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: strings.profileAbsenceStatusLabel,
              ),
            ),
            TextField(
              key: const Key('profile-absence-message-field'),
              controller: _message,
              maxLength: 500,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: strings.profileAbsenceMessageLabel,
              ),
            ),
            if (widget.replacementSupported)
              TextField(
                key: const Key('profile-absence-replacement-field'),
                controller: _replacement,
                maxLength: 64,
                decoration: InputDecoration(
                  labelText: strings.profileAbsenceReplacementLabel,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('profile-absence-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('profile-absence-save'),
          onPressed: () => Navigator.of(context).pop((
            firstDay: _firstDay,
            lastDay: _lastDay,
            status: _status.text.trim(),
            message: _message.text.trim(),
            replacementUserId: widget.replacementSupported
                ? _replacement.text.trim()
                : null,
          )),
          child: Text(strings.profileStatusSave),
        ),
      ],
    );
  }
}
