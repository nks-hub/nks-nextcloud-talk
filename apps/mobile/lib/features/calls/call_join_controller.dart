import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../app_providers.dart';
import '../../core/talk_features.dart';
import '../chat/chat_room_signaling.dart';
import '../rooms/room_settings_service.dart';
import 'call_lifecycle_service.dart';
import 'call_foreground_service.dart';
import 'call_signaling_session.dart';
import 'call_media_engine.dart';
import 'call_media_session.dart';
import 'call_proximity.dart';
import 'call_screen_share_service.dart';
import 'call_telecom.dart';
import 'call_transport_service.dart';

enum CallJoinPhase { idle, joining, joined, leaving, failed }

/// The Talk capability that gates the moderator recording control, the same
/// way `breakout-rooms-v1` gates the breakout-rooms control.
const String callRecordingCapability = 'recording-v1';

/// The Talk capability that gates downloading the running call's attendance.
const String callAttendanceCapability = 'download-call-participants';

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

/// What this participant may do to the call as a whole, as opposed to what
/// they may publish into it. Read once from the cached conversation and the
/// account's own capabilities, same source and same "hide rather than offer
/// something the server will refuse" policy as [CallPublishingRights].
final class CallModeratorState {
  const CallModeratorState({
    this.publishing = const CallPublishingRights(),
    this.canManageRecording = false,
    this.recordingActive = false,
    this.canDownloadAttendance = false,
  });

  final CallPublishingRights publishing;

  /// A moderator, on a server that advertises [callRecordingCapability]. A
  /// participant for whom this is `false` must not see the recording control
  /// at all — the same rule [CallPublishingRights.screen] already applies to
  /// the screen-share button.
  final bool canManageRecording;

  /// Whether the room already reports a recording starting or in progress
  /// (`ConversationRoom.callRecording != 0`) as of the last read. Kept
  /// optimistically in sync with this participant's own start/stop calls
  /// rather than polled, since nothing else in this screen re-reads the room
  /// while a call is joined.
  final bool recordingActive;

  /// A moderator, on a server that advertises [callAttendanceCapability]. Same
  /// rule as [canManageRecording]: a participant without it must not be shown
  /// the control, because the server would refuse the download anyway.
  final bool canDownloadAttendance;
}

