import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'call_join_controller.dart';
import 'call_transport_service.dart';

/// The same six the web client offers, in the same order.
const callReactions = <String>['❤️', '🎉', '👏', '👍', '👎', '😂'];

/// The controls of a joined call — mute, speaker (phones), camera, hand,
/// reaction — shared by the banner and the call screen so both behave the
/// same. Keys are `<keyPrefix>-mute` and so on.
final class CallControls extends ConsumerWidget {
  const CallControls({
    super.key,
    required this.roomKey,
    required this.join,
    required this.color,
    this.keyPrefix = 'call-banner',
  });

  final CallRoomKey roomKey;
  final CallJoinState join;
  final Color color;
  final String keyPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    CallJoinController controller() =>
        ref.read(callJoinControllerProvider(roomKey).notifier);
    final busy = join.isBusy;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: Key('$keyPrefix-mute'),
          tooltip: join.media.muted
              ? strings.callBannerUnmute
              : strings.callBannerMute,
          color: color,
          isSelected: join.media.muted,
          onPressed: busy
              ? null
              : () => unawaited(
                  controller().setMicrophoneMuted(!join.media.muted),
                ),
          icon: const Icon(Icons.mic_rounded),
          selectedIcon: const Icon(Icons.mic_off_rounded),
        ),
        // Only a phone has two outputs to choose from.
        if (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)
          IconButton(
            key: Key('$keyPrefix-speaker'),
            tooltip: join.media.speakerphone
                ? strings.callBannerSpeakerOff
                : strings.callBannerSpeakerOn,
            color: color,
            isSelected: join.media.speakerphone,
            onPressed: busy
                ? null
                : () => unawaited(
                    controller().setSpeakerphone(!join.media.speakerphone),
                  ),
            icon: const Icon(Icons.volume_down_rounded),
            selectedIcon: const Icon(Icons.volume_up_rounded),
          ),
        IconButton(
          key: Key('$keyPrefix-camera'),
          tooltip: join.media.cameraOn
              ? strings.callBannerCameraOff
              : strings.callBannerCameraOn,
          color: color,
          isSelected: join.media.cameraOn,
          onPressed: busy
              ? null
              : () => unawaited(
                  controller().setCameraEnabled(!join.media.cameraOn),
                ),
          icon: const Icon(Icons.videocam_off_outlined),
          selectedIcon: const Icon(Icons.videocam_rounded),
        ),
        // Sharing this device's screen exists where the platform can capture
        // one; on a phone that is Android.
        if (defaultTargetPlatform == TargetPlatform.android)
          IconButton(
            key: Key('$keyPrefix-share-screen'),
            tooltip: join.media.screenSharing
                ? strings.callBannerStopSharing
                : strings.callBannerShareScreen,
            color: color,
            isSelected: join.media.screenSharing,
            onPressed: busy
                ? null
                : () => unawaited(
                    controller().setScreenSharing(!join.media.screenSharing),
                  ),
            icon: const Icon(Icons.screen_share_outlined),
            selectedIcon: const Icon(Icons.stop_screen_share_rounded),
          ),
        IconButton(
          key: Key('$keyPrefix-raise-hand'),
          tooltip: join.media.handRaised
              ? strings.callBannerLowerHand
              : strings.callBannerRaiseHand,
          color: color,
          isSelected: join.media.handRaised,
          onPressed: busy
              ? null
              : () => unawaited(
                  controller().setHandRaised(!join.media.handRaised),
                ),
          // The count is the other participants' hands; our own is the
          // selected state of the icon.
          icon: Badge.count(
            key: Key('$keyPrefix-raised-hands'),
            count: join.media.raisedHands,
            isLabelVisible: join.media.raisedHands > 0,
            child: const Icon(Icons.front_hand_outlined),
          ),
          selectedIcon: Badge.count(
            count: join.media.raisedHands,
            isLabelVisible: join.media.raisedHands > 0,
            child: const Icon(Icons.front_hand_rounded),
          ),
        ),
        PopupMenuButton<String>(
          key: Key('$keyPrefix-react'),
          tooltip: strings.callBannerReact,
          enabled: !busy,
          onSelected: (emoji) => unawaited(controller().sendReaction(emoji)),
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            for (final emoji in callReactions)
              PopupMenuItem<String>(
                key: Key('$keyPrefix-react-$emoji'),
                value: emoji,
                child: Text(emoji, style: const TextStyle(fontSize: 22)),
              ),
          ],
          icon: Icon(Icons.add_reaction_outlined, color: color),
        ),
      ],
    );
  }
}
