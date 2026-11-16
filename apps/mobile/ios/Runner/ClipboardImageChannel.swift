import Flutter
import UIKit

/// Lets the composer suggest the image waiting on the pasteboard, on the same
/// channel and with the same three words as the Android side.
///
/// `peek` asks only `hasImages` and `changeCount`. Those are the two questions
/// iOS answers without the paste notice, so it is safe to ask them whenever the
/// message field gets focus. `read` takes the content, which is what makes iOS
/// ask the user about a clip that came from another app.
final class ClipboardImageChannel {
  static let channelName = "com.nkshub.nextcloudtalk/clipboard_image"

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(
    label: "com.nkshub.nextcloudtalk.clipboard-image",
    qos: .userInitiated
  )
  private var observers: [NSObjectProtocol] = []
  private var seenChangeCount = UIPasteboard.general.changeCount

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    // `changedNotification` only covers copies made inside this app. One made
    // elsewhere shows up as a new change count once the app is active again.
    for name in [UIPasteboard.changedNotification, UIApplication.didBecomeActiveNotification] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          self?.reportChange()
        }
      )
    }
  }

  func dispose() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    channel.setMethodCallHandler(nil)
  }

  private func reportChange() {
    let changeCount = UIPasteboard.general.changeCount
    guard changeCount != seenChangeCount else {
      return
    }
    seenChangeCount = changeCount
    channel.invokeMethod("changed", arguments: nil)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "peek":
      let pasteboard = UIPasteboard.general
      result(pasteboard.hasImages ? "ios-\(pasteboard.changeCount)" : nil)
    case "read":
      guard let maximumBytes = (call.arguments as? NSNumber)?.intValue, maximumBytes > 0 else {
        result(
          FlutterError(code: "invalid_arguments", message: "Expected a byte limit.", details: nil)
        )
        return
      }
      // Off the main thread: while iOS asks the user about the paste, the
      // reading thread is the one that waits.
      queue.async {
        let data = Self.read(maximumBytes: maximumBytes)
        DispatchQueue.main.async {
          result(data.map(FlutterStandardTypedData.init(bytes:)))
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func read(maximumBytes: Int) -> Data? {
    let pasteboard = UIPasteboard.general
    guard pasteboard.hasImages else {
      return nil
    }
    // The file as it was copied, when the pasteboard still has it in a form
    // every Talk client can show.
    for type in ["public.png", "public.jpeg"] {
      if let data = pasteboard.data(forPasteboardType: type) {
        return data.count <= maximumBytes ? data : nil
      }
    }
    guard let image = pasteboard.image, let data = upright(image).pngData(),
      data.count <= maximumBytes
    else {
      return nil
    }
    return data
  }

  /// PNG has no orientation flag, so a rotated photo is redrawn the way it
  /// is meant to be seen.
  private static func upright(_ image: UIImage) -> UIImage {
    guard image.imageOrientation != .up else {
      return image
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }
}