final class CallJoinState {
  const CallJoinState({
    this.phase = CallJoinPhase.idle,
    this.media = CallMediaState.idle,
    this.mediaError,
    this.lifecycleError,
    this.signalingUnavailable = false,
    this.publishing = const CallPublishingRights(),
    this.canManageRecording = false,
    this.recordingActive = false,
    this.canDownloadAttendance = false,
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

  /// See [CallModeratorState.canManageRecording].
  final bool canManageRecording;

  /// See [CallModeratorState.recordingActive].
  final bool recordingActive;

  /// See [CallModeratorState.canDownloadAttendance].
  final bool canDownloadAttendance;

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

  /// A hang-up that arrived while the join was still in flight.
  bool _leaveRequested = false;
  ({CallForegroundService service, String owner})? _foregroundCall;

  /// The screen-capture service while a share is running.
  ///
  /// Held rather than read again where it has to be stopped: both places that
  /// stop it — the teardown and the media state that reports the share gone —
  /// can run while the container is already going away, and reading a
  /// provider there throws.
  CallScreenShareService? _screenShare;

  /// The system's own record of this call, once Telecom accepted one. Held
  /// rather than read again on teardown, where reading a provider throws.
  ({CallTelecom telecom, String callId})? _telecomCall;
  int _cameraEpoch = 0;
  bool _enablingCamera = false;
  CallMediaError? _cameraError;
  Future<void>? _teardownPending;
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
          .updateFlags(accountId: arg.accountId, roomToken: arg.roomToken)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  var _moderator = const CallModeratorState();

  /// Held while the call wants the screen to follow the proximity sensor.
  /// Read once and kept, because the release runs from a teardown where
  /// reading a provider is no longer allowed.
  CallProximityHold? _proximity;

  /// What the room says this participant may publish and manage.
  ///
  /// Read from the cached conversation, which is the same copy the room
  /// details read their moderation state from — no extra request, and a room
  /// that cannot be parsed leaves every control as it was rather than hiding
  /// something the user is allowed to use.
  Future<CallModeratorState> _readModeratorState() async {
    try {
      final accounts = ref.read(accountRepositoryProvider);
      final cached = await accounts.getConversation(
        accountId: arg.accountId,
        token: arg.roomToken,
      );
      if (cached == null) {
        return const CallModeratorState();
      }
      final room = ConversationRoom.fromJson(
        jsonDecode(cached.rawJson) as Object?,
      );
      final policy = CallRoomPolicy.fromConversation(room);
      final account = await accounts.getAccount(arg.accountId);
      final features = account == null
          ? const <String>{}
          : talkFeaturesOf(account);
      return CallModeratorState(
        publishing: CallPublishingRights.fromPolicy(policy),
        canManageRecording:
            policy.isModerator && features.contains(callRecordingCapability),
        recordingActive: room.callRecording != 0,
        canDownloadAttendance:
            policy.isModerator && features.contains(callAttendanceCapability),
      );
    } on Object {
      return const CallModeratorState();
    }
  }

  Future<void> join() async {
    if (state.isBusy || state.phase == CallJoinPhase.joined) {
      return;
    }
    _leaveRequested = false;
    state = const CallJoinState(phase: CallJoinPhase.joining);
    final teardown = _teardownPending;
    if (teardown != null) await teardown;
    if (_disposed) return;

    // Held before the lease is asked for: the room session must survive the
    // window losing focus for as long as this call lives.
    _hold(true);
    final lease = await ref.read(chatRoomSignalingProvider(arg).future);
    var signaling = lease.session;
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
    final CallLifecycleState joined;
    try {
      joined = await lifecycle.join(
        accountId: arg.accountId,
        roomToken: arg.roomToken,
      );
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

    if (lease.nextcloudSessionId != joined.authority.nextcloudSessionId.value) {
      // A definitive REST 404 can renew the shared room. Its lifecycle holder
      // keeps it alive while the chat replaces the old signaling authority.
      ChatRoomSignalingLease? rebound;
      try {
        ref.invalidate(chatRoomSignalingProvider(arg));
        rebound = await ref.read(chatRoomSignalingProvider(arg).future);
      } on Object {
        // Failed provider admission must release the confirmed REST call seat.
      }
      if (_disposed) {
        unawaited(_leaveServer());
        return;
      }
      signaling = rebound?.session;
      if (signaling == null ||
          rebound?.nextcloudSessionId !=
              joined.authority.nextcloudSessionId.value) {
        await _leaveServer();
        _hold(false);
        if (!_disposed) {
          state = const CallJoinState(
            phase: CallJoinPhase.failed,
            signalingUnavailable: true,
          );
        }
        return;
      }
    }

    _moderator = await _readModeratorState();
    if (_disposed) {
      unawaited(_leaveServer());
      return;
    }
    final foreground = (
      service: ref.read(callForegroundServiceProvider),
      owner: const Uuid().v4(),
    );
    _foregroundCall = foreground;
    try {
      await foreground.service.start(foreground.owner);
    } on CallMediaException catch (error) {
      await _stopForegroundCall();
      await _leaveServer();
      _hold(false);
      if (!_disposed) {
        state = CallJoinState(
          phase: CallJoinPhase.failed,
          mediaError: error.code,
        );
      }
      return;
    }
    if (_disposed || _foregroundCall?.owner != foreground.owner) {
      await foreground.service.stop(foreground.owner);
      unawaited(_leaveServer());
      return;
    }

    // Permission UI can outlive a signaling lane without changing the Talk SID.
    try {
      signaling = await _reacquireSignaling(
        joined.authority.nextcloudSessionId.value,
      );
    } on Object {
      signaling = null;
    }
    if (_disposed || _foregroundCall?.owner != foreground.owner) {
      await foreground.service.stop(foreground.owner);
      unawaited(_leaveServer());
      return;
    }
    if (signaling == null) {
      await _teardown(leaveServer: true);
      if (!_disposed) {
        state = const CallJoinState(
          phase: CallJoinPhase.failed,
          signalingUnavailable: true,
        );
      }
      return;
    }

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
        mediaError: media.error ?? _cameraError,
        publishing: _moderator.publishing,
        canManageRecording: _moderator.canManageRecording,
        recordingActive: _moderator.recordingActive,
        canDownloadAttendance: _moderator.canDownloadAttendance,
      );
      unawaited(_applyProximity(media));
      // The share can end without anybody pressing the button: closing every
      // peer connection stops the capture, which is what a network drop and a
      // renegotiation both do. The system service outlives it either way, and
      // its notification then tells the person their screen is still being
      // shared when it is not.
      if (!media.screenSharing) {
        unawaited(_stopScreenShareService());
      }
      if (media.phase == CallMediaPhase.failed) {
        unawaited(_abandonFailedCall(session));
      }
    });
    await session.start();
    if (_disposed) {
      return;
    }
    ref.invalidate(callLifecycleStatusProvider(arg));
    if (_leaveRequested) {
      // Asked to hang up while this was still joining. The state is no longer
      // busy, so the ordinary path can run — and it must run before the
      // system is told about a call nobody wants.
      _leaveRequested = false;
      state = CallJoinState(phase: CallJoinPhase.joined, media: state.media);
      await leave();
      return;
    }
    await _startTelecomCall();
  }

