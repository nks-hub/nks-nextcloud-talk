import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../chat/chat_room_signaling.dart';
import 'call_lifecycle_service.dart';
import 'call_media_engine.dart';
import 'call_media_session.dart';
import 'call_transport_service.dart';

enum CallJoinPhase { idle, joining, joined, leaving, failed }

/// What a participant may publish into a call, as the room's permissions say.
/// Everything is allowed until the room says otherwise, so a room that could
/// not be read behaves as it always did.
final class CallPublishingRights {
  const CallPublishingRights({
    this.audio = true,
    this.video = true,
    this.screen = true,
  });

  factory CallPublishingRights.fromPolicy(CallRoomPolicy policy) =>
      CallPublishingRights(
        audio: policy.canPublishAudio,
        video: policy.canPublishVideo,
        screen: policy.canPublishScreen,
      );

  final bool audio;
  final bool video;
  final bool screen;
}

final class CallJoinState {
  const CallJoinState({
    this.phase = CallJoinPhase.idle,
    this.media = CallMediaState.idle,
    this.mediaError,
    this.lifecycleError,
    this.signalingUnavailable = false,
    this.publishing = const CallPublishingRights(),
  });

  final CallJoinPhase phase;
  final CallMediaState media;
  final CallMediaError? mediaError;
  final CallLifecycleError? lifecycleError;

  /// The room has no signalling session, so there is nothing to negotiate
  /// over. Distinct from a media failure: nothing was attempted.
  final bool signalingUnavailable;

