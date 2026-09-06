import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'call_media_engine.dart';

/// True on iOS, where the whole device's screen is only reachable through a
/// Broadcast Upload Extension. macOS shares a window through the desktop
/// capturer instead and has no such extension.
bool get _isApplePhone => defaultTargetPlatform == TargetPlatform.iOS;

/// The only file that talks to `flutter_webrtc`.
///
/// It maps the plugin onto [CallMediaEngine] and nothing else: no negotiation
/// decision is made here, so the call logic above stays testable without a
/// platform channel.
final class WebRtcCallMediaEngine implements CallMediaEngine {
  const WebRtcCallMediaEngine({this.relayOnly = false});

  /// Forces every connection to use a TURN relay and nothing else.
  ///
  /// The relay servers are NOT configured here and never in the build: Talk
  /// hands them out per room in its signalling settings, from what the
  /// Nextcloud administrator entered there. This only says which of the
  /// candidates ICE gathered may be used.
  ///
  /// It exists because on a rig where both ends see each other ICE picks the
  /// host pair — as it should — so a call proves TURN was offered and that
  /// relay candidates were gathered, but never that a relayed pair carries
  /// media. With the host pair gone from the choice, a call that connects at
  /// all connected through TURN. It also gets a call through a network that
  /// blocks the direct path without saying so.
  ///
  /// Off by default: a call that relays when it did not have to pays latency
  /// and somebody else's bandwidth for nothing.
  final bool relayOnly;

  /// The plugin's connection configuration, apart so the relay switch can be
  /// read back without a platform channel.
  static Map<String, dynamic> connectionConfiguration(
    List<CallIceServer> iceServers, {
    bool relayOnly = false,
  }) => <String, dynamic>{
    'iceServers': iceServers
        .map(
          (server) => <String, dynamic>{
            'urls': server.urls,
            if (server.username != null) 'username': server.username,
            if (server.credential != null) 'credential': server.credential,
          },
        )
        .toList(growable: false),
    'sdpSemantics': 'unified-plan',
    // Only where a relay actually exists. `relay` tells ICE to discard every
    // candidate that is not a relayed one, so on a server whose administrator
    // configured no TURN server it leaves ICE with nothing at all and the call
    // never connects. The switch is the user's answer to "prefer the relay",
    // not an instruction to break a call it cannot help.
    if (relayOnly && iceServers.any(offersRelay)) 'iceTransportPolicy': 'relay',
  };

  /// Whether [server] is a TURN server, which is the only kind a relay-only
  /// policy can use. Talk lists STUN and TURN in the same settings answer.
  static bool offersRelay(CallIceServer server) => server.urls.any((url) {
    final scheme = url.trim().toLowerCase();
    return scheme.startsWith('turn:') || scheme.startsWith('turns:');
  });

  @override
  Future<CallLocalAudio> openMicrophone() async {
    final rtc.MediaStream stream;
    try {
      stream = await rtc.navigator.mediaDevices.getUserMedia(
        const <String, dynamic>{'audio': true, 'video': false},
      );
    } on Object catch (error) {
      throw CallMediaException(_microphoneError(error));
    }
    if (stream.getAudioTracks().isEmpty) {
      await stream.dispose();
      throw const CallMediaException(CallMediaError.microphoneUnavailable);
    }
    return _WebRtcLocalAudio(stream);
  }

  @override
  Future<CallLocalVideo> openCamera() async {
    final rtc.MediaStream stream;
    try {
      stream = await rtc.navigator.mediaDevices.getUserMedia(
        const <String, dynamic>{
          'audio': false,
          'video': <String, dynamic>{'facingMode': 'user'},
        },
      );
    } on Object catch (error) {
      throw CallMediaException(_cameraError(error));
    }
    if (stream.getVideoTracks().isEmpty) {
      await stream.dispose();
      throw const CallMediaException(CallMediaError.cameraUnavailable);
    }
    return _WebRtcLocalVideo.open(stream);
  }

