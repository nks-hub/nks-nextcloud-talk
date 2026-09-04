import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../chat/chat_room_signaling.dart';
import 'call_lifecycle_service.dart';
import 'call_media_engine.dart';
import 'call_media_session.dart';
import 'call_transport_service.dart';

enum CallJoinPhase { idle, joining, joined, leaving, failed }

final class CallJoinState {
  const CallJoinState({
    this.phase = CallJoinPhase.idle,
    this.media = CallMediaState.idle,
    this.mediaError,
    this.lifecycleError,
    this.signalingUnavailable = false,
  });

  final CallJoinPhase phase;
  final CallMediaState media;
  final CallMediaError? mediaError;
  final CallLifecycleError? lifecycleError;

  /// The room has no signalling session, so there is nothing to negotiate
  /// over. Distinct from a media failure: nothing was attempted.
  final bool signalingUnavailable;

  bool get isBusy =>
      phase == CallJoinPhase.joining || phase == CallJoinPhase.leaving;

  @override
  String toString() =>
      'CallJoinState(${phase.name}, media: $media, '
      'mediaError: ${mediaError?.name}, '
      'lifecycleError: ${lifecycleError?.name})';
}

/// Joins one room's call with audio and leaves it again.
///
/// Joining is two steps that both have to hold: the Talk call REST lifecycle
/// registers this client as a participant of the call, and [CallMediaSession]
/// negotiates the audio over the room's existing signalling session. Leaving
/// undoes both, and so does disposal — a call must not outlive the screen that
/// has the only control for ending it.
final class CallJoinController
    extends AutoDisposeFamilyNotifier<CallJoinState, CallRoomKey> {
  CallMediaSession? _session;
  StreamSubscription<CallMediaState>? _mediaStates;
  CallLifecycleService? _lifecycle;
  bool _joinedServer = false;
  bool _disposed = false;

  @override
  CallJoinState build(CallRoomKey arg) {
    // Holds the room's signalling session open for as long as this controller
    // lives, so a joined call does not lose its lane to an unrelated dispose.
    // A replaced lease closes the old lane's stream, which the media session
    // reports as a lost signalling.
    ref.listen(chatRoomSignalingProvider(arg), (_, _) {});
    ref.onDispose(() {
      _disposed = true;
      unawaited(_teardown(leaveServer: true));
    });
    return const CallJoinState();
  }

  Future<void> join() async {
    if (state.isBusy || state.phase == CallJoinPhase.joined) {
      return;
    }
    state = const CallJoinState(phase: CallJoinPhase.joining);

    final lease = await ref.read(chatRoomSignalingProvider(arg).future);
    final signaling = lease.session;
    if (_disposed) {
      return;
    }
    if (signaling == null) {
      state = const CallJoinState(
        phase: CallJoinPhase.failed,
        signalingUnavailable: true,
      );
      return;
    }

    // Held rather than read again on dispose: the teardown runs while the
    // container is already tearing down, and reading a provider there throws.
    final lifecycle = ref.read(callLifecycleServiceProvider);
    _lifecycle = lifecycle;
    try {
      await lifecycle.join(
        accountId: arg.accountId,
        roomToken: arg.roomToken,
      );
      _joinedServer = true;
    } on CallLifecycleException catch (error) {
      if (!_disposed) {
        state = CallJoinState(
          phase: CallJoinPhase.failed,
          lifecycleError: error.code,
        );
      }
      return;
    }
    if (_disposed) {
      unawaited(_leaveServer());
      return;
    }

    final session = CallMediaSession(
      initial: signaling.current,
      updates: signaling.updates,
      sendMessage: signaling.sendPeerMessage,
      engine: ref.read(callMediaEngineProvider),
    );
    _session = session;
    _mediaStates = session.states.listen((media) {
      if (_disposed || !identical(_session, session)) {
        return;
      }
      state = CallJoinState(
        phase: media.phase == CallMediaPhase.failed
            ? CallJoinPhase.failed
            : CallJoinPhase.joined,
        media: media,
        mediaError: media.error,
      );
    });
    await session.start();
    if (_disposed) {
      return;
    }
    ref.invalidate(callLifecycleStatusProvider(arg));
  }

  Future<void> leave() async {
    if (state.phase == CallJoinPhase.idle || state.isBusy) {
      return;
    }
    state = CallJoinState(phase: CallJoinPhase.leaving, media: state.media);
    await _teardown(leaveServer: true);
    if (_disposed) {
      return;
    }
    state = const CallJoinState();
    ref.invalidate(callLifecycleStatusProvider(arg));
  }

  Future<void> _teardown({required bool leaveServer}) async {
    final subscription = _mediaStates;
    _mediaStates = null;
    await subscription?.cancel();
    final session = _session;
    _session = null;
    await session?.dispose();
    if (leaveServer) {
      await _leaveServer();
    }
  }

  Future<void> _leaveServer() async {
    if (!_joinedServer) {
      return;
    }
    _joinedServer = false;
    try {
      await _lifecycle!.leave(
        accountId: arg.accountId,
        roomToken: arg.roomToken,
      );
    } on CallLifecycleException {
      // The server-side seat is also released when the room session ends, and
      // a failed leave must not keep the local media running.
    }
  }
}
