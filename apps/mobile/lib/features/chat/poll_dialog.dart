import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../l10n/generated/app_localizations.dart';
import 'poll_service.dart';
import 'media/chat_attachment_exporter.dart';

part 'poll_composer_dialog.dart';
part 'poll_viewer_dialog.dart';
part 'poll_management_actions.dart';
part 'poll_drafts_dialog.dart';

String _pollError(AppLocalizations strings, PollServiceError error) =>
    switch (error) {
      PollServiceError.unsupported => strings.pollUnsupported,
      PollServiceError.permissionDenied => strings.pollPermissionDenied,
      PollServiceError.reauthenticationRequired => strings.pollSignInAgain,
      PollServiceError.rateLimited => strings.pollRateLimited,
      PollServiceError.ambiguous => strings.pollAmbiguous,
      _ => strings.pollFailed,
    };
