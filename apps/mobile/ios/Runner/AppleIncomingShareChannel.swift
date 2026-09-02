import Flutter
import Foundation

@MainActor
final class AppleIncomingShareChannel {
  static let name = "com.nkshub.nextcloudtalk/share"

  private let channel: FlutterMethodChannel
  private let inbox: AppleIncomingShareInbox?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    inbox = try? AppleIncomingShareInbox()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  func dispose() {
    channel.setMethodCallHandler(nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
