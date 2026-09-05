import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import 'call_controls.dart';
import 'call_join_controller.dart';
import 'call_lifecycle_service.dart';
import 'call_media_engine.dart';
import 'call_media_session.dart';
import 'call_participants_sheet.dart';
import 'call_screen.dart';
import 'call_state.dart';
import 'call_transport_service.dart';

/// Banner shown above a chat while the server reports a running call.
///
/// The banner recovers and reads the room's durable call REST state before it
/// exposes any call action. Joining registers a server-side participant and
/// negotiates audio over the room's signalling session; the button is only
/// offered once the transport is known, because a call whose signalling cannot
/// be resolved has nothing to negotiate over.
final class OngoingCallBanner extends ConsumerStatefulWidget {
  const OngoingCallBanner({
    super.key,
    required this.account,
    required this.conversation,
    this.now = DateTime.now,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// Injected so tests can drive the live duration without waiting.
  final DateTime Function() now;

  @override
  ConsumerState<OngoingCallBanner> createState() => _OngoingCallBannerState();
}

class _OngoingCallBannerState extends ConsumerState<OngoingCallBanner> {
  Timer? _ticker;

  /// The ticker exists only while a call with a known start time is shown, so
  /// a chat without a call schedules nothing at all.
  void _syncTicker({required bool running}) {
    if (running && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else if (!running && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = (
      accountId: widget.account.id,
      roomToken: widget.conversation.token,
    );
    final call = ConversationCallState.fromConversation(widget.conversation);
    final persistedLifecycle = ref.watch(callLifecyclePersistedProvider(key));
    final lifecycle = call != null || persistedLifecycle.valueOrNull == true
        ? ref.watch(callLifecycleStatusProvider(key))
        : null;
    final elapsed = call?.elapsed(now: widget.now());
    _syncTicker(running: elapsed != null);
    if (call == null) {
      return const SizedBox.shrink();
    }

    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final transport = ref.watch(callTransportProvider(key));
    final resolved = transport.valueOrNull;
    final boundLifecycle = lifecycle?.valueOrNull;
    final lifecycleReady = boundLifecycle?.matches(key) ?? false;
    final lifecycleFailed =
        (lifecycle?.hasError ?? false) ||
        (boundLifecycle != null && !lifecycleReady);
    final (String status, bool joinable) = !lifecycleReady
        ? (
            lifecycleFailed
                ? _callLifecycleErrorText(lifecycle?.error, strings)
                : strings.callBannerTransportChecking,
            false,
          )
        : switch (resolved) {
            CallTransport.internal => (
              strings.callBannerTransportReady(strings.callTransportInternal),
              true,
            ),
            CallTransport.externalHpb => (
              strings.callBannerTransportReady(
                strings.callTransportExternalHpb,
              ),
              true,
            ),
            CallTransport.reauthenticationRequired => (
              strings.callBannerTransportReauth,
              false,
            ),
            CallTransport.roomUnavailable => (
              strings.callBannerTransportRoomUnavailable,
              false,
            ),
            CallTransport.unavailable => (
              strings.callBannerTransportUnavailable,
              false,
            ),
            null when transport.hasError => (
              strings.callBannerTransportUnavailable,
              false,
            ),
            null => (strings.callBannerTransportChecking, false),
          };

    final join = ref.watch(callJoinControllerProvider(key));
    final joined =
        join.phase == CallJoinPhase.joined ||
        join.phase == CallJoinPhase.leaving;
    final statusText = joinable
        ? (_callJoinStatusText(join, strings) ?? status)
        : status;
    // A reaction from another participant rides on the status line for a
    // moment; the session clears it again.
    final reaction = join.media.reaction;
    final shownStatus = reaction == null
        ? statusText
        : '$statusText  ${reaction.emoji}';

    return Container(
      key: const Key('call-banner'),
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.videocam_rounded, color: scheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                // In a joined call the texts open the participant list — the
                // audio call's grid.
                child: InkWell(
                  key: const Key('call-banner-participants'),
                  onTap: joined
                      ? () => unawaited(showCallParticipantsSheet(context, key))
                      : null,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              strings.callBannerTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(color: scheme.onPrimaryContainer),
                            ),
                          ),
                          if (elapsed != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              formatCallDuration(elapsed),
                              key: const Key('call-banner-duration'),
                              semanticsLabel: strings.callBannerRunningFor(
                                formatCallDuration(elapsed),
                              ),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: scheme.onPrimaryContainer,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        shownStatus,
                        key: const Key('call-banner-transport'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (joinable) ...[
                const SizedBox(width: 12),
                FilledButton(
                  key: const Key('call-banner-join'),
                  onPressed: join.isBusy
                      ? null
                      : () {
                          final controller = ref.read(
                            callJoinControllerProvider(key).notifier,
                          );
                          unawaited(
                            joined ? controller.leave() : controller.join(),
                          );
                        },
                  child: Text(
                    joined ? strings.callBannerLeave : strings.callBannerJoin,
                  ),
                ),
              ] else if (lifecycleFailed) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('call-banner-lifecycle-retry'),
                  tooltip: strings.retry,
                  color: scheme.onPrimaryContainer,
                  onPressed: () {
                    ref.invalidate(callTransportProvider(key));
                    ref.invalidate(callLifecycleStatusProvider(key));
                  },
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ],
          ),
          // The controls of a joined call get a line of their own: four icons
          // beside the Leave button left the status text one letter per line on
          // a phone (measured on 5 September 2026).
          if (joinable && joined && join.media.phase != CallMediaPhase.failed)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  key: const Key('call-banner-open'),
                  tooltip: strings.callBannerOpenCallView,
                  color: scheme.onPrimaryContainer,
                  onPressed: () => unawaited(showCallScreen(context, key)),
                  icon: const Icon(Icons.grid_view_rounded),
                ),
                CallControls(
                  roomKey: key,
                  join: join,
                  color: scheme.onPrimaryContainer,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String _callLifecycleErrorText(Object? error, AppLocalizations strings) {
  if (error is! CallLifecycleException) {
    return strings.callBannerTransportUnavailable;
  }
  return switch (error.code) {
    CallLifecycleError.accountMissing ||
    CallLifecycleError.credentialMissing ||
    CallLifecycleError.reauthenticationRequired =>
      strings.callBannerTransportReauth,
    CallLifecycleError.roomMissing ||
    CallLifecycleError.forbidden => strings.callBannerTransportRoomUnavailable,
    _ => strings.callBannerTransportUnavailable,
  };
}

/// `h:mm:ss` once a call passes an hour, `mm:ss` before that.
String formatCallDuration(Duration elapsed) {
  final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = elapsed.inHours;
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

/// The join line replaces the transport line only while joining actually has
/// something to say; otherwise the transport keeps the line.
String? _callJoinStatusText(CallJoinState join, AppLocalizations strings) {
  if (join.signalingUnavailable) {
    return strings.callBannerSignalingUnavailable;
  }
  if (join.lifecycleError != null) {
    return strings.callBannerJoinFailed;
  }
  final mediaError = join.mediaError;
  if (mediaError != null) {
    return switch (mediaError) {
      CallMediaError.microphonePermissionDenied =>
        strings.callBannerMicrophoneDenied,
      CallMediaError.microphoneUnavailable =>
        strings.callBannerMicrophoneUnavailable,
      CallMediaError.topologyUnsupported => strings.callBannerMcuUnsupported,
      CallMediaError.signalingLost => strings.callBannerAudioSignalingLost,
      CallMediaError.engineFailure => strings.callBannerAudioFailed,
      // A camera problem never ends a call; these are here only because the
      // switch is exhaustive.
      CallMediaError.cameraPermissionDenied ||
      CallMediaError.cameraUnavailable => strings.callBannerAudioFailed,
    };
  }
  return switch (join.phase) {
    CallJoinPhase.idle => null,
    CallJoinPhase.joining || CallJoinPhase.leaving => strings.callBannerJoining,
    CallJoinPhase.joined || CallJoinPhase.failed => switch (join.media.phase) {
      CallMediaPhase.connected => strings.callBannerAudioConnected,
      CallMediaPhase.negotiating => strings.callBannerAudioNegotiating,
      CallMediaPhase.preparing => strings.callBannerAudioWaiting,
      CallMediaPhase.idle || CallMediaPhase.failed => null,
    },
  };
}
