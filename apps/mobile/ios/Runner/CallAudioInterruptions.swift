import AVFoundation
import Flutter

/// Reports when the system takes the audio away from a Talk call and when it
/// gives it back — a telephone call, Siri, an alarm — on the same channel and
/// with the same two words as the Android side, so the Dart side has one
/// listener for both platforms.
///
/// iOS has no audio-mode listener; its equivalent is `AVAudioSession`'s
/// `interruptionNotification`. `.began` arrives when the other session takes
/// over and `.ended` when it is done. The notification's `shouldResume` hint is
/// deliberately not consulted: it is advice for background music, and a call
/// is not music — the other participants are still there, so the microphone
/// is reopened regardless, and the Dart side composes that with the user's own
/// mute (a microphone the user closed stays closed).
final class CallAudioInterruptions: NSObject, FlutterStreamHandler {
  static let channelName = "com.nkshub.nextcloudtalk/call_audio_focus"

  private let channel: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var observer: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterEventChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setStreamHandler(self)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handle(notification)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    observer = nil
    sink = nil
    return nil
  }

  func dispose() {
    _ = onCancel(withArguments: nil)
    channel.setStreamHandler(nil)
  }

  private func handle(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else {
      return
    }
    switch type {
    case .began:
      sink?("began")
    case .ended:
      sink?("ended")
    @unknown default:
      break
    }
  }
}
