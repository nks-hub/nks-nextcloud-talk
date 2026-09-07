part of 'call_media_engine_webrtc.dart';

extension _WebRtcScreenCapture on WebRtcCallMediaEngine {
  Future<List<CallScreenSource>> _screenSources() async {
    if (!usesDesktopScreenSourcePicker) {
      throw const CallMediaException(CallMediaError.screenShareUnavailable);
    }
    try {
      final sources = await rtc.desktopCapturer.getSources(
        types: const [rtc.SourceType.Screen, rtc.SourceType.Window],
        thumbnailSize: rtc.ThumbnailSize(160, 90),
      );
      return [
        for (final source in sources)
          if (source.id.isNotEmpty && source.name.trim().isNotEmpty)
            CallScreenSource(
              id: source.id,
              name: source.name,
              isWindow: source.type == rtc.SourceType.Window,
              thumbnail: source.thumbnail,
            ),
      ];
    } on Object {
      throw const CallMediaException(CallMediaError.screenShareUnavailable);
    }
  }

  Future<bool> _requestScreenConsent() async {
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

  Future<CallLocalVideo> _openScreen({CallScreenSource? source}) async {
    if (usesDesktopScreenSourcePicker &&
        (source == null || source.id.isEmpty)) {
      throw const CallMediaException(CallMediaError.screenShareUnavailable);
    }
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
          'video': usesDesktopScreenSourcePicker
              ? <String, dynamic>{
                  'deviceId': <String, dynamic>{'exact': source!.id},
                }
              : _isApplePhone
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
}
