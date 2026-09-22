import Flutter
import Foundation

final class AppleIncomingShareChannel {
  static let name = "com.nkshub.nextcloudtalk/share"

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "com.nkshub.nextcloudtalk.share")
  private var inbox: AppleIncomingShareInbox?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      // A share extension can hold the file lock while copying a large file.
      self.queue.async {
        self.handle(call) { value in
          DispatchQueue.main.async { result(value) }
        }
      }
    }
  }

  func dispose() {
    channel.setMethodCallHandler(nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if inbox == nil {
      inbox = try? AppleIncomingShareInbox()
    }
    switch call.method {
    case "getLaunchShare":
      result(inbox?.pending().first?.methodChannelValue)
    case "completeShare":
      guard let arguments = call.arguments as? [String: Any],
            let id = arguments["id"] as? String
      else {
        result(
          FlutterError(
            code: "invalid_share",
            message: "A share id is required.",
            details: nil
          )
        )
        return
      }
      result(inbox?.complete(id: id) ?? false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
