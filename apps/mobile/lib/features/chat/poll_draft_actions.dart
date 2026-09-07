import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../conversations/conversation_header_actions.dart';
import 'poll_dialog.dart';
import 'poll_service.dart';

final pollDraftAccessProvider = FutureProvider.autoDispose
    .family<PollManagementAccess, PollRoomKey>(
      (ref, key) => ref.watch(pollServiceProvider).managementAccess(key: key),
    );

List<ConversationHeaderAction> pollDraftActions(
  BuildContext context,
  WidgetRef ref, {
  required PollRoomKey roomKey,
  required bool Function() isCurrent,
}) {
  final access = ref.watch(pollDraftAccessProvider(roomKey)).valueOrNull;
  if (access?.canListDrafts != true) return const [];
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