  @override
  Future<bool> requestScreenConsent() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return true;
    }
    try {
      // Stores the consent inside the plugin; the `getDisplayMedia` below
      // then reuses it instead of asking a second time.
      return await rtc.Helper.requestCapturePermission();
    } on Object catch (error) {
      debugPrint('[call] screen consent failed: $error');
      return false;
    }
  }

  @override
  Future<CallLocalVideo> openScreen() async {
    final rtc.MediaStream stream;
    try {
      // The platform asks for consent itself (Android's capture dialog); the
      // foreground service that Android 10+ requires is started by the caller
      // before this runs.
      //
      // On iOS the whole device's screen only reaches us through a Broadcast
      // Upload Extension, and the plugin picks that path from the `broadcast`
      // device id alone: it then reads the frames off the unix socket in the
      // App Group container and presents the system picker for the extension
      // named by `RTCScreenSharingExtension`. Without the prefix it would use
      // `RPScreenRecorder`, which records this application's own window — in
      // a call that is the call view, which is of no use to anybody.
      stream = await rtc.navigator.mediaDevices.getDisplayMedia(
        <String, dynamic>{
          'audio': false,
          'video': _isApplePhone
              ? const <String, dynamic>{'deviceId': 'broadcast'}
              : true,
        },
      );
    } on Object catch (error) {
      // The plugin's own words, because the mapped code alone cannot tell a
      // refused consent from a capturer that failed to start.
      debugPrint('[call] openScreen failed: $error');
      throw CallMediaException(_screenError(error));
    }
    if (stream.getVideoTracks().isEmpty) {
      await stream.dispose();
      throw const CallMediaException(CallMediaError.screenShareUnavailable);
    }
    return _WebRtcLocalVideo.open(stream);
  }

  @override
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio? audio,
    CallLocalVideo? video,
    bool sendOnly = false,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
    required void Function(CallRemoteVideo? video) onRemoteVideo,
  }) async {
    final stream = (audio as _WebRtcLocalAudio?)?.stream;
    final oneWay = sendOnly || video != null;
    debugPrint(
      '[call] ice servers: '
      '${iceServers.map((server) => server.urls.map((u) => u.split(':').first).join('/')).join(' ')}'
      '${relayOnly ? ' policy=relay' : ''}',
    );
    final rtc.RTCPeerConnection connection;
    try {
      connection = await rtc.createPeerConnection(
        connectionConfiguration(iceServers, relayOnly: relayOnly),
      );
    } on Object {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
    _WebRtcLocalVideo? local;
    try {
      if (stream != null) {
        for (final track in stream.getAudioTracks()) {
          await connection.addTrack(track, stream);
        }
      } else if (video != null) {
        // A screen publish still offers an audio line, empty and send-only.
        // talk-web's own screen offer reads `m=audio,video dir=sendonly,
        // sendonly` (captured from its socket on 5 September 2026), and a
        // media server given video alone never answered ours at all.
        await connection.addTransceiver(
          kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: rtc.RTCRtpTransceiverInit(
            direction: rtc.TransceiverDirection.SendOnly,
          ),
        );
      }
      // One video line per connection. It starts receive-only, so a peer
      // that sends video (the web client does by default) is seen without a
      // camera open here; turning the camera on puts a track on this same
      // line and flips it to send-and-receive, followed by a new offer.
      // A share opens with the picture already on the line, sending only:
      // nothing ever comes back on a screen connection.
      // Hoisted: the flag outlives the block that builds the transceiver.
      local = video as _WebRtcLocalVideo?;
      if (local == null) {
        // A publisher's video line starts empty and send-only: the camera
        // fills it later, and nothing ever comes back on it.
        await connection.addTransceiver(
          kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: rtc.RTCRtpTransceiverInit(
            direction: sendOnly
                ? rtc.TransceiverDirection.SendOnly
                : rtc.TransceiverDirection.RecvOnly,
          ),
        );
      } else {
        await connection.addTransceiver(
          track: local.track,
          init: rtc.RTCRtpTransceiverInit(
            direction: rtc.TransceiverDirection.SendOnly,
            streams: <rtc.MediaStream>[local.stream],
          ),
        );
      }
    } on Object {
      await connection.close();
      await connection.dispose();
      throw const CallMediaException(CallMediaError.engineFailure);
    }
    connection.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      // An end-of-candidates marker arrives as a null candidate; it carries no
      // transport address, and Talk has no wire message for it.
      if (value == null || value.isEmpty) {
        return;
      }
      // The candidate's type is the fourth token of the a=candidate line;
      // `relay` is the only proof a TURN server is actually in use.
      final parts = value.split(' ');
      if (parts.length > 7) {
        debugPrint('[call] candidate ${parts[7]}');
      }
      onIceCandidate(
        CallIceCandidate(
          candidate: value,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    connection.onConnectionState = (state) {
      final mapped = _connectionState(state);
      onConnectionState(mapped);
      // A share has no picture of its own to look at, so the only proof it
      // sends is the sender's own counters. Three samples, then quiet.
      if (local != null && mapped == CallMediaConnectionState.connected) {
        unawaited(_probeOutbound(connection));
      }
    };
    connection.onTrack = (event) {
      if (event.track.kind != 'video' || event.streams.isEmpty) {
        return;
      }
      unawaited(
        _WebRtcRemoteVideo.open(event.streams.first).then(onRemoteVideo),
      );
    };
    connection.onRemoveTrack = (stream, track) {
      if (track.kind == 'video') {
        onRemoteVideo(null);
      }
    };
    return _WebRtcPeerConnection(connection, stream, sendOnly: oneWay);
  }
}

CallMediaError _cameraError(Object error) {
  final detail = error is PlatformException
      ? '${error.code} ${error.message ?? ''}'
      : error.toString();
  return detail.contains('NotAllowedError')
      ? CallMediaError.cameraPermissionDenied
      : CallMediaError.cameraUnavailable;
}

/// The camera stream with a mirrored preview of it.
final class _WebRtcLocalVideo implements CallLocalVideo {
  _WebRtcLocalVideo._(this.stream, this._renderer);

  static Future<_WebRtcLocalVideo> open(rtc.MediaStream stream) async {
    final renderer = rtc.RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    return _WebRtcLocalVideo._(stream, renderer);
  }

  final rtc.MediaStream stream;
  final rtc.RTCVideoRenderer _renderer;
  bool _disposed = false;

  rtc.MediaStreamTrack get track => stream.getVideoTracks().first;

  @override
  Widget buildPreview(BuildContext context) => rtc.RTCVideoView(
    _renderer,
    mirror: true,
    objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
  );

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _renderer.srcObject = null;
    await _renderer.dispose();
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }
}

/// Both the Android and the Apple side of the plugin report a refused
/// permission as the `NotAllowedError` DOMException name from the getUserMedia
/// algorithm. The type it arrives as is not dependable: the plugin catches the
/// platform exception and rethrows a bare String
/// (`Unable to getUserMedia: DOMException, NotAllowedError`), which is what a
/// live refusal on Android actually produced, so the text is what is matched.
CallMediaError _microphoneError(Object error) {
  final detail = error is PlatformException
      ? '${error.code} ${error.message ?? ''}'
      : error.toString();
  return detail.contains('NotAllowedError')
      ? CallMediaError.microphonePermissionDenied
      : CallMediaError.microphoneUnavailable;
}

CallMediaConnectionState _connectionState(rtc.RTCPeerConnectionState state) =>
    switch (state) {
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
        CallMediaConnectionState.connected,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
        CallMediaConnectionState.failed,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
        CallMediaConnectionState.closed,
      // `disconnected` is transient by design: ICE may recover from it on its
      // own, so it is not a failure the call has to react to.
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew ||
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting ||
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
        CallMediaConnectionState.connecting,
    };

/// A renderer bound to one remote stream. `initialize` has to finish before
/// the stream is attached, so construction is asynchronous.
final class _WebRtcRemoteVideo implements CallRemoteVideo {
  _WebRtcRemoteVideo._(this._renderer, this.videoTrackId);

  static Future<_WebRtcRemoteVideo> open(rtc.MediaStream stream) async {
    final renderer = rtc.RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    final tracks = stream.getVideoTracks();
    return _WebRtcRemoteVideo._(
      renderer,
      tracks.isEmpty ? null : tracks.first.id,
    );
  }

  @override
  final String? videoTrackId;

  final rtc.RTCVideoRenderer _renderer;
  bool _disposed = false;

  @override
  Widget build(BuildContext context) => rtc.RTCVideoView(
    _renderer,
    objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
  );

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _renderer.srcObject = null;
    await _renderer.dispose();
  }
}

