import ReplayKit

/// The broadcast upload extension. ReplayKit hosts it in its own process and
/// hands it the whole device's screen; it forwards the video frames to the
/// application over a unix socket in the shared App Group container, where
/// `flutter_webrtc`'s `FlutterBroadcastScreenCapturer` turns them back into a
/// WebRTC video source.
///
/// Audio is deliberately dropped: a Talk call already carries the microphone,
/// and sending the device's audio a second time would echo.
final class SampleHandler: RPBroadcastSampleHandler {
  /// The same file name `FlutterBroadcastScreenCapturer` binds
  /// (`kRTCScreensharingSocketFD`).
  private static let socketFileName = "rtc_SSFD"
  private static let appGroup = "group.com.nkshub.nextcloudtalk"

  private var connection: SocketConnection?
  private var uploader: SampleUploader?

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: SampleHandler.appGroup),
      let socket = SocketConnection(
        filePath: container.appendingPathComponent(SampleHandler.socketFileName).path)
    else {
      finish(reason: "The screen could not be shared with NKS Talk.")
      return
    }

    socket.didClose = { [weak self] _ in
      // The application stopped listening — it left the call or was closed.
      // Ending the broadcast here is what takes the red status bar away.
      self?.finish(reason: "The call that was receiving the screen has ended.")
    }

    guard socket.open() else {
      finish(reason: "Start sharing from a call in NKS Talk.")
      return
    }

    connection = socket
    uploader = SampleUploader(connection: socket)
  }

  override func broadcastFinished() {
    connection?.close()
    connection = nil
    uploader = nil
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    with sampleBufferType: RPSampleBufferType
  ) {
    guard sampleBufferType == .video, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
      return
    }
    uploader?.send(sample: sampleBuffer)
  }

  private func finish(reason: String) {
    let error = NSError(
      domain: "com.nkshub.nextcloudtalk.broadcast",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: reason]
    )
    finishBroadcastWithError(error)
  }
}
