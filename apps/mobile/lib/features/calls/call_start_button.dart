/// Starting a call in a conversation where none is running.
///
/// The banner below the header offers to JOIN a call somebody else started;
/// until this existed there was no way to start one at all, which the owner
/// reported on 5 September 2026. Talk's own clients put the control in the
/// conversation header, and so does this.
///
/// These are handed to the header as descriptions rather than as widgets, so a
/// header too narrow for every icon can fold them into its menu instead of
/// squeezing the conversation name out. They are given FIRST, which puts them
/// last in line to be folded.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../conversations/conversation_header_actions.dart';
import 'call_join_controller.dart';
import 'call_state.dart';

/// A phone and, where the room allows video, a camera. Both start the call
/// and join it; the camera one turns the camera on as soon as the media is
/// up, which is what "start with video" means on the wire.
List<ConversationHeaderAction> callStartActions(
  BuildContext context,
  WidgetRef ref, {
  required String accountId,
  required CachedConversation conversation,
}) {
  final policy = ConversationCallStartPolicy.fromConversation(conversation);
  if (!policy.canStart) {
    return const [];
  }
  final strings = AppLocalizations.of(context);
  final key = (accountId: accountId, roomToken: conversation.token);
  final join = ref.watch(callJoinControllerProvider(key));
  final busy = join.isBusy || join.phase == CallJoinPhase.joined;
  Future<void> start({required bool withCamera}) async {
    final controller = ref.read(callJoinControllerProvider(key).notifier);
    await controller.join();
    if (withCamera) {
      await controller.setCameraEnabled(true);
    }
  }

  return [
    ConversationHeaderAction(
      id: const Key('start-call-audio'),
      icon: Icons.call_rounded,
      label: strings.callStartAudio,
      onPressed: busy ? null : () => unawaited(start(withCamera: false)),
    ),
    if (policy.withVideo)
      ConversationHeaderAction(
        id: const Key('start-call-video'),
        icon: Icons.videocam_rounded,
        label: strings.callStartVideo,
        onPressed: busy ? null : () => unawaited(start(withCamera: true)),
      ),
  ];
}
