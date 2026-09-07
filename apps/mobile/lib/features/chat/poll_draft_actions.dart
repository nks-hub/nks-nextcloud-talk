import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../core/talk_features.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../conversations/conversation_header_actions.dart';
import 'poll_dialog.dart';
import 'poll_service.dart';

/// Header rendering is local; opening the dialog refreshes server authority.
bool pollDraftEntryAvailable(StoredAccount account, CachedConversation room) {
  final features = talkFeaturesOf(account);
  if (room.accountId != account.id ||
      !features.contains('talk-polls') ||
      !features.contains('talk-polls-drafts')) {
    return false;
  }
  try {
    final data = jsonDecode(room.rawJson);
    if (data is! Map<String, Object?> ||
        data['token'] != room.token ||
        data['participantType'] is! int) {
      return false;
    }
    return switch (participantRoleFor(data['participantType'] as int)) {
      ParticipantRole.owner ||
      ParticipantRole.moderator ||
      ParticipantRole.guestModerator => true,
      _ => false,
    };
  } on FormatException {
    return false;
  }
}

List<ConversationHeaderAction> pollDraftActions(
  BuildContext context,
  WidgetRef ref, {
  required PollRoomKey roomKey,
  required bool available,
  required bool Function() isCurrent,
}) {
  if (!available) return const [];
  return [
    ConversationHeaderAction(
      id: const Key('open-poll-drafts'),
      icon: Icons.poll_outlined,
      label: AppLocalizations.of(context).pollDraftsTitle,
      onPressed: () {
        if (!context.mounted || !ref.context.mounted || !isCurrent()) return;
        final sender = ref.read(pollServiceProvider);
        unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => PollDraftsDialog(
              sender: sender,
              roomKey: roomKey,
              isCurrent: () =>
                  context.mounted && ref.context.mounted && isCurrent(),
            ),
          ),
        );
      },
    ),
  ];
}
