import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import 'call_lifecycle_service.dart';
import 'call_state.dart';
import 'call_transport_service.dart';

/// Banner shown above a chat while the server reports a running call.
///
/// The banner recovers and reads the room's durable call REST state before it
/// exposes any call action. The join button remains inert until WebRTC media
/// exists; registering a server-side participant without media would create a
/// false presence in the call.
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
              strings.callBannerJoinUnsupported(strings.callTransportInternal),
              true,
            ),
            CallTransport.externalHpb => (
              strings.callBannerJoinUnsupported(
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

    return Container(
      key: const Key('call-banner'),
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.videocam_rounded, color: scheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
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
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
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
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  key: const Key('call-banner-transport'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
          if (joinable) ...[
            const SizedBox(width: 12),
            FilledButton(
              key: const Key('call-banner-join'),
              // Enabled once media exists; a button that does nothing would
              // lie about the app's state.
              onPressed: null,
              child: Text(strings.callBannerJoin),
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