final class _WebRtcLocalAudio implements CallLocalAudio {
  _WebRtcLocalAudio(this.stream) {
    // The plugin has one hook for every kind of device; a call is the only
    // thing in this app that cares, so it owns the hook for its lifetime.
    rtc.navigator.mediaDevices.ondevicechange = (_) {
      if (!_routeChanges.isClosed) {
        _routeChanges.add(null);
      }
    };
  }

  final rtc.MediaStream stream;
  final _routeChanges = StreamController<void>.broadcast();
  bool _disposed = false;

  @override
  Stream<void> get routeChanges => _routeChanges.stream;

  @override
  Future<List<CallAudioRoute>> routes() async {
    if (_disposed) {
      return const [];
    }
    try {
      final outputs = await rtc.Helper.audiooutputs;
      return [
        for (final device in outputs)
          CallAudioRoute(
            id: device.deviceId,
            label: device.label,
            kind: _routeKind(device.deviceId, device.groupId),
          ),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } on Object {
      // The desktop plugins throw a bare String for "not implemented".
      return const [];
    }
  }

  @override
  Future<void> selectRoute(CallAudioRoute route) async {
    if (_disposed) {
      return;
    }
    try {
      await rtc.Helper.selectAudioOutput(route.id);
    } on MissingPluginException {
      // No such route on this platform.
    } on PlatformException {
      // The desktop plugins answer the method with "not implemented".
    }
  }

  /// Android names outputs by kind (`speaker`, `earpiece`, `bluetooth`,
  /// `wired-headset`); iOS hands back the port's UID with its `portType` as
  /// the group, and `Speaker` for the built-in loudspeaker.
  static CallAudioRouteKind _routeKind(String id, String? group) {
    final key = '${id.toLowerCase()}|${(group ?? '').toLowerCase()}';
    if (key.startsWith('speaker')) {
      return CallAudioRouteKind.speaker;
    }
    if (key.startsWith('earpiece') || key.contains('|receiver')) {
      return CallAudioRouteKind.earpiece;
    }
    if (key.contains('bluetooth')) {
      return CallAudioRouteKind.bluetooth;
    }
    if (key.contains('wired') ||
        key.contains('headphones') ||
        key.contains('headset')) {
      return CallAudioRouteKind.wiredHeadset;
    }
    return CallAudioRouteKind.other;
  }

  @override
  Future<void> setMuted(bool muted) async {
    if (_disposed) {
      return;
    }
    // `enabled` rather than `stop`: a stopped track cannot be restarted and the
    // peer connection would have to renegotiate. Disabled, it stays in the
    // sender and transmits silence.
    for (final track in stream.getAudioTracks()) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setSpeakerphone(bool on) async {
    if (_disposed) {
      return;
    }
    try {
      await rtc.Helper.setSpeakerphoneOn(on);
    } on MissingPluginException {
      // No such route on this platform.
    } on PlatformException {
      // The desktop plugins answer the method with "not implemented".
    }
  }

  @override
  Future<void> dispose() async {
    rtc.navigator.mediaDevices.ondevicechange = null;
    await _routeChanges.close();
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }
}

final class _WebRtcPeerConnection implements CallPeerConnection {
  _WebRtcPeerConnection(
    this._connection,
    this._localStream, {
    required this._sendOnly,
  });

  /// A share offers nothing back. Without this the plugin's default offer
  /// constraints add a receive-only audio and video line to every offer, and
  /// a screen offer then reaches the web client as three m-lines it did not
  /// ask for (measured on 5 September 2026: the web answered them
  /// `inactive` and showed no screen at all).
  final bool _sendOnly;

  final rtc.RTCPeerConnection _connection;

  /// The microphone's stream: the camera track is sent under the SAME stream
  /// id, because the web client listens to the legacy `addstream` event and
  /// keeps one `MediaStream` per peer — a video track with its own (or no)
  /// stream id never reaches the element it renders (measured on 5 September
  /// 2026: the answer said `video:recvonly`, the frames were encoded, the
  /// web's stream still had no video track).
  final rtc.MediaStream? _localStream;
  bool _closed = false;

  /// The transceiver handed back by `addTransceiver` must not be kept: the
  /// plugin disposes that wrapper once the connection negotiates ("RtpTransceiver
  /// has been disposed", measured on 5 September 2026 with flutter_webrtc
  /// 1.6.1), so the video line is looked up afresh each time.
  @override
  Future<void> setLocalVideo(CallLocalVideo? video) => _guard(() async {
    try {
      await _setLocalVideo(video);
    } on Object catch (error) {
      // The guard turns this into a plain engine failure; the cause is worth
      // one log line, because the camera then quietly stays off.
      debugPrint('[call] setLocalVideo failed: $error');
      rethrow;
    }
  });

  Future<void> _setLocalVideo(CallLocalVideo? video) async {
    final transceivers = await _connection.getTransceivers();
    // A typed literal, not `where().toList()`: the plugin hands back a list of
    // its own subtype, and a filtered copy keeps that runtime type, so the
    // `orElse` closure below (typed to the interface) would be refused at
    // run time — measured as a camera that never left "engine failure".
    final videoLines = <rtc.RTCRtpTransceiver>[
      for (final transceiver in transceivers)
        if (transceiver.receiver.track?.kind == 'video') transceiver,
    ];
    if (videoLines.isEmpty) {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
    // Prefer the line the peer already negotiated (it has a mid): when the
    // peer offered first, our own receive-only transceiver was not matched to
    // their video line and a second one exists; sending on the negotiated
    // line keeps one video line per connection.
    final line = videoLines.firstWhere(
      (transceiver) => transceiver.mid.isNotEmpty,
      orElse: () => videoLines.first,
    );
    await line.sender.replaceTrack(
      video == null ? null : (video as _WebRtcLocalVideo).track,
    );
    final localStream = _localStream;
    if (video != null && localStream != null) {
      try {
        await line.sender.setStreams([localStream]);
      } on Object {
        // Best effort: without it the track travels with its own stream id,
        // which some receivers do not attach to the participant's stream.
      }
    }
    await line.setDirection(
      video == null
          ? (_sendOnly
                ? rtc.TransceiverDirection.Inactive
                : rtc.TransceiverDirection.RecvOnly)
          : (_sendOnly
                ? rtc.TransceiverDirection.SendOnly
                : rtc.TransceiverDirection.SendRecv),
    );
  }

  @override
  Future<CallSessionDescription> createOffer({bool iceRestart = false}) {
    final mandatory = <String, dynamic>{
      if (iceRestart) 'IceRestart': true,
      if (_sendOnly) ...<String, dynamic>{
        'OfferToReceiveAudio': false,
        'OfferToReceiveVideo': false,
      },
    };
    return _describe(
      mandatory.isEmpty
          ? _connection.createOffer()
          : _connection.createOffer(<String, dynamic>{
              'mandatory': mandatory,
              'optional': <dynamic>[],
            }),
    );
  }

  @override
  Future<CallSessionDescription> createAnswer() =>
      _describe(_connection.createAnswer());

  @override
  Future<void> setLocalDescription(CallSessionDescription description) =>
      _guard(
        () => _connection.setLocalDescription(
          rtc.RTCSessionDescription(description.sdp, description.type),
        ),
      );

  @override
  Future<void> setRemoteDescription(CallSessionDescription description) =>
      _guard(
        () => _connection.setRemoteDescription(
          rtc.RTCSessionDescription(description.sdp, description.type),
        ),
      );

  @override
  Future<void> addIceCandidate(CallIceCandidate candidate) => _guard(
    () => _connection.addCandidate(
      rtc.RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ),
    ),
  );

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _connection.onIceCandidate = null;
    _connection.onConnectionState = null;
    _connection.onTrack = null;
    _connection.onRemoveTrack = null;
    try {
      await _connection.close();
    } on Object {
      // A connection the engine already tore down is still closed.
    }
    await _connection.dispose();
  }

  Future<CallSessionDescription> _describe(
    Future<rtc.RTCSessionDescription> pending,
  ) async {
    final rtc.RTCSessionDescription description;
    try {
      description = await pending;
    } on Object {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
    final sdp = description.sdp;
    final type = description.type;
    if (sdp == null || sdp.isEmpty || type == null || type.isEmpty) {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
    return (type: type, sdp: sdp);
  }

  Future<void> _guard(Future<void> Function() operation) async {
    try {
      await operation();
    } on CallMediaException {
      rethrow;
    } on Object {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
  }
}

/// Logs the outbound video counters of a send-only connection a few times
/// after it connects: frames captured, encoded and sent, and bytes on the
/// wire. This is how a share that the far side does not paint is told apart
/// from one that never left this device.
Future<void> _probeOutbound(rtc.RTCPeerConnection connection) async {
  for (var sample = 0; sample < 3; sample++) {
    await Future<void>.delayed(const Duration(seconds: 4));
    try {
      final reports = await connection.getStats();
      for (final report in reports) {
        if (report.type != 'outbound-rtp') {
          continue;
        }
        final v = report.values;
        debugPrint(
          '[call] outbound ${v['kind'] ?? v['mediaType']} '
          'frames=${v['framesEncoded']}/${v['framesSent']} '
          'bytes=${v['bytesSent']} res=${v['frameWidth']}x${v['frameHeight']} '
          'fps=${v['framesPerSecond']} limit=${v['qualityLimitationReason']}',
        );
      }
    } on Object catch (error) {
      debugPrint('[call] outbound stats failed: $error');
      return;
    }
  }
}

/// The plugin reports a refused capture as a plain string, the same way it
/// does a refused microphone, so the text is what separates "the user said
/// no" from "this device cannot".
CallMediaError _screenError(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('notallowed') ||
      text.contains('permission') ||
      text.contains('denied') ||
      text.contains("didn't give") ||
      text.contains('did not give')) {
    return CallMediaError.screenSharePermissionDenied;
  }
  return CallMediaError.screenShareUnavailable;
}