  /// Puts the joined call into the system's own call lifecycle.
  ///
  /// After the media session rather than before it, so what the system is told
  /// about is a call that exists. Every refusal is ordinary — an Android older
  /// than the self-managed API, a ROM without Telecom, a platform failure —
  /// and leaves the call exactly as it was: this must never fail a join.
  Future<void> _startTelecomCall() async {
    // Captured before the await, and compared by identity after it. A null
    // check is not enough: a call can end and another one start while the
    // platform is answering, and the handle for the first would then be
    // stored against the second and never ended.
    final session = _session;
    if (session == null) {
      return;
    }
    try {
      // A container already going away has no platform left to tell.
      final telecom = ref.read(callTelecomProvider);
      final call = await telecom.startOutgoing(
        accountId: arg.accountId,
        roomToken: arg.roomToken,
      );
      if (call == null) {
        return;
      }
      if (_disposed || !identical(_session, session)) {
        // The call ended while the system was being told about it.
        await telecom.endCall(call.callId);
        return;
      }
      _telecomCall = (telecom: telecom, callId: call.callId);
    } on Object {
      // The system's opinion of the call is not the call.
    }
  }

  /// Takes the system's record of the call down. Runs from the teardown, so a
  /// platform that fails here must not stop the call from ending.
  Future<void> _endTelecomCall() async {
    final call = _telecomCall;
    _telecomCall = null;
    try {
      await call?.telecom.endCall(call.callId);
    } on Object {
      // Detaching the activity's channel also releases what it still holds.
    }
  }

  Future<CallSignalingSession?> _reacquireSignaling(
    String nextcloudSessionId,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final lease = await ref.read(chatRoomSignalingProvider(arg).future);
      if (_disposed) return null;
      final current = ref.read(chatRoomSignalingProvider(arg)).valueOrNull;
      if (!identical(current, lease)) continue;
      final session = lease.session;
      if (lease.nextcloudSessionId == nextcloudSessionId &&
          session?.isActive == true) {
        return session;
      }
      if (attempt == 0) ref.invalidate(chatRoomSignalingProvider(arg));
    }
    return null;
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

