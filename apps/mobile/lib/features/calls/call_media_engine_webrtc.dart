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
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio audio,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
    required void Function(CallRemoteVideo? video) onRemoteVideo,
  }) async {
    final stream = (audio as _WebRtcLocalAudio).stream;
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
      for (final track in stream.getAudioTracks()) {
        await connection.addTrack(track, stream);
      }
      // Receive-only video: the offer carries a video m-line, so a peer that
      // sends video (the web client does by default) is seen here without
      // this side having a camera open. Sending video is a later step.
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
    return _WebRtcPeerConnection(connection);
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
  _WebRtcPeerConnection(this._connection);

  final rtc.RTCPeerConnection _connection;
  bool _closed = false;

  @override
  Future<CallSessionDescription> createOffer() =>
      _describe(_connection.createOffer());

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
