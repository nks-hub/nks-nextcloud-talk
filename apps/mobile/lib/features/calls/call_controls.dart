import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'call_join_controller.dart';
import 'call_media_engine.dart';
import 'call_transport_service.dart';

/// The same six the web client offers, in the same order.
const callReactions = <String>['❤️', '🎉', '👏', '👍', '👎', '😂'];

/// The controls of a joined call — mute, speaker (phones), camera, hand,
/// reaction — shared by the banner and the call screen so both behave the
/// same. Keys are `<keyPrefix>-mute` and so on.
IconData _routeIcon(CallAudioRouteKind kind) => switch (kind) {
  CallAudioRouteKind.speaker => Icons.volume_up_rounded,
  CallAudioRouteKind.earpiece => Icons.phone_in_talk_rounded,
  CallAudioRouteKind.bluetooth => Icons.bluetooth_audio_rounded,
  CallAudioRouteKind.wiredHeadset => Icons.headset_rounded,
  CallAudioRouteKind.other => Icons.speaker_rounded,
};

/// The kind's own name where there is one; the platform's label for the rest,
/// which is where a Bluetooth headset's product name ends up.
String _routeLabel(AppLocalizations strings, CallAudioRoute route) =>
    switch (route.kind) {
      CallAudioRouteKind.speaker => strings.callAudioRouteSpeaker,
      CallAudioRouteKind.earpiece => strings.callAudioRouteEarpiece,
      CallAudioRouteKind.bluetooth =>
        route.label.isEmpty ? strings.callAudioRouteBluetooth : route.label,
      CallAudioRouteKind.wiredHeadset => strings.callAudioRouteWiredHeadset,
      CallAudioRouteKind.other => route.label.isEmpty ? route.id : route.label,
    };

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
        // A headset or headphones present: a menu names every output. Only
        // the built-in two: the toggle, which is faster than a menu.
        if (join.media.audioRoutes.length > 2)
          PopupMenuButton<CallAudioRoute>(
            key: Key('$keyPrefix-audio-route'),
            tooltip: strings.callBannerAudioRoute,
            enabled: !busy,
            onSelected: (route) =>
                unawaited(controller().selectAudioRoute(route)),
            itemBuilder: (context) => <PopupMenuEntry<CallAudioRoute>>[
              for (final route in join.media.audioRoutes)
                PopupMenuItem<CallAudioRoute>(
                  key: Key('$keyPrefix-audio-route-${route.id}'),
                  value: route,
                  child: ListTile(
                    dense: true,
                    leading: Icon(_routeIcon(route.kind)),
                    title: Text(_routeLabel(strings, route)),
                    trailing: route.id == join.media.audioRoute?.id
                        ? const Icon(Icons.check_rounded)
                        : null,
                  ),
                ),
            ],
            icon: Icon(
              _routeIcon(
                join.media.audioRoute?.kind ??
                    (join.media.speakerphone
                        ? CallAudioRouteKind.speaker
                        : CallAudioRouteKind.earpiece),
              ),
              color: color,
            ),
          )
        // Only a phone has two outputs to choose from.
        else if (defaultTargetPlatform == TargetPlatform.android ||
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
        // A moderator can take publishing away. The button must go with it:
        // pressing it really opens the camera on this device and renegotiates
        // the connection, for a picture the server will not carry.
        if (join.publishing.video)
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
        // one: Android through a MediaProjection, iOS through the Broadcast
        // Upload Extension the system's own picker starts. `publish-screen`
        // is a permission and never a call flag, so it has to be asked for
        // separately — without it the button would walk the user through the
        // system's recording consent for a share nobody receives.
        if ((defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS) &&
            join.publishing.screen)
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