  /// Starts or stops recording the call. `CallControls` is responsible for
  /// only offering this to a participant for whom
  /// `state.canManageRecording` is true — the server also refuses it on its
  /// own (`#[RequireLoggedInModeratorParticipant]`), but the control must not
  /// exist at all for anyone else, the same rule the screen-share button
  /// already follows for `publish-screen`.
  ///
  /// ponytail: a failure is swallowed rather than surfaced, matching every
  /// other fire-and-forget control on this banner. Add a visible error once
  /// there is a recording backend on the rig to observe one against.
  Future<void> setRecording(
    bool active, {
    CallRecordingStartMode mode = CallRecordingStartMode.video,
  }) async {
    if (state.phase != CallJoinPhase.joined || state.isBusy) {
      return;
    }
    final settings = ref.read(roomSettingsServiceProvider);
    try {
      if (active) {
        await settings.startCallRecording(
          accountId: arg.accountId,
          roomToken: arg.roomToken,
          mode: mode,
        );
      } else {
        await settings.stopCallRecording(
          accountId: arg.accountId,
          roomToken: arg.roomToken,
        );
      }
    } on RoomSettingsException {
      return;
    }
    if (_disposed || state.phase != CallJoinPhase.joined) {
      return;
    }
    _moderator = CallModeratorState(
      publishing: _moderator.publishing,
      canManageRecording: _moderator.canManageRecording,
      recordingActive: active,
      canDownloadAttendance: _moderator.canDownloadAttendance,
    );
    state = CallJoinState(
      phase: state.phase,
      media: state.media,
      mediaError: state.mediaError,
      lifecycleError: state.lifecycleError,
      signalingUnavailable: state.signalingUnavailable,
      publishing: _moderator.publishing,
      canManageRecording: _moderator.canManageRecording,
      recordingActive: active,
      canDownloadAttendance: _moderator.canDownloadAttendance,
    );
  }

  /// Starts or stops sharing this device's screen into the joined call. The
  /// foreground service Android needs for a capture runs for exactly as long
  /// as the share does.
  Future<CallMediaError?> setScreenSharing(
    bool sharing, {
    Future<CallScreenSource?> Function()? chooseSource,
  }) async {
    if (_disposed) return null;
    final session = _session;
    if (session == null || state.phase != CallJoinPhase.joined) {
      return null;
    }
    bool current() =>
        !_disposed &&
        identical(_session, session) &&
        state.phase == CallJoinPhase.joined;

    final service = ref.read(callScreenShareServiceProvider);
    var serviceStarted = false;
    try {
      CallScreenSource? source;
      if (sharing) {
        if (!state.publishing.screen) {
          return CallMediaError.screenShareUnavailable;
        }
        // Android 14 requires consent before the foreground service starts.
        if (!await ref.read(callMediaEngineProvider).requestScreenConsent()) {
          return current() ? CallMediaError.screenSharePermissionDenied : null;
        }
        if (!current()) return null;
        if (usesDesktopScreenSourcePicker) {
          if (chooseSource == null) {
            return CallMediaError.screenShareUnavailable;
          }
          source = await chooseSource();
          if (source == null || !current()) return null;
          if (!state.publishing.screen) {
            return CallMediaError.screenShareUnavailable;
          }
        }
        if (!await service.start()) {
          return current() ? CallMediaError.screenShareUnavailable : null;
        }
        serviceStarted = true;
        _screenShare = service;
        if (!current()) return null;
      }
      await session.setScreenSharing(sharing, source: source);
      return null;
    } on CallMediaException catch (error) {
      return current() ? error.code : null;
    } finally {
      if (!sharing || (serviceStarted && !session.state.screenSharing)) {
        _screenShare = null;
        await service.stop();
      }
    }
  }

  /// Turns this participant's camera on or off in the joined call.
  Future<void> setCameraEnabled(bool enabled) async {
    final session = _session;
    final foreground = _foregroundCall;
    if (session == null ||
        foreground == null ||
        state.phase != CallJoinPhase.joined ||
        (enabled &&
            (_enablingCamera ||
                session.state.cameraOn ||
                !state.publishing.video))) {
      return;
    }
    final epoch = ++_cameraEpoch;
    _enablingCamera = enabled;
    _setCameraError(null);
    bool current() =>
        !_disposed &&
        epoch == _cameraEpoch &&
        identical(_session, session) &&
        _foregroundCall?.owner == foreground.owner &&
        state.phase == CallJoinPhase.joined;
    try {
      if (enabled) {
        await foreground.service.setCameraEnabled(foreground.owner, true);
        if (!current()) return;
      }
      await session.setCameraEnabled(enabled);
      if (!current()) return;
      if (!enabled || !session.state.cameraOn) {
        await foreground.service.setCameraEnabled(foreground.owner, false);
        if (enabled && current()) {
          _setCameraError(CallMediaError.cameraUnavailable);
        }
      }
    } on CallMediaException catch (error) {
      if (!current()) return;
      try {
        await foreground.service.setCameraEnabled(foreground.owner, false);
      } on CallMediaException {
        // A camera-type failure must not tear down the microphone owner.
      }
      if (current()) _setCameraError(error.code);
    } finally {
      if (epoch == _cameraEpoch) _enablingCamera = false;
    }
  }