  /// What this participant is allowed to publish. A moderator can take any of
  /// it away, and a control that promises what the server will refuse is
  /// worse than no control — pressing the camera really opens the camera, and
  /// pressing the screen share really asks the system to record the screen.
  final CallPublishingRights publishing;

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
// `base`, not `final`: a test freezes a joined state by subclassing it.
base class CallJoinController
    extends AutoDisposeFamilyNotifier<CallJoinState, CallRoomKey> {
  CallMediaSession? _session;
  StreamSubscription<CallMediaState>? _mediaStates;
  CallLifecycleService? _lifecycle;
  bool _joinedServer = false;
  bool _disposed = false;
  StateController<Set<ChatRoomSignalingKey>>? _heldRooms;

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

  /// Re-asserts this side's call flags after the signalling came back as a
  /// new session.
  ///
  /// Talk broadcasts the call's participant list when its own state changes,
  /// and a pure signalling reconnect changes nothing there — so without this
  /// nobody is told either side is still in the call and the two never open
  /// connections to each other again. A flag update is the lightest change
  /// there is: no system message, no call restart.
  void _refreshCallFlags() {
    final lifecycle = _lifecycle;
    if (_disposed || !_joinedServer || lifecycle == null) {
      return;
    }
    unawaited(
      lifecycle
          .updateFlags(
            accountId: arg.accountId,
            roomToken: arg.roomToken,
          )
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  var _publishing = const CallPublishingRights();

  /// What the room says this participant may publish.
  ///
  /// Read from the cached conversation, which is the same copy the room
  /// details read their moderation state from — no extra request, and a room
  /// that cannot be parsed leaves every control as it was rather than hiding
  /// something the user is allowed to use.
  Future<CallPublishingRights> _readPublishingRights() async {
    try {
      final cached = await ref
          .read(accountRepositoryProvider)
          .getConversation(accountId: arg.accountId, token: arg.roomToken);
      if (cached == null) {
        return const CallPublishingRights();
      }
      final room = ConversationRoom.fromJson(
        jsonDecode(cached.rawJson) as Object?,
      );
      return CallPublishingRights.fromPolicy(
        CallRoomPolicy.fromConversation(room),
      );
    } on Object {
      return const CallPublishingRights();
    }
  }

  Future<void> join() async {
    if (state.isBusy || state.phase == CallJoinPhase.joined) {
      return;
    }
    state = const CallJoinState(phase: CallJoinPhase.joining);

    // Held before the lease is asked for: the room session must survive the
    // window losing focus for as long as this call lives.
    _hold(true);
    final lease = await ref.read(chatRoomSignalingProvider(arg).future);
    final signaling = lease.session;
    if (_disposed) {
      return;
    }
    if (signaling == null) {
      _hold(false);
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
      await lifecycle.join(accountId: arg.accountId, roomToken: arg.roomToken);
      _joinedServer = true;
    } on CallLifecycleException catch (error) {
      _hold(false);
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

    _publishing = await _readPublishingRights();

    final session = CallMediaSession(
      initial: signaling.current,
      updates: signaling.updates,
      sendMessage: signaling.sendPeerMessage,
      sendControl: signaling.sendControl,
      engine: ref.read(callMediaEngineProvider),
      interruptions: ref.read(callAudioInterruptionsProvider),
      onSignalingRebuilt: _refreshCallFlags,
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
        publishing: _publishing,
      );
      if (media.phase == CallMediaPhase.failed) {
        unawaited(_abandonFailedCall(session));
      }
    });
    await session.start();
    if (_disposed) {
      return;
    }
    ref.invalidate(callLifecycleStatusProvider(arg));
  }

  /// Mutes or unmutes this participant's microphone in the joined call.
  Future<void> setMicrophoneMuted(bool muted) async {
    final session = _session;
    if (session == null || state.phase != CallJoinPhase.joined) {
      return;
    }
    await session.setMicrophoneMuted(muted);
  }

  /// Routes the joined call's audio to the loudspeaker or the earpiece.
  Future<void> setSpeakerphone(bool on) async {
    final session = _session;
    if (session == null || state.phase != CallJoinPhase.joined) {
      return;
    }
    await session.setSpeakerphone(on);
  }

  /// Sends the joined call's audio to one of the platform's outputs.
  Future<void> selectAudioRoute(CallAudioRoute route) async {
    final session = _session;
    if (session == null || state.phase != CallJoinPhase.joined) {
      return;
    }
    await session.selectAudioRoute(route);
  }

  /// Raises or lowers this participant's hand in the joined call.
  Future<void> setHandRaised(bool raised) async {
    final session = _session;
    if (session == null || state.phase != CallJoinPhase.joined) {
      return;
    }
    await session.setHandRaised(raised);
  }

  /// Sends a reaction into the joined call.
  Future<void> sendReaction(String emoji) async {
    final session = _session;
    if (session == null || state.phase != CallJoinPhase.joined) {
      return;
    }
    await session.sendReaction(emoji);
  }

  /// Starts or stops sharing this device's screen into the joined call. The
  /// foreground service Android needs for a capture runs for exactly as long
  /// as the share does.
  Future<void> setScreenSharing(bool sharing) async {
    final session = _session;
    if (session == null || state.phase != CallJoinPhase.joined) {
      return;
    }
    final service = ref.read(callScreenShareServiceProvider);
    if (sharing) {
      // The order Android 14 insists on: consent, then the foreground
      // service, then the capture. Starting the service first is refused,
      // because the permission it needs only exists once the user has said
      // yes (measured on the Android 14 emulator: a SecurityException that
      // took the whole app down).
      if (!await ref.read(callMediaEngineProvider).requestScreenConsent()) {
        return;
      }
      if (!await service.start()) {
        return;
      }
    }
    await session.setScreenSharing(sharing);
    if (!sharing || !state.media.screenSharing) {
      await service.stop();
    }
  }

  /// Turns this participant's camera on or off in the joined call.
  Future<void> setCameraEnabled(bool enabled) async {
    final session = _session;
    if (session == null || state.phase != CallJoinPhase.joined) {
      return;
    }
    await session.setCameraEnabled(enabled);
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

  /// Gives the server-side seat back when the media could not be established.
  ///
  /// The REST join succeeds before the media does, so a media failure used to
  /// leave the client a participant of a call it cannot hear: measured on
  /// 5 September 2026 as `inCall=7` on the server while the banner read "Call
  /// in progress / Running for 58:58 / The call signalling ended, so the audio
  /// stopped." and offered to JOIN. Nothing outside the app could clear it
  /// either — the seat belongs to the app's own Talk session, so a `DELETE`
  /// from anywhere else answers 404. The state is deliberately left at
  /// [CallJoinPhase.failed] so the reason stays on screen; only the seat goes.
  Future<void> _abandonFailedCall(CallMediaSession session) async {
    if (_disposed || !identical(_session, session)) {
      return;
    }
    await _teardown(leaveServer: true);
    if (_disposed) {
      return;
    }
    ref.invalidate(callLifecycleStatusProvider(arg));
  }

  /// Marks the room as held by this call in [callHeldRoomsProvider]. The
  /// controller is read once and kept: the release runs from a dispose, where
  /// the container may already be going away.
  void _hold(bool held) {
    try {
      final StateController<Set<ChatRoomSignalingKey>> rooms =
          _heldRooms ?? ref.read(callHeldRoomsProvider.notifier);
      _heldRooms = rooms;
      final current = rooms.state;
      if (current.contains(arg) == held) {
        return;
      }
      rooms.state = held
          ? {...current, arg}
          : {
              for (final room in current)
                if (room != arg) room,
            };
    } on Object {
      // A disposed container has no rooms left to hold.
    }
  }

  Future<void> _teardown({required bool leaveServer}) async {
    _hold(false);
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
