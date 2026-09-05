import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'call_media_engine.dart';

/// The only file that talks to `flutter_webrtc`.
///
/// It maps the plugin onto [CallMediaEngine] and nothing else: no negotiation
/// decision is made here, so the call logic above stays testable without a
/// platform channel.
final class WebRtcCallMediaEngine implements CallMediaEngine {
  const WebRtcCallMediaEngine();

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
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio? audio,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
    required void Function(CallRemoteVideo? video) onRemoteVideo,
  }) async {
    final stream = (audio as _WebRtcLocalAudio?)?.stream;
    final rtc.RTCPeerConnection connection;
    try {
      connection = await rtc.createPeerConnection(<String, dynamic>{
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
      });
    } on Object {
      throw const CallMediaException(CallMediaError.engineFailure);
    }
    try {
      if (stream != null) {
        for (final track in stream.getAudioTracks()) {
          await connection.addTrack(track, stream);
        }
      }
      // One video line per connection. It starts receive-only, so a peer
      // that sends video (the web client does by default) is seen without a
      // camera open here; turning the camera on puts a track on this same
      // line and flips it to send-and-receive, followed by a new offer.
      await connection.addTransceiver(
        kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: rtc.RTCRtpTransceiverInit(
          direction: rtc.TransceiverDirection.RecvOnly,
        ),
      );
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
      onIceCandidate(
        CallIceCandidate(
          candidate: value,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    connection.onConnectionState = (state) =>
        onConnectionState(_connectionState(state));
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
    return _WebRtcPeerConnection(connection, stream);
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
  _WebRtcRemoteVideo._(this._renderer);

  static Future<_WebRtcRemoteVideo> open(rtc.MediaStream stream) async {
    final renderer = rtc.RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    return _WebRtcRemoteVideo._(renderer);
  }

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
  _WebRtcLocalAudio(this.stream);

  final rtc.MediaStream stream;
  bool _disposed = false;

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
  _WebRtcPeerConnection(this._connection, this._localStream);

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
          ? rtc.TransceiverDirection.RecvOnly
          : rtc.TransceiverDirection.SendRecv,
    );
  }

  @override
  Future<CallSessionDescription> createOffer({bool iceRestart = false}) =>
      _describe(
        iceRestart
            ? _connection.createOffer(<String, dynamic>{
                'mandatory': <String, dynamic>{'IceRestart': true},
                'optional': <dynamic>[],
              })
            : _connection.createOffer(),
      );

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