  void _setCameraError(CallMediaError? error) {
    _cameraError = error;
    state = CallJoinState(
      phase: state.phase,
      media: state.media,
      mediaError: state.media.error ?? error,
      lifecycleError: state.lifecycleError,
      signalingUnavailable: state.signalingUnavailable,
      publishing: state.publishing,
      canManageRecording: state.canManageRecording,
      recordingActive: state.recordingActive,
      canDownloadAttendance: state.canDownloadAttendance,
    );
  }

  Future<void> leave() async {
    if (state.phase == CallJoinPhase.idle) {
      return;
    }
    if (state.isBusy) {
      // Remembered instead of refused. A join is several round trips with a
      // 20 s timeout each, and the system call screen can hang up in the
      // middle of it: the ring is dropped, this was a no-op, and the join
      // then finished into a live call with an open microphone that no
      // system UI was left to end. The join checks this before it settles.
      _leaveRequested = true;
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
    final pending = _teardownPending;
    if (pending != null) return pending;
    final cleanup = _performTeardown(leaveServer: leaveServer);
    _teardownPending = cleanup;
    try {
      await cleanup;
    } finally {
      if (identical(_teardownPending, cleanup)) _teardownPending = null;
    }
  }

  /// Follows the call's own state: the screen is handed to the sensor while
  /// this side is on the earpiece with no picture in the call, and given back
  /// on every other route, on a failure and on teardown.
  ///
  /// From the moment the call is live, not from the moment somebody answers.
  /// A phone is held to the ear while it is still ringing out, and a call
  /// waiting alone in the room is exactly the one nobody is looking at.
  Future<void> _applyProximity(CallMediaState media) async {
    final hold = _proximity ??= CallProximityHold(
      ref.read(callProximityScreenProvider),
    );
    await hold.apply(
      wanted:
          media.phase != CallMediaPhase.idle &&
          media.phase != CallMediaPhase.failed &&
          callWantsProximityBlanking(
            joined: true,
            onEarpiece:
                !media.speakerphone &&
                (media.audioRoute?.kind ?? CallAudioRouteKind.earpiece) ==
                    CallAudioRouteKind.earpiece,
            cameraOn: media.cameraOn,
            screenSharing: media.screenSharing,
            receivingVideo: media.participants.any(
              (peer) => peer.video != null,
            ),
          ),
    );
    if (_disposed) {
      await hold.release();
    }
  }

  Future<void> _releaseProximity() async {
    final hold = _proximity;
    _proximity = null;
    await hold?.release();
  }

  Future<void> _performTeardown({required bool leaveServer}) async {
    _hold(false);
    // Taken first, so nothing that runs later in this teardown can be told
    // about a call that is already going. A join still finishing in parallel
    // reads this null and stops: the system used to be handed a call handle
    // right after the teardown had ended the previous one, and that handle
    // then belonged to nobody.
    final session = _session;
    _session = null;
    final subscription = _mediaStates;
    _mediaStates = null;
    await _stopScreenShareService();
    await _releaseProximity();
    await _endTelecomCall();
    _cameraEpoch++;
    _enablingCamera = false;
    _cameraError = null;
    final foreground = _foregroundCall;
    _foregroundCall = null;
    final disposal = session?.dispose();
    try {
      await subscription?.cancel();
      await disposal;
    } finally {
      try {
        await foreground?.service.stop(foreground.owner);
      } finally {
        if (leaveServer) await _leaveServer();
      }
    }
  }

  /// Stops the screen-capture service if this call started one.
  Future<void> _stopScreenShareService() async {
    final service = _screenShare;
    if (service == null) {
      return;
    }
    _screenShare = null;
    await service.stop();
  }

  Future<void> _stopForegroundCall() async {
    final foreground = _foregroundCall;
    _foregroundCall = null;
    await foreground?.service.stop(foreground.owner);
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
