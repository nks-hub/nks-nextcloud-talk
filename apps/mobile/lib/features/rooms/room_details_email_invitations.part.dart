part of 'room_details_screen.dart';

/// Picks the CSV to import. Injected so a widget test can supply a file
/// without a platform channel.
typedef PickInvitationCsv = Future<XFile?> Function(XTypeGroup typeGroup);

Future<XFile?> pickInvitationCsvFromPlatform(XTypeGroup typeGroup) {
  return openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
}

extension _RoomDetailsEmailInvitationsState on _RoomDetailsStateLogic {
  /// Talk gates the CSV import behind its own capability; the endpoint is
  /// moderator-only and, like every other membership action, only exists on a
  /// group or public conversation.
  bool get _canImportEmailInvitations =>
      _isModerator &&
      _isGroupOrPublic &&
      _talkFeatures.contains(_emailCsvImportCapability);

  /// Resending has no capability of its own — it is the same participants
  /// endpoint the import feeds — so it is offered where there is somebody to
  /// resend to: a moderator, and at least one e-mail attendee in the loaded
  /// participant list.
  bool _canResendEmailInvitations(List<Participant> participants) =>
      _isModerator && participants.any(_isEmailAttendee);

  bool _isEmailAttendee(Participant participant) =>
      participant.actorType == _emailActorType;

