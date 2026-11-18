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
  private static let originalTypes = [
    "public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp",
  ]
  private static let convertedTypes = ["public.heic", "public.heif", "public.tiff"]
  private static let imageTypes = originalTypes + convertedTypes

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(
    label: "com.nkshub.nextcloudtalk.clipboard-image",
    qos: .userInitiated
  )
  private var observers: [NSObjectProtocol] = []

  /// The change count `peek` names the clip by. iOS also moves the count
  /// while this app is in front and nothing was copied, by four each time the
  /// keyboard comes up. Following those left the tile on show naming an old
  /// count, so its first tap took nothing, and brought a dismissed picture
  /// back. The count is taken when this app copies, and when it comes back
  /// from the background, where another app may have copied.
  ///
  /// The count moves during an app switch too, and nothing iOS tells without
  /// the paste alert separates that from a new copy: a picture dismissed
  /// before a visit to another app is offered again after it. A copy made
  /// next to the app while it stays in front (iPad split view) is seen only
  /// once the app was in the background.
  private var clipCount = UIPasteboard.general.changeCount

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    // `changedNotification` only covers copies made inside this app.
    for (name, object) in [
      (UIPasteboard.changedNotification, UIPasteboard.general),
      (UIApplication.willEnterForegroundNotification, nil),
    ] as [(Notification.Name, Any?)] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
          [weak self] _ in
          self?.take(UIPasteboard.general.changeCount)
        }
      )
    }
  }

  func dispose() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    channel.setMethodCallHandler(nil)
  }

  private func take(_ changeCount: Int) {
    guard changeCount != clipCount else {
      return
    }
    clipCount = changeCount
    channel.invokeMethod("changed", arguments: nil)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "peek":
      result(Self.hasImage(UIPasteboard.general) ? "ios-\(clipCount)" : nil)
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

  private static func hasImage(_ pasteboard: UIPasteboard) -> Bool {
    pasteboard.hasImages || pasteboard.contains(pasteboardTypes: imageTypes)
  }

  private static func read(maximumBytes: Int) -> Data? {
    let pasteboard = UIPasteboard.general
    guard hasImage(pasteboard) else {
      return nil
    }
    // The file as it was copied, when the pasteboard still has it in a form
    // every Talk client can show.
    for type in originalTypes where pasteboard.contains(pasteboardTypes: [type]) {
      guard let data = pasteboard.data(forPasteboardType: type) else {
        return nil
      }
      if !data.isEmpty && data.count <= maximumBytes {
        return data
      }
    }
    let image = pasteboard.image ?? convertedTypes.lazy.compactMap { type in
      pasteboard.data(forPasteboardType: type).flatMap { data in
        data.count <= maximumBytes ? UIImage(data: data) : nil
      }
    }.first
    guard let image = image,
      let bitmap = image.cgImage, bitmap.height > 0,
      bitmap.width <= (32 * 1024 * 1024) / bitmap.height,
      let data = upright(image).pngData(),
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
