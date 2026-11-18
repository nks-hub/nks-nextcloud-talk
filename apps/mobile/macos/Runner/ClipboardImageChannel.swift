import AppKit
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers

final class ClipboardImageChannel {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(
    label: "com.nkshub.nextcloudtalk.clipboard-image",
    qos: .userInitiated
  )
  private let originalTypes: [UTType] = [.png, .jpeg, .gif, .webP]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.nkshub.nextcloudtalk/clipboard_image",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "peek":
      // Even a pasteboard query can wait on Universal Clipboard.
      queue.async {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        let hasImage = self.imageType(on: pasteboard) != nil
        let id = hasImage && count == pasteboard.changeCount ? "macos-\(count)" : nil
        DispatchQueue.main.async { result(id) }
      }
    case "read":
      guard let maximumBytes = (call.arguments as? NSNumber)?.intValue, maximumBytes > 0 else {
        result(FlutterError(code: "invalid_arguments", message: "Expected a byte limit.", details: nil))
        return
      }
      queue.async {
        let data = self.read(maximumBytes: maximumBytes)
        DispatchQueue.main.async { result(data.map(FlutterStandardTypedData.init(bytes:))) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func imageType(on pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
    guard let types = pasteboard.types, !types.contains(.fileURL) else {
      return nil
    }
    for type in originalTypes {
      let format = NSPasteboard.PasteboardType(type.identifier)
      if types.contains(format) {
        return format
      }
    }
    return types.first { UTType($0.rawValue)?.conforms(to: .image) == true }
  }

  private func read(maximumBytes: Int) -> Data? {
    let pasteboard = NSPasteboard.general
    let count = pasteboard.changeCount
    guard let type = imageType(on: pasteboard),
      let data = pasteboard.data(forType: type), !data.isEmpty, data.count <= maximumBytes,
      count == pasteboard.changeCount
    else {
      return nil
    }
    if originalTypes.contains(where: { $0.identifier == type.rawValue }) {
      return data
    }

    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= (32 * 1024 * 1024) / height
    else {
      return nil
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output as CFMutableData, UTType.png.identifier as CFString, 1, nil
    ) else {
      return nil
    }
    CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else {
      return nil
    }
    return output as Data
  }
}
