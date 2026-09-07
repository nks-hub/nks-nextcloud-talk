import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../l10n/generated/app_localizations.dart';
import 'poll_service.dart';

part 'poll_composer_dialog.dart';
part 'poll_viewer_dialog.dart';

String _pollError(AppLocalizations strings, PollServiceError error) =>
    switch (error) {
      PollServiceError.unsupported => strings.pollUnsupported,
      PollServiceError.permissionDenied => strings.pollPermissionDenied,
      PollServiceError.reauthenticationRequired => strings.pollSignInAgain,
      PollServiceError.rateLimited => strings.pollRateLimited,
      PollServiceError.ambiguous => strings.pollAmbiguous,
      _ => strings.pollFailed,
    };
