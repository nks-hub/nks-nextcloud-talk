/// Starting a call in a conversation where none is running.
///
/// The banner below the header offers to JOIN a call somebody else started;
/// until this existed there was no way to start one at all, which the owner
/// reported on 5 September 2026. Talk's own clients put the control in the
/// conversation header, and so does this.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import 'call_join_controller.dart';
import 'call_state.dart';

/// A phone and, where the room allows video, a camera. Both start the call
/// and join it; the camera one turns the camera on as soon as the media is
/// up, which is what "start with video" means on the wire.
final class CallStartButtons extends ConsumerWidget {
  const CallStartButtons({
    super.key,
    required this.accountId,
    required this.conversation,
  });

  final String accountId;
  final CachedConversation conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ConversationCallStartPolicy.fromConversation(conversation);
    if (!policy.canStart) {
      return const SizedBox.shrink();
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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('start-call-audio'),
          tooltip: strings.callStartAudio,
          icon: const Icon(Icons.call_rounded),
          onPressed: busy ? null : () => unawaited(start(withCamera: false)),
        ),
        if (policy.withVideo)
          IconButton(
            key: const Key('start-call-video'),
            tooltip: strings.callStartVideo,
            icon: const Icon(Icons.videocam_rounded),
            onPressed: busy ? null : () => unawaited(start(withCamera: true)),
          ),
      ],
    );
  }
}