  Future<void> _importEmailInvitations() async {
    if (_busy) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final XFile? file;
    try {
      file = await widget.csvPicker(
        XTypeGroup(
          label: strings.roomDetailsEmailInvitationsFileTypeLabel,
          extensions: const <String>['csv'],
          mimeTypes: const <String>['text/csv', 'text/comma-separated-values'],
          uniformTypeIdentifiers: const <String>[
            'public.comma-separated-values-text',
          ],
        ),
      );
    } on Object {
      if (mounted) {
        _showMessage(strings.roomDetailsEmailInvitationsFileUnreadable);
      }
      return;
    }
    if (file == null || !mounted) {
      return;
    }

    final Uint8List csvBytes;
    try {
      csvBytes = await file.readAsBytes();
    } on Object {
      if (mounted) {
        _showMessage(strings.roomDetailsEmailInvitationsFileUnreadable);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    if (csvBytes.isEmpty) {
      _showMessage(strings.roomDetailsEmailInvitationsFileUnreadable);
      return;
    }
    // The bound is checked here, before anything is uploaded: a moderator with
    // an export of a whole address book should be told to split it, not watch
    // a phone push megabytes at a server that never published a limit.
    if (csvBytes.length > emailInvitationCsvMaximumBytes) {
      _showMessage(
        strings.roomDetailsEmailInvitationsFileTooLarge(
          emailInvitationCsvMaximumBytes ~/ 1024,
        ),
      );
      return;
    }

    final fileName = _invitationCsvFileName(file.name);
    final preview = await _runEmailInvitationImport(
      csvBytes: csvBytes,
      fileName: fileName,
      testRun: true,
    );
    if (preview == null || !mounted) {
      return;
    }

    final confirmed = await _confirmEmailInvitationSend(preview);
    if (confirmed != true || !mounted) {
      return;
    }

    final sent = await _runEmailInvitationImport(
      csvBytes: csvBytes,
      fileName: fileName,
      testRun: false,
    );
    if (sent == null || !mounted) {
      return;
    }
    _showMessage(strings.roomDetailsEmailInvitationsSent(sent.invites));
    _retry();
  }

  /// Runs one leg of the import and turns every refusal into a message. A
  /// `null` result means the caller must stop: the failure was already shown
  /// and must never be retried on its own.
  Future<EmailInvitationImportResult?> _runEmailInvitationImport({
    required Uint8List csvBytes,
    required String fileName,
    required bool testRun,
  }) async {
    _setBusy(true);
    try {
      return await ref
          .read(roomSettingsServiceProvider)
          .importEmailInvitations(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            csvBytes: csvBytes,
            fileName: fileName,
            testRun: testRun,
          );
    } on EmailInvitationInvalidRowsException catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).roomDetailsEmailInvitationsInvalidRows(
            error.invalidLines.join(', '),
          ),
        );
      }
      return null;
    } on EmailInvitationFileRejectedException catch (error) {
      if (mounted) {
        _showMessage(
          error.message ??
              AppLocalizations.of(
                context,
              ).roomDetailsEmailInvitationsFileRejected,
        );
      }
      return null;
    } on RoomSettingsException catch (error) {
      _showActionError(_emailInvitationErrorMessage, error.code);
      return null;
    } finally {
      if (mounted) {
        _setBusy(false);
      }
    }
  }

  Future<bool?> _confirmEmailInvitationSend(
    EmailInvitationImportResult preview,
  ) {
    final strings = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-email-invitations-preview'),
        title: Text(strings.roomDetailsEmailInvitationsPreviewTitle),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.roomDetailsEmailInvitationsPreviewInvites(
                preview.invites,
              ),
              key: const Key('room-details-email-invitations-invites'),
            ),
            const SizedBox(height: 4),
            Text(
              strings.roomDetailsEmailInvitationsPreviewDuplicates(
                preview.duplicates,
              ),
              key: const Key('room-details-email-invitations-duplicates'),
            ),
            const SizedBox(height: 12),
            Text(
              strings.roomDetailsEmailInvitationsPreviewNothingSent,
              key: const Key('room-details-email-invitations-nothing-sent'),
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('room-details-email-invitations-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('room-details-email-invitations-send'),
            // Nothing to send is not a decision worth offering; the moderator
            // is left with the preview and the way out.
            onPressed: preview.invites == 0
                ? null
                : () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsEmailInvitationsSendConfirm),
          ),
        ],
      ),
    );
  }

  Future<void> _resendAllEmailInvitations() async {
    if (_busy) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-resend-invitations-dialog'),
        title: Text(strings.roomDetailsResendInvitationsDialogTitle),
        scrollable: true,
        content: Text(strings.roomDetailsResendInvitationsDialogMessage),
        actions: [
          TextButton(
            key: const Key('room-details-resend-invitations-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('room-details-resend-invitations-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsResendInvitationsConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _resendEmailInvitations(
      attendeeId: null,
      confirmation: strings.roomDetailsResendInvitationsSent,
    );
  }

  Future<void> _resendInvitationTo(Participant participant) {
    return _resendEmailInvitations(
      attendeeId: participant.attendeeId,
      confirmation: AppLocalizations.of(
        context,
      ).roomDetailsResendInvitationSent,
    );
  }

  /// A resend is a message leaving the server, so a failure is reported and
  /// the call stops there. Nothing here ever repeats the request.
  Future<void> _resendEmailInvitations({
    required int? attendeeId,
    required String confirmation,
  }) async {
    _setBusy(true);
    try {
      await ref
          .read(roomSettingsServiceProvider)
          .resendEmailInvitations(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            attendeeId: attendeeId,
          );
      if (mounted) {
        _showMessage(confirmation);
      }
    } on RoomSettingsException catch (error) {
      _showActionError(_emailInvitationErrorMessage, error.code);
    } finally {
      if (mounted) {
        _setBusy(false);
      }
    }
  }
}

/// A device file name is only used as the multipart part's name, and the
/// contract refuses separators and quotes; anything unusable falls back to a
/// neutral one rather than failing the import over cosmetics.
String _invitationCsvFileName(String deviceName) {
  final trimmed = deviceName.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 255 ||
      trimmed.contains('/') ||
      trimmed.contains(r'\') ||
      trimmed.contains('"') ||
      trimmed.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
    return 'invitations.csv';
  }
  return trimmed;
}

/// Same as [_actionErrorMessage] except for [RoomSettingsError.ambiguous],
/// which here means invitations may or may not have been mailed.
String _emailInvitationErrorMessage(
  AppLocalizations strings,
  RoomSettingsError code,
) {
  return code == RoomSettingsError.ambiguous
      ? strings.roomDetailsEmailInvitationsUncertain
      : _actionErrorMessage(strings, code);
}
